// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction

/** Stateless capture/resolve policy used by the Android adapter and JVM tests. */
internal class LegacyStorageInspection(
    private val readPreference: () -> Any?,
    private val queryDirectory: (NativeDirectory) -> List<NativeNode>,
    private val queryChildren: (NativeDirectory) -> List<NativeNode>
) {
    private fun checkedName(d: NativeDirectory): String {
        val node = queryDirectory(d).singleOrNull() ?: invalid()
        if (node.id != d.documentId || !node.directory || node.virtual) invalid()
        return node.name
    }
    private val policy = SafPolicy(object : DocumentsPort {
        override fun name(directory: NativeDirectory) = checkedName(directory)
        override fun children(directory: NativeDirectory): List<NativeNode> {
            checkedName(directory)
            return queryChildren(directory)
        }
        override fun delete(directory: NativeDirectory, node: NativeNode): Boolean =
            throw NativeStorageException("unsupported", "Legacy inspection is read-only")
    })
    fun inspect(frozenAnchor: Any?): Map<String, Any?>? {
        if (frozenAnchor == null) {
            val saved = try { readPreference() }
                catch (_: ClassCastException) { invalid() }
                catch (_: SecurityException) { throw NativeStorageException("denied", "Legacy preference access denied") }
                catch (_: IOException) { throw NativeStorageException("io", "Legacy preference read failed") }
            if (saved == null) return null
            if (saved !is String) invalid()
            return mapOf("location" to null, "anchorJson" to encodeAnchor(saved))
        }
        if (frozenAnchor !is String) invalid()
        val selected = decodeAnchor(frozenAnchor)["selectedTreeUri"] as String?
        return mapOf("location" to resolve(selected), "anchorJson" to frozenAnchor)
    }
    private fun resolve(selected: String?): Map<String, Any?>? {
        if (selected == null) return null
        return try {
            val root = selection(selected)
            val effective = policy.effectiveDirectory(root, true)
            val label = checkedName(effective)
            mapOf("version" to 1, "id" to "legacy-saf", "label" to label,
                "directory" to mapOf("version" to 1, "kind" to "saf", "path" to "",
                    "authority" to effective.authority, "treeUri" to selected, "documentId" to effective.documentId))
        } catch (_: NativeStorageException) { null }
          catch (_: SecurityException) { null }
          catch (_: IOException) { null }
          catch (_: IllegalArgumentException) { null }
    }
    companion object {
        private const val KIND = "legacy-saf-selection"
        private const val POLICY = "tree-root-documents-or-tangent-v1"
        private fun invalid(): Nothing = throw NativeStorageException("invalid", "Invalid frozen legacy inspection")
        fun encodeAnchor(selected: String?): String =
            "{\"version\":1,\"kind\":\"$KIND\",\"policy\":\"$POLICY\",\"selectedTreeUri\":" +
                (selected?.let(::quote) ?: "null") + "}"
        fun decodeAnchor(json: String): Map<String, Any?> {
            val map = EnvelopeReader(json).read()
            if (map.keys != setOf("version", "kind", "policy", "selectedTreeUri") ||
                map["version"] != 1L || map["kind"] != KIND || map["policy"] != POLICY ||
                (map["selectedTreeUri"] != null && map["selectedTreeUri"] !is String)) invalid()
            return map
        }
        private fun quote(value: String): String = buildString {
            append('"')
            for (c in value) when {
                c == '"' || c == '\\' -> { append('\\'); append(c) }
                c.code < 32 || c.isSurrogate() -> append("\\u" + c.code.toString(16).padStart(4, '0'))
                else -> append(c)
            }
            append('"')
        }
        fun selection(value: String): NativeDirectory {
            if (value.contains('\u0000') || Regex("%(?![0-9A-Fa-f]{2})").containsMatchIn(value)) invalid()
            val match = Regex("^content://([^/?#]+)(/[^?#]*)$", RegexOption.IGNORE_CASE).matchEntire(value) ?: invalid()
            val authority = match.groupValues[1]
            if (authority.contains('@') || authority.contains(':') || authority.contains('[') || authority.contains(']')) {
                // A bracketed IPv6 authority may have no port; userinfo/ports never qualify.
                val uri = try { java.net.URI("content://$authority/") } catch (_: java.net.URISyntaxException) { invalid() }
                if (!authority.startsWith('[') || !authority.endsWith(']') || uri.rawUserInfo != null || uri.port != -1) invalid()
            }
            val parts = match.groupValues[2].substring(1).split('/').map(::decodeComponent)
            if (parts.size != 2 && parts.size != 4) invalid()
            if (parts[0] != "tree" || parts[1].isEmpty() ||
                (parts.size == 4 && (parts[2] != "document" || parts[3].isEmpty()))) invalid()
            return NativeDirectory(authority, value, parts[1])
        }
        private fun decodeComponent(encoded: String): String {
            val bytes = ByteArrayOutputStream()
            var index = 0
            while (index < encoded.length) {
                if (encoded[index] == '%') {
                    if (index + 2 >= encoded.length) invalid()
                    bytes.write(encoded.substring(index + 1, index + 3).toIntOrNull(16) ?: invalid())
                    index += 3
                } else {
                    val end = encoded.indexOf('%', index).let { if (it < 0) encoded.length else it }
                    val buffer = try {
                        Charsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
                            .encode(CharBuffer.wrap(encoded.substring(index, end)))
                    } catch (_: java.nio.charset.CharacterCodingException) { invalid() }
                    while (buffer.hasRemaining()) bytes.write(buffer.get().toInt())
                    index = end
                }
            }
            val decoded = try {
                Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes.toByteArray())).toString()
            } catch (_: java.nio.charset.CharacterCodingException) { invalid() }
            if (decoded.contains('\u0000')) invalid()
            return decoded
        }
        /** Strict scalar JSON for this exact flat envelope; no Android mock JSON or dependencies. */
        private class EnvelopeReader(private val text: String) {
            private var i = 0
            private fun space() { while (i < text.length && text[i] in " \t\r\n") i++ }
            private fun take(c: Char) { space(); if (i >= text.length || text[i++] != c) invalid() }
            private fun string(): String {
                take('"')
                val out = StringBuilder()
                while (i < text.length) {
                    val c = text[i++]
                    if (c == '"') return out.toString()
                    if (c.code < 32) invalid()
                    if (c != '\\') { out.append(c); continue }
                    if (i == text.length) invalid()
                    out.append(when (val escape = text[i++]) {
                        '"', '\\', '/' -> escape
                        'b' -> '\b'; 'f' -> '\u000c'; 'n' -> '\n'; 'r' -> '\r'; 't' -> '\t'
                        'u' -> {
                            if (i + 4 > text.length) invalid()
                            val hex = text.substring(i, i + 4)
                            if (!hex.all { it in "0123456789abcdefABCDEF" }) invalid()
                            i += 4; hex.toInt(16).toChar()
                        }
                        else -> invalid()
                    })
                }
                invalid()
            }
            private fun value(): Any? {
                space()
                if (i >= text.length) invalid()
                if (text[i] == '"') return string()
                if (text.startsWith("null", i)) { i += 4; return null }
                val match = Regex("-?(?:0|[1-9][0-9]*)").find(text, i)
                if (match == null || match.range.first != i) invalid()
                i += match.value.length
                return match.value.toLongOrNull() ?: invalid()
            }
            fun read(): Map<String, Any?> {
                val map = linkedMapOf<String, Any?>()
                take('{'); space()
                if (i < text.length && text[i] == '}') { i++; space(); if (i != text.length) invalid(); return map }
                while (true) {
                    val key = string(); take(':'); val value = value()
                    if (map.containsKey(key)) invalid()
                    map[key] = value; space()
                    if (i >= text.length) invalid()
                    if (text[i] == '}') { i++; break }
                    take(',')
                }
                space(); if (i != text.length) invalid()
                return map
            }
        }
    }
}
