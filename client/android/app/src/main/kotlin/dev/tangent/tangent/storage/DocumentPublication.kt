// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage

/**
 * Sidecar-free durable documents (notebooks). One self-contained file per
 * document inside a named child of the owned tree, published through the SAME
 * provider primitives and ownership policy the capture pipeline uses.
 *
 * Only provider primitives are replaceable; production and JVM tests share
 * this policy, so a bug here cannot hide behind a test-only implementation.
 */
interface DurableDocumentsPort : DocumentsIoPort {
    /** Creates a child DIRECTORY; the caller has already proven it is absent. */
    fun createDirectory(directory: NativeDirectory, name: String): NativeNode
}

object DocumentWire {
    /** Mirrors the shared Dart constant notebookSubdirectoryName. A sibling of
     *  CaptureWire.TEXT_NOTE_DIRECTORY, never the same directory. */
    const val NOTEBOOK_DIRECTORY = "Tangent Notebooks"

    /** Mirrors the shared Dart constant notebookFileSuffix. */
    const val NOTEBOOK_SUFFIX = ".notebook.json"
    const val DOCUMENT_MIME = "application/json"

    /**
     * MIME-coherent temporary extension.
     *
     * AOSP's FileSystemProvider APPENDS a MIME-derived extension when the
     * requested display name's extension does not match the MIME type,
     * silently renaming the temp and tripping the created-identity check
     * (observed on-device: '.x.partial' became '.x.partial.json'). Every temp
     * name must already end in the MIME's extension. Same rule, same spelling
     * as AndroidDocumentsPort.publish.
     */
    fun tempExtension(mime: String): String = when (mime) {
        "application/json" -> ".json"; "text/markdown" -> ".md"; "audio/ogg" -> ".ogg"; else -> ""
    }

    fun text(x: Any?): String = x as? String ?: CaptureWire.fault("invalid", "Expected document string")
    fun literal(x: Any?): String = CaptureWire.literal(x)
    fun directory(location: Any?): NativeDirectory = CaptureWire.directory(location)

    /** The owned child of a tree root, or null when it is absent. A same-name
     *  non-directory (or a duplicate) is a conflict: falling back to the root
     *  would scatter documents outside the folder the user can find. */
    fun child(port: DocumentsPort, d: NativeDirectory, name: String): NativeNode? {
        val matches = port.children(d).filter { it.name == name }
        if (matches.size > 1) CaptureWire.fault("conflict", "Ambiguous document directory")
        val node = matches.singleOrNull() ?: return null
        if (!node.directory || node.virtual) CaptureWire.fault("conflict", "Document directory name is not a directory")
        return node
    }
}

class DocumentPublication(private val port: DurableDocumentsPort) {
    private val policy = SafPolicy(port)

    /** Resolve-or-create, idempotently. Never created on read/delete paths. */
    private fun directoryFor(d: NativeDirectory, name: String, create: Boolean): NativeDirectory? {
        DocumentWire.child(port, d, name)?.let { return NativeDirectory(d.authority, d.treeUri, it.id) }
        if (!create) return null
        val created = port.createDirectory(d, name)
        if (created.id == d.documentId || !created.directory || created.virtual) {
            CaptureWire.fault("conflict", "Returned document directory is not owned")
        }
        val observed = DocumentWire.child(port, d, name)
            ?: CaptureWire.fault("unavailable", "Created document directory is not observable")
        if (observed.id != created.id) CaptureWire.fault("conflict", "Document directory identity differs")
        return NativeDirectory(d.authority, d.treeUri, observed.id)
    }

    private fun located(args: Map<String, Any?>): Pair<NativeDirectory, String> {
        val d = DocumentWire.directory(args["location"])
        return d to DocumentWire.literal(args["directoryName"])
    }

    private fun row(d: NativeDirectory, node: NativeNode, content: String): Map<String, Any?> = mapOf(
        "name" to node.name,
        "locator" to mapOf("version" to 1, "kind" to "saf", "value" to port.uri(d, node)),
        "content" to content,
    )

    fun publish(args: Map<String, Any?>): Map<String, Any?> {
        val (root, directoryName) = located(args)
        val name = DocumentWire.literal(args["name"])
        val content = DocumentWire.text(args["content"])
        DocumentWire.literal(args["publicationId"])
        val bytes = content.toByteArray(Charsets.UTF_8)
        return write(root, directoryName, name, bytes, DocumentWire.DOCUMENT_MIME, content)
    }

