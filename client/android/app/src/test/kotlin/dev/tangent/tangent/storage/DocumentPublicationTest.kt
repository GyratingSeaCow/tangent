// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage

import java.net.URLEncoder
import org.junit.Assert.*
import org.junit.Test

/** Disposable provider primitives only; all ownership policy lives in production. */
private class DocumentFixture : DurableDocumentsPort {
    data class Doc(var node: NativeNode, var bytes: ByteArray = byteArrayOf())

    val directory = NativeDirectory("document.fixture", "content://document.fixture/tree/primary%3Aroot", "primary:root")
    val documents = linkedMapOf<String, Doc>()
    val createdNames = mutableListOf<String>()
    val createdMimes = mutableListOf<String>()
    val deleted = mutableListOf<String>()
    var sequence = 0
    /** AOSP FileSystemProvider behaviour: a requested display name whose final
     *  extension does not match the MIME type gets the MIME extension appended. */
    var aospExtensionRewrite = false
    var denyRename = false
    var childId: String? = null

    val location = mapOf(
        "version" to 1, "id" to "fixture-location", "label" to "fixture root",
        "directory" to mapOf(
            "version" to 1, "kind" to "saf", "path" to "",
            "authority" to directory.authority, "treeUri" to directory.treeUri,
            "documentId" to directory.documentId,
        ),
    )

    fun uri(id: String) =
        "content://${directory.authority}/tree/primary%3Aroot/document/${URLEncoder.encode(id, "UTF-8").replace("+", "%20")}"

    private fun parent(d: NativeDirectory) = d.documentId
    private fun listing(d: NativeDirectory) =
        documents.values.filter { it.node.id.startsWith("${parent(d)}|") }.map { it.node }

    override fun name(directory: NativeDirectory) = "fixture root"
    override fun children(directory: NativeDirectory) = listing(directory)
    override fun uri(directory: NativeDirectory, node: NativeNode) = uri(node.id)
    override fun read(directory: NativeDirectory, node: NativeNode) =
        documents.getValue(node.id).bytes.copyOf()

    override fun write(directory: NativeDirectory, node: NativeNode, bytes: ByteArray) {
        documents.getValue(node.id).bytes = bytes.copyOf()
    }

    private fun mimeExtension(mime: String) = when (mime) {
        "application/json" -> ".json"; "text/markdown" -> ".md"; "audio/ogg" -> ".ogg"; else -> ""
    }

    override fun create(directory: NativeDirectory, name: String, mime: String): NativeNode {
        createdNames.add(name); createdMimes.add(mime)
        if (listing(directory).any { it.name == name }) throw NativeStorageException("conflict", "Target exists")
        val extension = mimeExtension(mime)
        val effective =
            if (aospExtensionRewrite && extension.isNotEmpty() && !name.endsWith(extension)) "$name$extension" else name
        val node = NativeNode("${parent(directory)}|opaque-${sequence++}", effective, false)
        documents[node.id] = Doc(node)
        if (effective != name) throw NativeStorageException("conflict", "Provider changed created identity")
        return node
    }

    override fun createDirectory(directory: NativeDirectory, name: String): NativeNode {
        createdNames.add(name); createdMimes.add(CaptureWire.DIRECTORY_MIME)
        if (listing(directory).any { it.name == name }) throw NativeStorageException("conflict", "Target exists")
        val id = childId ?: "${parent(directory)}|child-${sequence++}"
        val node = NativeNode(id, name, true)
        documents[id] = Doc(node)
        return node
    }

    override fun rename(directory: NativeDirectory, node: NativeNode, name: String): NativeNode {
        if (denyRename) throw NativeStorageException("io", "Provider refused rename")
        if (listing(directory).any { it.name == name && it.id != node.id }) {
            throw NativeStorageException("conflict", "Target exists")
        }
        val doc = documents.getValue(node.id)
        doc.node = doc.node.copy(name = name)
        return doc.node
    }

    override fun delete(directory: NativeDirectory, node: NativeNode): Boolean {
        deleted.add(node.id); return documents.remove(node.id) != null
    }

    /** Seeds a pre-existing child document without going through publication. */
    fun seed(parentId: String, name: String, content: String): NativeNode {
        val node = NativeNode("$parentId|seeded-${sequence++}", name, false)
        documents[node.id] = Doc(node, content.toByteArray(Charsets.UTF_8))
        return node
    }

    fun seedDirectory(name: String, directory_: Boolean = true): NativeNode {
        val node = NativeNode("${directory.documentId}|seeded-${sequence++}", name, directory_)
        documents[node.id] = Doc(node)
        return node
    }
}

class DocumentPublicationTest {
    private fun publishArgs(
        f: DocumentFixture,
        name: String = "fixture-one${DocumentWire.NOTEBOOK_SUFFIX}",
        content: String = "{\"schema\":1}",
        id: String = "fixture-publish-1",
    ) = mapOf(
        "operationId" to id, "location" to f.location,
        "directoryName" to DocumentWire.NOTEBOOK_DIRECTORY,
        "name" to name, "content" to content, "publicationId" to id,
    )

