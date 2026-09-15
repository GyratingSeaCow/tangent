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
interface DocumentsPort {
    fun name(directory: NativeDirectory): String
    fun children(directory: NativeDirectory): List<NativeNode>
    fun delete(directory: NativeDirectory, node: NativeNode): Boolean
}
