// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage

/** Synthetic provider: rename commits B, then observation fails before returning a node. */
internal class ProbeRenameFailureFixture(
    private val receipts: ProbeReceipts,
    private val cleanupThrows: Boolean,
    private val emptyQuery: Boolean = false,
    private val afterRename: () -> Unit = {}
) : DocumentsIoPort {
    companion object {
        const val A = "content://Fixture.Provider/tree/root%2Fgrant/document/A%2fopaque"
        const val B = "content://Fixture.Provider/tree/root%2Fgrant/document/%42%2FOpaque"
        val DIRECTORY = NativeDirectory("Fixture.Provider", "content://Fixture.Provider/tree/root%2Fgrant", "root/grant")
    }
    val nodes = mutableListOf(NativeNode("unrelated", "unrelated.partial", false))
    val deleted = mutableListOf<String>()
    private var payload = byteArrayOf()
    override fun name(directory: NativeDirectory) = "Chosen folder"
    override fun children(directory: NativeDirectory) = nodes.toList()
    override fun uri(directory: NativeDirectory, node: NativeNode) = when (node.id) {
        "A/opaque" -> A
        "B/Opaque" -> B
        else -> throw AssertionError("Unrelated node must not become a receipt")
    }
    override fun create(directory: NativeDirectory, name: String, mime: String): NativeNode {
        val node = NativeNode("A/opaque", name, false)
        nodes.add(node)
        return receipts.observe(A) { node }
    }
    override fun write(directory: NativeDirectory, node: NativeNode, bytes: ByteArray) { payload = bytes.copyOf() }
    override fun read(directory: NativeDirectory, node: NativeNode) = payload.copyOf()
    override fun rename(directory: NativeDirectory, node: NativeNode, name: String): NativeNode {
        check(nodes.remove(node))
        nodes.add(node.copy(id = "B/Opaque", name = name))
        return receipts.observe(B) {
            afterRename()
            // Exercise the production query classification after the side effect.
            ProviderQuerySnapshot(emptyList(), false, if (emptyQuery) null else "Query failed")
                .completedRows().singleOrNull()
                ?: throw NativeStorageException("io", "Renamed document not observable")
        }
    }
    override fun delete(directory: NativeDirectory, node: NativeNode): Boolean {
        deleted.add(node.id)
        check(node.id == "A/opaque") { "Must not guess the new ID or an unrelated node" }
        if (cleanupThrows) throw NativeStorageException("unavailable", "Old ID unavailable")
        return false
    }
}