    @Test fun publicationCreatesTheNamedChildAndReturnsTheExactDocumentIdentity() {
        val f = DocumentFixture()
        val result = DocumentPublication(f).execute("publishDocumentAt", publishArgs(f))
        @Suppress("UNCHECKED_CAST") val map = result as Map<String, Any?>
        assertEquals("fixture-one${DocumentWire.NOTEBOOK_SUFFIX}", map["name"])
        assertEquals("{\"schema\":1}", map["content"])
        val locator = map["locator"] as Map<*, *>
        assertEquals("saf", locator["kind"])
        // The child directory is created exactly once, with the directory MIME.
        assertEquals(CaptureWire.DIRECTORY_MIME, f.createdMimes.first())
        assertEquals(DocumentWire.NOTEBOOK_DIRECTORY, f.createdNames.first())
        // Content lands INSIDE the child, never at the tree root.
        val child = f.documents.values.single { it.node.directory }
        val published = f.documents.values.single { it.node.name.endsWith(DocumentWire.NOTEBOOK_SUFFIX) }
        assertTrue(published.node.id.startsWith("${child.node.id}|"))
        assertEquals("{\"schema\":1}", String(published.bytes, Charsets.UTF_8))
        assertEquals(f.uri(published.node.id), locator["value"])
        // Republication reuses the same child: resolve-or-create is idempotent.
        DocumentPublication(f).execute("publishDocumentAt", publishArgs(f, content = "{\"schema\":1,\"v\":2}", id = "fixture-publish-2"))
        assertEquals(1, f.documents.values.count { it.node.directory })
        assertEquals(1, f.documents.values.count { it.node.name.endsWith(DocumentWire.NOTEBOOK_SUFFIX) })
        assertEquals(
            "{\"schema\":1,\"v\":2}",
            String(f.documents.values.single { it.node.name.endsWith(DocumentWire.NOTEBOOK_SUFFIX) }.bytes, Charsets.UTF_8),
        )
    }

    /** Regression: the AOSP FileSystemProvider RENAMES a created temp whose
     *  extension does not match its MIME type. A non-MIME-coherent temp name
     *  made publication fail on device; the temp must end in '.json'. */
    @Test fun temporaryDocumentNamesStayMimeCoherentUnderAospExtensionRewriting() {
        val f = DocumentFixture()
        f.aospExtensionRewrite = true
        val result = DocumentPublication(f).execute("publishDocumentAt", publishArgs(f))
        @Suppress("UNCHECKED_CAST") val map = result as Map<String, Any?>
        assertEquals("fixture-one${DocumentWire.NOTEBOOK_SUFFIX}", map["name"])
        val temp = f.createdNames.single { it.startsWith(".") }
        assertTrue("Temp name must end in the MIME extension: $temp", temp.endsWith(".json"))
        assertTrue(temp.contains(".partial"))
        // Shared rule with the capture publisher; one spelling, one behaviour.
        assertEquals(".json", DocumentWire.tempExtension("application/json"))
        assertEquals(".md", DocumentWire.tempExtension("text/markdown"))
        assertEquals(".ogg", DocumentWire.tempExtension("audio/ogg"))
        assertEquals("", DocumentWire.tempExtension("application/octet-stream"))
    }

    @Test fun failedPublicationDeletesOnlyItsOwnTemporaryAndKeepsThePriorCopy() {
        val f = DocumentFixture()
        DocumentPublication(f).execute("publishDocumentAt", publishArgs(f, content = "good"))
        val survivor = f.documents.values.single { it.node.name.endsWith(DocumentWire.NOTEBOOK_SUFFIX) }
        f.denyRename = true
        val error = assertThrows(NativeStorageException::class.java) {
            DocumentPublication(f).execute("publishDocumentAt", publishArgs(f, content = "torn", id = "fixture-publish-3"))
        }
        assertEquals("io", error.code)
        assertEquals("good", String(survivor.bytes, Charsets.UTF_8))
        assertTrue(f.documents.containsKey(survivor.node.id))
        assertEquals(1, f.documents.values.count { it.node.name.endsWith(DocumentWire.NOTEBOOK_SUFFIX) })
        // Only this operation's own temp was cleaned up; nothing else deleted.
        assertEquals(1, f.deleted.size)
        assertFalse(f.deleted.contains(survivor.node.id))
    }

    @Test fun aNonDirectoryHoldingTheChildNameIsAConflictNotARootFallback() {
        val f = DocumentFixture()
        f.seedDirectory(DocumentWire.NOTEBOOK_DIRECTORY, directory_ = false)
        val error = assertThrows(NativeStorageException::class.java) {
            DocumentPublication(f).execute("publishDocumentAt", publishArgs(f))
        }
        assertEquals("conflict", error.code)
        assertTrue(f.documents.values.none { it.node.name.endsWith(DocumentWire.NOTEBOOK_SUFFIX) })
    }

