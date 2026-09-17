// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage

class SafPolicy(private val port: DocumentsPort) {
    companion object {
        fun sameGrant(authority:String?,treeId:String,otherAuthority:String?,otherTreeId:String):Boolean =
            authority != null && authority == otherAuthority && treeId == otherTreeId
    }
    fun probe(directory: NativeDirectory, token: String): Map<String,Any?> {
        val io = port as DocumentsIoPort
        var node = io.create(directory,".$token-${java.util.UUID.randomUUID()}.partial","application/octet-stream")
        val owned = mutableListOf(io.uri(directory,node))
        try {
            val bytes = "tangent-probe".toByteArray()
            io.write(directory,node,bytes)
            if (!io.read(directory,node).contentEquals(bytes)) throw NativeStorageException("io","Probe readback mismatch")
            node = io.rename(directory,node,node.name + ".renamed"); owned.add(io.uri(directory,node))
            val cleaned = io.delete(directory,node)
            return mapOf("owned" to owned,"cleaned" to cleaned)
        } catch (e: Exception) {
            val cleaned = try { io.delete(directory,node) } catch (_: Exception) { false }
            if (!cleaned) return mapOf("owned" to owned,"cleaned" to false)
            throw e
        }
    }
    fun effectiveDirectory(selected: NativeDirectory, legacy: Boolean): NativeDirectory {
        if (!legacy) return selected
        val name = port.name(selected)
        if (name.equals("Tangent", true)) return selected
        if (!name.equals("Documents", true)) throw NativeStorageException("unresolved", "Unsupported legacy folder")
        val children = port.children(selected).filter { it.name == "Tangent" }
        if (children.size != 1 || !children.single().directory || children.single().virtual)
            throw NativeStorageException("unresolved", "Legacy Tangent child is missing or ambiguous")
        return selected.copy(documentId = children.single().id)
    }
    fun requireAvailableNames(directory: NativeDirectory, names: Set<String>, exceptId: String? = null) {
        if (port.children(directory).any { it.name in names && it.id != exceptId })
            throw NativeStorageException("conflict", "Target exists")
    }
    fun ownedNode(directory: NativeDirectory, name: String, expectedDocumentId: String?): NativeNode? {
        if (name.isEmpty() || name == "." || name == ".." || name.any { it == '/' || it == '\\' || it == '\u0000' })
            throw NativeStorageException("invalid", "Invalid component name")
        val matches = port.children(directory).filter { it.name == name }
        if (matches.isEmpty()) return null
        if (matches.size != 1) throw NativeStorageException("conflict", "Ambiguous component name")
        val node = matches.single()
        if (node.directory || node.virtual || (expectedDocumentId != null && node.id != expectedDocumentId))
            throw NativeStorageException("invalid", "Not the owned regular component")
        return node
    }
    fun deleteComponent(directory: NativeDirectory, name: String, expectedDocumentId: String?): NativeComponentResult {
        return try {
            val node = ownedNode(directory, name, expectedDocumentId) ?: return NativeComponentResult("absent")
            if (port.delete(directory,node)) NativeComponentResult("removed")
            else NativeComponentResult("failed",NativeStorageException("io","Provider refused deletion"))
        } catch (e: NativeStorageException) { NativeComponentResult("failed",e) }
        catch (e: SecurityException) { NativeComponentResult("failed",NativeStorageException("denied","Provider access denied")) }
    }
}
