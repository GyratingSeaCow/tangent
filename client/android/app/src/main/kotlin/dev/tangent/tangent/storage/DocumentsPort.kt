// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage

data class NativeDirectory(val authority: String, val treeUri: String, val documentId: String)
data class NativeNode(val id: String, val name: String, val directory: Boolean, val virtual: Boolean = false)
class NativeStorageException(val code: String, message: String) : RuntimeException(message)
data class NativeComponentResult(val state: String, val problem: NativeStorageException? = null)
interface DocumentsIoPort : DocumentsPort {
    fun create(directory: NativeDirectory, name: String, mime: String): NativeNode
    fun read(directory: NativeDirectory, node: NativeNode): ByteArray
    fun write(directory: NativeDirectory, node: NativeNode, bytes: ByteArray)
    fun rename(directory: NativeDirectory, node: NativeNode, name: String): NativeNode
    fun uri(directory: NativeDirectory, node: NativeNode): String
}
/** Answer to "is this exact document a regular child of this directory?". */
sealed interface Membership {
    /** The provider cannot answer without listing; the caller must fall back. */
    object Unsupported : Membership
    /** Definitively not a usable regular child (missing, or a directory). */
    object Absent : Membership
    data class Present(val node: NativeNode) : Membership
}

interface DocumentsPort {
    fun name(directory: NativeDirectory): String
    fun children(directory: NativeDirectory): List<NativeNode>
    fun delete(directory: NativeDirectory, node: NativeNode): Boolean

    /** Verifies ONE known child without listing the directory.
     *
     *  T8: checking a single file by listing all 81 files in the folder, ~20
     *  times per save, was most of a 10.4-second stop. Mirrors the record-start
     *  fix (31645e8), where a full enumeration answering "does this folder
     *  exist?" became a single document query.
     *
     *  Defaults to [Membership.Unsupported] so every existing implementation
     *  keeps its current listing behaviour untouched. */
    fun membership(
        directory: NativeDirectory,
        name: String,
        documentId: String,
    ): Membership = Membership.Unsupported
}