    @Test fun enumerationReadsOnlyMatchingChildrenAndAnAbsentChildIsEmpty() {
        val f = DocumentFixture()
        val listArgs = mapOf(
            "operationId" to "fixture-list", "location" to f.location,
            "directoryName" to DocumentWire.NOTEBOOK_DIRECTORY, "suffix" to DocumentWire.NOTEBOOK_SUFFIX,
        )
        assertEquals(emptyList<Any?>(), DocumentPublication(f).execute("listDocumentsAt", listArgs))
        val child = f.seedDirectory(DocumentWire.NOTEBOOK_DIRECTORY)
        f.seed(child.id, "fixture-a${DocumentWire.NOTEBOOK_SUFFIX}", "{\"a\":1}")
        f.seed(child.id, "fixture-b${DocumentWire.NOTEBOOK_SUFFIX}", "{\"b\":2}")
        f.seed(child.id, "unrelated.txt", "ignored")
        f.seed(f.directory.documentId, "fixture-root${DocumentWire.NOTEBOOK_SUFFIX}", "root-level")
        @Suppress("UNCHECKED_CAST")
        val rows = DocumentPublication(f).execute("listDocumentsAt", listArgs) as List<Map<String, Any?>>
        assertEquals(listOf("fixture-a${DocumentWire.NOTEBOOK_SUFFIX}", "fixture-b${DocumentWire.NOTEBOOK_SUFFIX}"), rows.map { it["name"] })
        assertEquals(listOf("{\"a\":1}", "{\"b\":2}"), rows.map { it["content"] })
        assertTrue(rows.all { (it["locator"] as Map<*, *>)["kind"] == "saf" })
    }

    @Test fun deletionResolvesTheOpaqueLocatorAndIsIdempotent() {
        val f = DocumentFixture()
        @Suppress("UNCHECKED_CAST")
        val published = DocumentPublication(f).execute("publishDocumentAt", publishArgs(f)) as Map<String, Any?>
        fun delete(locator: Any?, name: Any? = published["name"]) = DocumentPublication(f).execute(
            "deleteDocumentAt",
            mapOf(
                "operationId" to "fixture-delete", "location" to f.location,
                "directoryName" to DocumentWire.NOTEBOOK_DIRECTORY, "name" to name,
                "locator" to locator, "deletionId" to "fixture-delete",
            ),
        ) as Map<*, *>
        // A foreign locator is refused: the name alone never authorizes deletion.
        val foreign = delete(mapOf("version" to 1, "kind" to "saf", "value" to f.uri("primary:root|not-mine")))
        assertEquals("failed", foreign["state"])
        assertEquals(1, f.documents.values.count { it.node.name.endsWith(DocumentWire.NOTEBOOK_SUFFIX) })
        assertEquals("removed", delete(published["locator"])["state"])
        assertTrue(f.documents.values.none { it.node.name.endsWith(DocumentWire.NOTEBOOK_SUFFIX) })
        assertEquals("absent", delete(published["locator"])["state"])
    }

    @Test fun malformedDocumentPayloadsAreRejectedBeforeAnyProviderMutation() {
        val f = DocumentFixture()
        val base = publishArgs(f)
        val rejected = listOf(
            base - "name",
            base + ("name" to "../escape.json"),
            base + ("name" to ""),
            base + ("directoryName" to "../Tangent Notebooks"),
            base + ("directoryName" to ""),
            base + ("content" to 42),
            base + ("location" to mapOf("version" to 1, "id" to "x", "label" to "y", "directory" to mapOf("version" to 1, "kind" to "file", "path" to "/tmp", "authority" to "", "treeUri" to "", "documentId" to ""))),
        )
        for (args in rejected) {
            val error = assertThrows("Accepted $args", NativeStorageException::class.java) {
                DocumentPublication(f).execute("publishDocumentAt", args)
            }
            assertEquals("invalid", error.code)
        }
        assertTrue(f.documents.isEmpty())
        assertTrue(f.createdNames.isEmpty())
        assertTrue(f.deleted.isEmpty())
        val unsupported = assertThrows(NativeStorageException::class.java) {
            DocumentPublication(f).execute("fixture-unknown", base)
        }
        assertEquals("unsupported", unsupported.code)
    }

    @Test fun theNotebookDirectoryLiteralMatchesTheDartConstantAndIsATextNoteSibling() {
        assertEquals("Tangent Notebooks", DocumentWire.NOTEBOOK_DIRECTORY)
        assertEquals(".notebook.json", DocumentWire.NOTEBOOK_SUFFIX)
        assertNotEquals(CaptureWire.TEXT_NOTE_DIRECTORY, DocumentWire.NOTEBOOK_DIRECTORY)
    }
}