    /**
     * Publishes raw bytes (downloaded audio) rather than text.
     *
     * The text [publish] above encodes its content as UTF-8, which corrupts
     * anything that is not text, so audio needs its own entry point. Both
     * share [write] so the atomic temp -> verify -> park -> rename -> delete
     * sequence can never drift between them.
     */
    fun publishBinary(args: Map<String, Any?>): Map<String, Any?> {
        val (root, directoryName) = located(args)
        val name = DocumentWire.literal(args["name"])
        DocumentWire.literal(args["publicationId"])
        val bytes = args["bytes"] as? ByteArray
            ?: CaptureWire.fault("invalid", "Document bytes are missing")
        if (bytes.isEmpty()) CaptureWire.fault("invalid", "Refusing to publish an empty document")
        val mime = DocumentWire.text(args["mimeType"])
        if (mime.isEmpty()) CaptureWire.fault("invalid", "Empty document MIME type")
        // `content` describes TEXT documents; binary publication reports an
        // empty string rather than decoding audio into one.
        return write(root, directoryName, name, bytes, mime, "")
    }

    private fun write(
        root: NativeDirectory,
        directoryName: String,
        name: String,
        bytes: ByteArray,
        mime: String,
        content: String,
    ): Map<String, Any?> {
        val d = directoryFor(root, directoryName, true)!!
        val old = policy.ownedNode(d, name, null)
        // Write to a MIME-coherent temp, verify, replace, then rename: a torn
        // write can never truncate the last successfully published copy.
        val temp = port.create(
            d,
            ".$name-${java.util.UUID.randomUUID()}.partial${DocumentWire.tempExtension(mime)}",
            mime,
        )
        try {
            port.write(d, temp, bytes)
            if (!port.read(d, temp).contentEquals(bytes)) CaptureWire.fault("io", "Document readback mismatch")
            // Park the previous copy under a temp name instead of deleting it:
            // if the publish rename then fails, the old content is still on
            // disk and gets its name back. Deleting first would destroy the
            // last good copy whenever the provider refuses the rename.
            var parked: NativeNode? = null
            if (old != null) {
                parked = port.rename(
                    d,
                    old,
                    ".$name-${java.util.UUID.randomUUID()}.superseded${DocumentWire.tempExtension(mime)}",
                )
            }
            val published = try {
                port.rename(d, temp, name)
            } catch (e: Exception) {
                // Restore the previous copy's name before surfacing the fault.
                if (parked != null) {
                    try { port.rename(d, parked, name) } catch (_: Exception) { /* keep original fault */ }
                }
                throw e
            }
            if (published.name != name || published.directory || published.virtual) {
                if (parked != null) {
                    try { port.rename(d, parked, name) } catch (_: Exception) { /* keep original fault */ }
                }
                CaptureWire.fault("conflict", "Provider changed the published document")
            }
            if (parked != null && !port.delete(d, parked)) {
                CaptureWire.fault("io", "Provider refused replacement")
            }
            return row(d, published, content)
        } catch (e: Exception) {
            // Only this operation's exact returned document is eligible for cleanup.
            try { port.delete(d, temp) } catch (_: Exception) { /* Retain failure; never guess another URI. */ }
            throw e
        }
    }

    fun list(args: Map<String, Any?>): List<Map<String, Any?>> {
        val (root, directoryName) = located(args)
        val suffix = DocumentWire.text(args["suffix"])
        if (suffix.isEmpty()) CaptureWire.fault("invalid", "Empty document suffix")
        val d = directoryFor(root, directoryName, false) ?: return emptyList()
        return port.children(d)
            .filter { !it.directory && !it.virtual && it.name.endsWith(suffix) && it.name.length > suffix.length }
            .map { node ->
                val owned = policy.ownedNode(d, node.name, node.id)
                    ?: CaptureWire.fault("absent", "Document disappeared during enumeration")
                row(d, owned, String(port.read(d, owned), Charsets.UTF_8))
            }
    }

    fun delete(args: Map<String, Any?>): Map<String, Any?> {
        val (root, directoryName) = located(args)
        val name = DocumentWire.literal(args["name"])
        DocumentWire.literal(args["deletionId"])
        val locator = CaptureWire.obj(args["locator"], setOf("kind", "value"))
        if (locator["kind"] != "saf") CaptureWire.fault("invalid", "Wrong document locator kind")
        val decoded = CaptureWire.uri(DocumentWire.text(locator["value"]))
        val d = directoryFor(root, directoryName, false)
            ?: return mapOf("state" to "absent", "problem" to null)
        if (decoded.first != d.authority) CaptureWire.fault("invalid", "Foreign document authority")
        // Name AND the opaque document ID must agree: a same-name foreign
        // document is never deleted, and no ID is ever parsed as a path.
        val result = policy.deleteComponent(d, name, decoded.second)
        return mapOf(
            "state" to result.state,
            "problem" to result.problem?.let { mapOf("code" to it.code, "message" to it.message) },
        )
    }

    fun execute(method: String, args: Map<String, Any?>): Any = when (method) {
        "publishDocumentAt" -> publish(args)
        "publishBinaryDocumentAt" -> publishBinary(args)
        "listDocumentsAt" -> list(args)
        "deleteDocumentAt" -> delete(args)
        else -> CaptureWire.fault("unsupported", "Unknown document operation")
    }
}
