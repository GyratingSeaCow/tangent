// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage

/** Descriptor acquisition seam shared by the Android adapter and host regressions. */
internal class AndroidCaptureSource<H>(private val cacheRoot: String, private val io: Io<H>) {
    data class Node(val device: Long, val inode: Long, val directory: Boolean,
                    val regular: Boolean, val link: Boolean, val uid: Int)
    interface Io<H> {
        fun canonicalRoot(path: String): String
        fun lstat(path: String): Node
        fun open(path: String): H
        fun openAt(parent: H, name: String): H
        fun stat(handle: H): Node
        fun identity(handle: H): Map<String, Any?>
        fun read(handle: H): ByteArray
        fun close(handle: H)
    }
    private fun fail(code: String, message: String): Nothing = throw NativeStorageException(code, message)
    private fun parts(path: String): List<String> {
        if (!path.startsWith('/') || path.contains('\u0000') || path.split('/').any { it == "." || it == ".." })
            fail("invalid", "Invalid capture source path")
        return path.split('/').filter { it.isNotEmpty() }
    }
    private data class RootProof(val canonical: String, val nodes: List<Node>)

    private fun trustedRoot(): RootProof {
        val names = parts(cacheRoot)
        // Context.cacheDir is beneath the application's data directory. Neither
        // of these last two components is an allowed platform-owned alias.
        if (names.size < 2) fail("invalid", "Missing application cache anchor")
        val nodes = names.indices.map { index ->
            val node = io.lstat("/" + names.take(index + 1).joinToString("/"))
            if (node.link) {
                if (index >= names.size - 2 || node.uid !in setOf(0, 1000))
                    fail("invalid", "Untrusted alias in application cache anchor")
            } else if (!node.directory) fail("invalid", "Cache ancestor is not a directory")
            node
        }
        // ONLY the framework-supplied root is canonicalized. Never the reservation
        // path or suffix: resolving those would bless an untrusted symlink.
        val canonical = io.canonicalRoot(cacheRoot)
        parts(canonical)
        return RootProof(canonical, nodes)
    }

    fun read(path: String): CaptureSource {
        if (path.endsWith('/')) fail("invalid", "Capture source must name a regular file")
        val names = parts(path)
        val proof = trustedRoot()
        val literal = parts(cacheRoot)
        val canonical = parts(proof.canonical)
        val prefix = when {
            names.size > literal.size && names.take(literal.size) == literal -> literal
            names.size > canonical.size && names.take(canonical.size) == canonical -> canonical
            else -> fail("invalid", "Capture source is outside application cache")
        }
        val suffix = names.drop(prefix.size)
        val held = mutableListOf<H>()
        val pinned = mutableListOf<Node>()
        fun pin(fd: H, directory: Boolean) {
            held.add(fd) // retain even if stat/type validation throws
            val node = io.stat(fd)
            if (node.link || (if (directory) !node.directory else !node.regular))
                fail("unsupported", "Capture requires directory ancestors and a regular source")
            pinned.add(node)
        }
        try {
            // A direct no-follow open of the trusted root requires only SEARCH on
            // system ancestors, not READ. Owned suffix opens are descriptor-relative.
            pin(io.open(cacheRoot), true)
            if (pinned.first() != proof.nodes.last()) fail("conflict", "Cache root changed before pin")
            for ((index, name) in suffix.withIndex()) pin(io.openAt(held.last(), name), index < suffix.lastIndex)
            if (trustedRoot() != proof) fail("conflict", "Cache anchor changed before source read")
            val fd = held.last()
            val identity = io.identity(fd)
            val bytes = io.read(fd)
            if (io.stat(fd) != pinned.last() || io.identity(fd) != identity)
                fail("conflict", "Opened source identity changed")

            // Rewalk the ORIGINAL reservation spelling, without canonicalizing it.
            // Compare every directory too: moving the same final inode into a new
            // cache/staging directory must not pass a file-only comparison.
            val fresh = mutableListOf<H>()
            try {
                fresh.add(io.open("/" + prefix.joinToString("/")))
                if (io.stat(fresh.last()) != pinned.first()) fail("conflict", "Cache root was replaced")
                for ((index, name) in suffix.withIndex()) {
                    fresh.add(io.openAt(fresh.last(), name))
                    if (io.stat(fresh.last()) != pinned[index + 1]) fail("conflict", "Staging path was replaced")
                }
                if (io.identity(fresh.last()) != identity || trustedRoot() != proof)
                    fail("conflict", "Original source association changed")
            } finally { fresh.asReversed().forEach(io::close) }
            return CaptureSource(identity, bytes)
        } finally { held.asReversed().forEach(io::close) }
    }
}
