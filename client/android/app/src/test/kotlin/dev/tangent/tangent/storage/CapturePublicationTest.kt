// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class CapturePublicationTest {
    @Test fun captureUriMatchesLiteralC1AuthorityAndOpaqueEncoding() {
        val authority="MiXeD.例"
        val uri="content://$authority/tree/root%2Fopaque/document/id%2fCAFÉ+%E4%BE%8B"
        assertEquals(authority to "id/CAFÉ+例",CaptureWire.uri(uri))
        assertEquals(authority,CaptureWire.identity(mapOf("version" to 1,"kind" to "saf-document","scope" to authority,"objectId" to "..","generation" to null))["scope"])
        val f=CapturePublicationFixture()
        val directory=mapOf("version" to 1,"kind" to "saf","path" to "","authority" to authority,"treeUri" to "content://$authority/tree/root%2Fopaque/document/effective%2Fchild","documentId" to "effective/child")
        assertEquals("effective/child",CaptureWire.directory(f.location + ("directory" to directory)).documentId)
    }
    @Test fun captureUriRejectsMalformedUtf8AndNulInEverySegment() {
        for(uri in listOf("content://fixture/document/%FF", "content://fixture/tree/%00/document/id", "content://fixture/tree/%FF/document/id")) {
            assertThrows(NativeStorageException::class.java) { CaptureWire.uri(uri) }
        }
        val f=CapturePublicationFixture()
        val directory=f.location["directory"] as Map<*,*>
        for(tree in listOf("content://capture.fixture/tree/%00","content://capture.fixture/tree/%FF")) {
            assertThrows(NativeStorageException::class.java) { CaptureWire.directory(f.location + ("directory" to (directory + ("treeUri" to tree)))) }
        }
    }
    @Test fun flushFailureAndReadbackMismatchRetainArtifactsWithoutNonemptyRepair() {
        for(corrupt in listOf(false,true)) {
            val fixture=CapturePublicationFixture(); val policy=CapturePublication(fixture)
            val preparation=policy.prepare(fixture.args())["preparation"]
            if(corrupt) fixture.corruptWriteName="fixture-dump.opus" else fixture.flushFailureName="fixture-dump.opus"
            assertThrows(NativeStorageException::class.java) { policy.publish(fixture.preparedArgs(preparation)) }
            assertEquals(1,fixture.writes); assertEquals(2,fixture.creates)
            fixture.corruptWriteName=null; fixture.flushFailureName=null
            if(corrupt) {
                assertEquals("partial",(policy.inspect(fixture.preparedArgs(preparation))["audio"] as Map<*,*>)["state"])
                assertThrows(NativeStorageException::class.java) { policy.publish(fixture.preparedArgs(preparation)) }
                assertEquals(1,fixture.writes)
            } else { policy.publish(fixture.preparedArgs(preparation)); assertEquals(2,fixture.writes) }
            assertEquals(0,fixture.deletes); assertEquals(0,fixture.renames)
        }
    }
    @Test fun emptyTruncatedAndSwappedSourceProofCannotAuthorizeTargetWrites() {
        val zero=CapturePublicationFixture(); zero.source=byteArrayOf()
        assertEquals("notStarted",CapturePublication(zero).prepare(zero.args())["state"]); assertEquals(0,zero.creates)
        for(swapped in listOf(false,true)) {
            val fixture=CapturePublicationFixture(); val policy=CapturePublication(fixture)
            val preparation=policy.prepare(fixture.args())["preparation"]
            if(swapped) fixture.sourceIdentity=fixture.sourceIdentity + ("objectId" to "2") else fixture.source=byteArrayOf(1)
            assertThrows(NativeStorageException::class.java) { policy.publish(fixture.preparedArgs(preparation)) }
            assertEquals(0,fixture.writes); assertEquals(2,fixture.creates)
        }
    }
    @Test fun completePairReconciliationNeedsNoWritableDescriptor() {
        val fixture=CapturePublicationFixture(); val policy=CapturePublication(fixture)
        val prepared=policy.prepare(fixture.args())["preparation"]
        val published=policy.publish(fixture.preparedArgs(prepared))
        fixture.denyWritable=true
        val cold=CapturePublication(fixture)
        assertEquals(published,cold.publish(fixture.preparedArgs(prepared)))
        assertEquals(2,fixture.writes); assertEquals(2,fixture.creates)
    }
    @Test fun frozenMetadataParserUsesRealJsonRuntime() {
        // Exercise the same parser used by CaptureWire, not a mocked success.
        val fixture = CapturePublicationFixture()
        val parsed = org.json.JSONObject(fixture.metadata)
        assertEquals(2, parsed.get("schemaVersion"))
        assertEquals("fixture-dump", parsed.get("id"))
        assertEquals("café 🧪", parsed.get("title"))
        assertTrue(parsed.isNull("transcript"))
        CaptureWire.metadata(fixture.metadata, fixture.reservation)
    }

    private fun call(supervisor:NativeIoSupervisor,channel:StorageChannel,method:String,args:Map<String,Any?>):Map<*,*> {
        val submitted=channel.handle(method,args) as Map<*,*>
        supervisor.operation(submitted["operationId"] as String)!!.settled.get(5,TimeUnit.SECONDS)
        val state=channel.handle("operationState",mapOf("operationId" to submitted["operationId"])) as Map<*,*>
        assertNull(state["problem"])
        return state["result"] as Map<*,*>
    }
    @Test fun productionChannelPublishesAndColdPolicyReconcilesWithoutWrites() {
        val fixture=CapturePublicationFixture(); val policy=CapturePublication(fixture)
        NativeIoSupervisor(Executors.newFixedThreadPool(2)).use { supervisor ->
            val channel=StorageChannel(supervisor,policy::execute)
            val prepared=call(supervisor,channel,"prepareCaptureAt",fixture.args())
            assertEquals("prepared",prepared["state"]); assertEquals(0,fixture.writes)
            assertTrue(fixture.documents.values.all { it.bytes.isEmpty() })
            val publication=call(supervisor,channel,"publishPreparedCaptureAt",fixture.preparedArgs(prepared["preparation"],"fixture-publish"))
            assertEquals(2,fixture.writes); assertEquals(0,fixture.deletes); assertEquals(0,fixture.renames)
            val frozen=prepared["preparation"]
            NativeIoSupervisor(Executors.newSingleThreadExecutor()).use { cold ->
                val coldChannel=StorageChannel(cold,CapturePublication(fixture)::execute)
                val inspected=call(cold,coldChannel,"inspectPreparedCaptureAt",fixture.preparedArgs(frozen))
                assertEquals("complete",(inspected["audio"] as Map<*,*>)["state"])
                assertEquals("complete",(inspected["metadata"] as Map<*,*>)["state"])
                val replay=call(cold,coldChannel,"publishPreparedCaptureAt",fixture.preparedArgs(frozen,"fixture-cold-publish"))
                assertEquals(publication,replay); assertEquals(2,fixture.writes); assertEquals(2,fixture.creates)
            }
            val inventory=channel.handle("activeOperations",emptyMap()) as List<*>
            assertTrue(inventory.any { (it as Map<*,*>)["method"] == "prepareCaptureAt" })
            assertNotNull(supervisor.operation("capture-fixture-reservation-prepare"))
        }
    }
    @Test fun rawReturnSurvivesQueryFailureAndCannotAuthorizeContent() {
        val f=CapturePublicationFixture(); f.failAfterReturn=true
        val p=CapturePublication(f); val result=p.prepare(f.args())
        assertEquals("uncertain",result["state"]); assertEquals(1,(result["rawReturnedLocators"] as List<*>).size)
        assertEquals(1,f.creates); assertEquals(0,f.writes)
        assertThrows(NativeStorageException::class.java) { p.publish(f.preparedArgs(result["preparation"])) }
        assertTrue(f.documents.values.all { it.bytes.isEmpty() })
    }
    @Test fun completedLoadingErrorAndBlankErrorQueriesStayDistinct() {
        for(error in listOf("failure","")) {
            val f=CapturePublicationFixture(); f.queryError=error
            val result=CapturePublication(f).prepare(f.args())
            assertEquals("notStarted",result["state"]); assertEquals(0,f.creates)
        }
        val f=CapturePublicationFixture(); f.loading=true
        assertEquals("notStarted",CapturePublication(f).prepare(f.args())["state"]); assertEquals(0,f.creates)
    }
    @Test fun autoRenameAndAlreadyExistingReturnedIdCannotBeOwned() {
        val renamed=CapturePublicationFixture(); renamed.renamed=true
        val result=CapturePublication(renamed).prepare(renamed.args())
        assertEquals("uncertain",result["state"]); assertEquals(1,(result["rawReturnedLocators"] as List<*>).size)
        assertEquals(0,renamed.writes)
        val alias=CapturePublicationFixture(); val node=NativeNode("opaque:foreign/id","unrelated",false)
        alias.documents[node.id]=CapturePublicationFixture.Document(node,byteArrayOf(8))
        alias.returnedExisting=node.id
        val conflict=CapturePublication(alias).prepare(alias.args())
        assertEquals("uncertain",conflict["state"]); assertEquals(0,alias.writes)
        assertArrayEquals(byteArrayOf(8),alias.documents.getValue(node.id).bytes)
    }
    @Test fun completeAudioEmptyMetadataRetriesOnlyMetadataAndPartialNeverWrites() {
        val f=CapturePublicationFixture(); val p=CapturePublication(f); val prepared=p.prepare(f.args())["preparation"]
        f.writeFailureName="fixture-dump.meta.json"
        assertThrows(NativeStorageException::class.java) { p.publish(f.preparedArgs(prepared)) }
        assertEquals(1,f.writes); f.writeFailureName=null
        p.publish(f.preparedArgs(prepared)); assertEquals(2,f.writes)
        val other=CapturePublicationFixture(); val policy=CapturePublication(other); val claims=policy.prepare(other.args())["preparation"]
        other.documents.values.single { it.node.name.endsWith(".meta.json") }.bytes=byteArrayOf(9)
        assertThrows(NativeStorageException::class.java) { policy.publish(other.preparedArgs(claims)) }
        assertEquals(0,other.writes)
    }
    @Test fun changedSourcePermissionAndDescriptorErrorsRemainFailures() {
        val f=CapturePublicationFixture(); val p=CapturePublication(f); val prepared=p.prepare(f.args())["preparation"]
        f.source=byteArrayOf(9,8,7)
        assertThrows(NativeStorageException::class.java) { p.inspect(f.preparedArgs(prepared)) }
        f.source=byteArrayOf(1,2,3); f.denied=true
        assertThrows(SecurityException::class.java) { p.inspect(f.preparedArgs(prepared)) }
        f.denied=false; f.descriptorError="unsupported"
        val inspection=p.inspect(f.preparedArgs(prepared))
        assertEquals("unknown",(inspection["audio"] as Map<*,*>)["state"])
        assertThrows(NativeStorageException::class.java) { p.publish(f.preparedArgs(prepared)) }; assertEquals(0,f.writes)
    }
    @Test fun replacementDuplicateDirectoryAndVirtualComponentsAreForeign() {
        for(kind in listOf("replacement","duplicate","directory","virtual")) {
            val f=CapturePublicationFixture(); val p=CapturePublication(f); val prepared=p.prepare(f.args())["preparation"]
            val entry=f.documents.values.first(); val old=entry.node
            when(kind) {
                "replacement" -> { f.documents.remove(old.id); val node=old.copy(id="different:opaque/id"); f.documents[node.id]=CapturePublicationFixture.Document(node) }
                "duplicate" -> { val node=old.copy(id="duplicate:opaque/id"); f.documents[node.id]=CapturePublicationFixture.Document(node) }
                "directory" -> entry.node=old.copy(directory=true)
                "virtual" -> entry.node=old.copy(virtual=true)
            }
            assertEquals("foreign",(p.inspect(f.preparedArgs(prepared))["audio"] as Map<*,*>)["state"])
            assertThrows(NativeStorageException::class.java) { p.publish(f.preparedArgs(prepared)) }; assertEquals(0,f.writes)
        }
    }
    @Test fun strictNativeSchemaDigestAndMetadataBytes() {
        assertEquals("18446744073709551615",CaptureWire.unsigned64(-1L))
        assertEquals("9223372036854775808",CaptureWire.unsigned64(Long.MIN_VALUE))
        assertEquals("0",CaptureWire.unsigned64(0L))
        assertEquals("039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81",CaptureWire.sha(byteArrayOf(1,2,3)))
        val f=CapturePublicationFixture()
        assertThrows(NativeStorageException::class.java) { CaptureWire.reservation(f.reservation + ("startedAtMs" to 1.5)) }
        assertThrows(NativeStorageException::class.java) { CaptureWire.reservation(f.reservation + ("phase" to "stopped")) }
        assertThrows(NativeStorageException::class.java) { CaptureWire.reservation(f.reservation + ("mode" to "unknown-mode")) }
        val p=CapturePublication(f); val prepared=p.prepare(f.args())["preparation"]
        p.publish(f.preparedArgs(prepared))
        assertArrayEquals(f.metadata.toByteArray(Charsets.UTF_8),f.documents.values.single { it.node.name.endsWith(".meta.json") }.bytes)
    }
}
