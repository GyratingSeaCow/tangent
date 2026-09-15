// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage
import org.junit.Assert.*
import org.junit.Test

private class MemoryDocuments : DocumentsPort {
    var label = "Documents"
    var entries = emptyList<NativeNode>()
    val deleted = mutableListOf<String>()
    var denied = false
    var deleteSucceeds = true
    override fun name(directory: NativeDirectory) = label
    override fun children(directory: NativeDirectory): List<NativeNode> {
        if (denied) throw NativeStorageException("denied", "Grant revoked")
        return entries
    }
    override fun delete(directory: NativeDirectory, node: NativeNode): Boolean {
        deleted.add(node.id); return deleteSucceeds
    }
}
class SafPolicyTest {
    @Test fun equivalentGrantIdentityIsNotUriPrefixMatching() {
        assertTrue(SafPolicy.sameGrant("Provider","opaque/root","Provider","opaque/root"))
        assertFalse(SafPolicy.sameGrant("Provider","opaque/root","Provider","opaque/root-other"))
        assertFalse(SafPolicy.sameGrant("Provider","opaque/root","Other","opaque/root"))
        assertTrue(SafPolicy.sameGrant("Provider","..","Provider",".."))
    }
    private val dir = NativeDirectory("provider", "content://provider/tree/grant", "opaque-parent")
    @Test fun probeFailuresRetainExactOwnedReceiptsAndNeverDeleteForeignNodes() {
        class ProbePort : DocumentsIoPort {
            var failAt = ""; val nodes = mutableListOf(NativeNode("foreign","foreign.partial",false))
            val bytes = mutableMapOf<String,ByteArray>(); val deleted = mutableListOf<String>()
            override fun name(directory:NativeDirectory) = "arbitrary"
            override fun children(directory:NativeDirectory) = nodes.toList()
            override fun uri(directory:NativeDirectory,node:NativeNode) = "content://provider/document/${node.id}"
            override fun create(directory:NativeDirectory,name:String,mime:String):NativeNode {
                if (failAt == "create") throw NativeStorageException("io","Create failed")
                return NativeNode("owned",name,false).also { nodes.add(it) }
            }
            override fun write(directory:NativeDirectory,node:NativeNode,value:ByteArray) { bytes[node.id] = value }
            override fun read(directory:NativeDirectory,node:NativeNode) = bytes[node.id]!!
            override fun rename(directory:NativeDirectory,node:NativeNode,name:String):NativeNode {
                if (failAt == "rename") throw NativeStorageException("io","Rename failed")
                nodes.remove(node); return node.copy(id="renamed",name=name).also { nodes.add(it) }
            }
            override fun delete(directory:NativeDirectory,node:NativeNode):Boolean {
                deleted.add(node.id); if (failAt == "cleanup") return false
                return nodes.remove(node)
            }
        }
        for (failure in listOf("", "create", "rename", "cleanup")) {
            val port = ProbePort(); port.failAt = failure
            try {
                val receipt = SafPolicy(port).probe(dir,"fixture-probe")
                assertEquals(failure != "cleanup",receipt["cleaned"])
                assertTrue((receipt["owned"] as List<*>).isNotEmpty())
                assertTrue(failure == "" || failure == "cleanup")
            } catch (e: NativeStorageException) { assertTrue(failure == "create" || failure == "rename") }
            assertTrue(port.nodes.any { it.id == "foreign" }); assertFalse(port.deleted.contains("foreign"))
        }
    }
    @Test fun legacyChildButNewSelectionIsDirect() {
        val docs = MemoryDocuments(); docs.entries = listOf(NativeNode("opaque-child", "Tangent", true))
        val policy = SafPolicy(docs)
        assertEquals("opaque-child", policy.effectiveDirectory(dir, true).documentId)
        assertEquals(dir, policy.effectiveDirectory(dir, false))
    }
    @Test fun falseDeleteAndDeniedEnumerationAreNotAbsence() {
        val docs = MemoryDocuments(); docs.entries = listOf(NativeNode("audio-id", "fixture-a.opus", false))
        docs.deleteSucceeds = false
        val policy = SafPolicy(docs)
        assertEquals("failed", policy.deleteComponent(dir,"fixture-a.opus","audio-id").state)
        docs.denied = true
        assertEquals("failed", policy.deleteComponent(dir,"fixture-a.meta.json",null).state)
    }
    @Test fun directoryOrWrongDocumentIdentityIsNeverDeleted() {
        val docs = MemoryDocuments(); docs.entries = listOf(NativeNode("other","fixture-a.opus",false),NativeNode("directory","fixture-a.meta.json",true))
        val policy = SafPolicy(docs)
        assertEquals("failed",policy.deleteComponent(dir,"fixture-a.opus","owned").state)
        assertEquals("failed",policy.deleteComponent(dir,"fixture-a.meta.json",null).state)
        assertTrue(docs.deleted.isEmpty())
    }
    @Test fun arbitraryNewNamesAndDirectTangent() {
        val docs = MemoryDocuments(); val policy = SafPolicy(docs)
        docs.label = "Any chosen name"; assertEquals(dir,policy.effectiveDirectory(dir,false))
        docs.label = "Tangent"; assertEquals(dir,policy.effectiveDirectory(dir,true))
    }
    @Test fun missingDuplicateAndNonDirectoryLegacyChildrenFailClosed() {
        for (nodes in listOf(emptyList(),listOf(NativeNode("file","Tangent",false)),listOf(NativeNode("one","Tangent",true),NativeNode("two","Tangent",true)))) {
            val docs = MemoryDocuments(); docs.entries = nodes
            try { SafPolicy(docs).effectiveDirectory(dir,true); fail("Must reject ambiguous legacy folder") }
            catch (expected: NativeStorageException) { assertEquals("unresolved",expected.code) }
        }
    }
    @Test fun virtualDuplicateAndAbsentComponentsAreTruthful() {
        val docs = MemoryDocuments(); val policy = SafPolicy(docs)
        assertEquals("absent",policy.deleteComponent(dir,"fixture-a.opus","owned").state)
        docs.entries = listOf(NativeNode("owned","fixture-a.opus",false,true))
        assertEquals("failed",policy.deleteComponent(dir,"fixture-a.opus","owned").state)
        docs.entries = listOf(NativeNode("owned","fixture-a.opus",false),NativeNode("other","fixture-a.opus",false))
        assertEquals("failed",policy.deleteComponent(dir,"fixture-a.opus","owned").state)
        assertTrue(docs.deleted.isEmpty())
    }
}
