// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*

class LegacyStorageInspectionTest {
    private val a = "content://Fixture.Provider/tree/A%2fopaque/document/not-the-root"
    private val b = "content://Fixture.Provider/tree/B"
    private class Provider {
        var preference: Any? = null
        var reads = 0
        var calls = mutableListOf<NativeDirectory>()
        var denied = false
        var wrong = false
        var wrongEffective = false
        var loading = false
        var queryError: String? = null
        var directory = true
        var virtual = false
        var selectedName = "Tangent"
        var childRows = listOf(NativeNode("effective/child", "Tangent", true))
        val inspection = LegacyStorageInspection({ reads++; preference }, { d ->
            calls.add(d)
            if (denied) throw NativeStorageException("denied", "synthetic")
            ProviderQuerySnapshot(listOf(NativeNode(if (wrong || (wrongEffective && d.documentId == "effective/child")) "foreign" else d.documentId,
                if (d.documentId == "effective/child") "Tangent" else selectedName, directory, virtual)), loading, queryError).completedRows()
        }, { _ -> childRows })
    }
    @Test fun captureNeverTouchesEvenDeniedProvider() {
      for (denied in listOf(false, true)) {
        val p = Provider(); p.preference = a; p.denied = denied
        val result = p.inspection.inspect(null)!!
        assertNull(result["location"])
        assertEquals(a, LegacyStorageInspection.decodeAnchor(result["anchorJson"] as String)["selectedTreeUri"])
        assertEquals(1, p.reads); assertTrue(p.calls.isEmpty())
      }
    }
    @Test fun resolutionUsesFrozenSourceAndExactBytesNeverPreferences() {
        val p = Provider(); p.preference = b
        val anchor = "  " + LegacyStorageInspection.encodeAnchor(a) + "\n"
        val result = p.inspection.inspect(anchor)!!
        assertEquals(anchor, result["anchorJson"])
        val directory = (result["location"] as Map<*, *>)["directory"] as Map<*, *>
        assertEquals(a, directory["treeUri"])
        assertEquals("A/opaque", directory["documentId"])
        assertEquals("Fixture.Provider", directory["authority"])
        assertEquals(0, p.reads)
    }
    @Test fun wrongSelectedIdentityIsNeverDirectoryProof() {
        val p = Provider(); p.wrong = true; p.preference = a
        val result = p.inspection.inspect(LegacyStorageInspection.encodeAnchor(a))!!
        assertNull(result["location"])
    }
    @Test fun absentEmptyAndReadFailureAreDifferent() {
        val p = Provider()
        assertNull(p.inspection.inspect(null))
        for (s in listOf("", "bad URI", "content://fixture/tree/%FF", "\u0000")) {
            p.preference = s
            val captured = p.inspection.inspect(null)!!
            assertNull(captured["location"])
            val anchor = captured["anchorJson"] as String
            assertEquals(s, LegacyStorageInspection.decodeAnchor(anchor)["selectedTreeUri"])
            assertNull(p.inspection.inspect(anchor)!!["location"])
        }
        assertTrue(p.calls.isEmpty())
        p.preference = 42
        assertEquals("invalid", assertThrows(NativeStorageException::class.java) { p.inspection.inspect(null) }.code)
        for ((error, code) in listOf(ClassCastException() to "invalid", SecurityException() to "denied", java.io.IOException() to "io")) {
            val inspection = LegacyStorageInspection({ throw error }, { error("no provider") }, { error("no provider") })
            assertEquals(code, assertThrows(NativeStorageException::class.java) { inspection.inspect(null) }.code)
        }
        val anchor = " \n" + LegacyStorageInspection.encodeAnchor(null)
        p.preference = b
        val reads = p.reads
        assertEquals(mapOf("location" to null, "anchorJson" to anchor), p.inspection.inspect(anchor))
        assertEquals(reads, p.reads)
    }
    @Test fun envelopeRejectsMalformedMixedUnknownAndWrongTypedWithoutFallback() {
        val p = Provider(); p.preference = b
        val good = LegacyStorageInspection.encodeAnchor(a)
        for (bad in listOf<Any>(42, "", "null", "[]", "{}", "{", good + " trailing",
            good.replace("\"version\":1", "\"version\":1.0"), good.replace("\"version\":1", "\"version\":2"),
            good.replace("legacy-saf-selection", "legacy-file-root"), good.replace("tree-root-documents-or-tangent-v1", "unknown"),
            good.replace("\"selectedTreeUri\"", "\"path\""), good.replace("}", ",\"foreign\":null}"),
            "{\"version\":1,\"kind\":\"legacy-saf-selection\",\"policy\":\"tree-root-documents-or-tangent-v1\",\"selectedTreeUri\":1}",
            "{'version':1}", good.replace("\"version\":1", "\"version\":01"), good.replace("}", ",}"))) {
            assertEquals("invalid", assertThrows(NativeStorageException::class.java) { p.inspection.inspect(bad) }.code)
        }
        assertEquals(0, p.reads); assertTrue(p.calls.isEmpty())
    }
    @Test fun literalSelectionParityUsesTreeRootEvenForTreeDocumentUri() {
        for (authority in listOf("fixture", "FiXtUrE.Provider", "MiXeD.例")) {
            for ((encoded, expected) in listOf("." to ".", ".." to "..", "%2e%2E" to "..", "folder%2Fclip%3A100%25" to "folder/clip:100%", "%252F" to "%2F", "%E5%BD%95%E9%9F%B3" to "录音", "录音-é" to "录音-é", "é%2F录音%25" to "é/录音%")) {
                for (suffix in listOf("", "/document/not-the-root")) {
                    val uri = "content://$authority/tree/$encoded$suffix"
                    assertEquals(NativeDirectory(authority, uri, expected), LegacyStorageInspection.selection(uri))
                }
            }
        }
        for (bad in listOf("content://[bad]/tree/A", "content://fixture]/tree/A", "content://fixture/document/audio", "content://fixture/garbage/../tree/root", "content://fixture/tree/", "content://fixture/tree/A/document/", "content://fixture/tree/A/", "content://user@fixture/tree/A", "content://fixture:80/tree/A", "content://fixture/tree/A?q=1", "content://fixture/tree/A#fragment") +
            listOf("%", "%ZZ", "%0", "%00", "%FF", "%C0%AF").map { "content://fixture/tree/$it" }) {
            val p = Provider()
            val anchor = LegacyStorageInspection.encodeAnchor(bad)
            assertEquals(mapOf("location" to null, "anchorJson" to anchor), p.inspection.inspect(anchor))
            assertTrue(p.calls.isEmpty())
        }
    }
    @Test fun legacyDocumentsDirectAndUnresolvedCasesPreserveAnchorThenRecover() {
        val p = Provider(); val anchor = LegacyStorageInspection.encodeAnchor(a)
        p.selectedName = "Documents"
        val result = p.inspection.inspect(anchor)!!
        assertEquals("effective/child", ((result["location"] as Map<*, *>)["directory"] as Map<*, *>)["documentId"])
        p.wrongEffective = true; assertNull(p.inspection.inspect(anchor)!!["location"]); p.wrongEffective = false
        for (children in listOf(emptyList(), listOf(NativeNode("x", "Tangent", false)), listOf(NativeNode("x", "Tangent", true, true)), listOf(NativeNode("x", "Tangent", true), NativeNode("y", "Tangent", true)))) {
            p.childRows = children; assertEquals(mapOf("location" to null, "anchorJson" to anchor), p.inspection.inspect(anchor))
        }
        p.selectedName = "unknown"; assertNull(p.inspection.inspect(anchor)!!["location"])
        p.selectedName = "tAnGeNt"
        p.directory = false; assertNull(p.inspection.inspect(anchor)!!["location"]); p.directory = true
        p.virtual = true; assertNull(p.inspection.inspect(anchor)!!["location"]); p.virtual = false
        p.denied = true; assertNull(p.inspection.inspect(anchor)!!["location"]); p.denied = false
        p.loading = true; assertNull(p.inspection.inspect(anchor)!!["location"]); p.loading = false
        p.queryError = "synthetic"; assertNull(p.inspection.inspect(anchor)!!["location"]); p.queryError = null
        assertNotNull(p.inspection.inspect(anchor)!!["location"])
        assertEquals(0, p.reads)
    }
    @Test fun realChannelRetainsCaptureAndFrozenResolutionAcrossOwnerReplacement() {
        for (resolve in listOf(false, true)) {
            val entered = CountDownLatch(1); val release = CountDownLatch(1)
            val supervisor = NativeIoSupervisor(Executors.newFixedThreadPool(2))
            val anchor = "  " + LegacyStorageInspection.encodeAnchor(a) + "\n"
            var reads = 0
            val inspection = LegacyStorageInspection({ reads++; entered.countDown(); check(release.await(5, TimeUnit.SECONDS)); a },
                { d -> entered.countDown(); check(release.await(5, TimeUnit.SECONDS)); listOf(NativeNode(d.documentId, "Tangent", true)) }, { emptyList() })
            val dispatch: (String, Map<String, Any?>) -> Any? = { method, args ->
                assertEquals("inspectLegacyStorage", method); inspection.inspect(args["frozenAnchorJson"])
            }
            val args = mutableMapOf<String, Any?>("operationId" to "fixture-legacy-$resolve")
            if (resolve) args["frozenAnchorJson"] = anchor
            try {
                val old = StorageChannel(supervisor, dispatch); old.handle("inspectLegacyStorage", args)
                assertTrue(entered.await(5, TimeUnit.SECONDS)); old.detach()
                val replacement = StorageChannel(supervisor, dispatch)
                assertEquals("pending", (replacement.handle("operationState", args) as Map<*, *>)["state"])
                assertEquals(1, (replacement.handle("activeOperations", emptyMap()) as List<*>).size)
                release.countDown(); supervisor.operation(args["operationId"] as String)!!.settled.get(5, TimeUnit.SECONDS)
                val state = replacement.handle("operationState", args) as Map<*, *>
                val result = state["result"] as Map<*, *>
                assertEquals(if (resolve) anchor else LegacyStorageInspection.encodeAnchor(a), result["anchorJson"])
                assertEquals(!resolve, result["location"] == null)
                assertEquals(if (resolve) 0 else 1, reads)
                replacement.detach(); val third = StorageChannel(supervisor, dispatch)
                assertEquals(state, third.handle("operationState", args))
                third.handle("acknowledgeOperation", args); assertNull(supervisor.operation(args["operationId"] as String))
            } finally { release.countDown(); supervisor.close() }
        }
    }
}
