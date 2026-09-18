// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class CapturePublicationTest {
    /**
     * The MIME type must agree with the filename's extension.
     *
     * AOSP's FileSystemProvider appends a MIME-derived extension when the two
     * disagree, so declaring audio/ogg for a .wav published "<id>.wav.oga" on
     * a Galaxy Tab S10 FE: unplayable, and invisible to the app's own lookup.
     */
    @Test fun amplifiedWavPublishesWithAWavMimeType() {
        assertEquals("audio/wav", CaptureWire.audioMimeForSuffix(".wav"))
    }

    @Test fun opusKeepsItsOggMimeType() {
        assertEquals("audio/ogg", CaptureWire.audioMimeForSuffix(".opus"))
    }

    @Test fun textNotesKeepTheirMarkdownMimeType() {
        assertEquals("text/markdown", CaptureWire.audioMimeForSuffix(".md"))
    }

    @Test fun anUnknownSuffixFallsBackToTheAudioDefault() {
        assertEquals("audio/ogg", CaptureWire.audioMimeForSuffix(""))
    }

    @Test fun androidSourceSearchOnlyAncestryPreparesBeforeAnyContentWrite() {
        CaptureSourceFixture().use { source ->
            val fixture = CapturePublicationFixture()
            fixture.sourceReader = { source.read(it) }
            val reservation = fixture.reservation + ("stagingPath" to source.path)
            val args = fixture.args() + ("reservation" to reservation)
            NativeIoSupervisor(Executors.newSingleThreadExecutor()).use { supervisor ->
                val channel = StorageChannel(supervisor, CapturePublication(fixture)::execute)
                val result = call(supervisor, channel, "prepareCaptureAt", args)
                assertEquals("prepared", result["state"])
                assertEquals(source.path, (result["preparation"] as Map<*, *>)["stagingPath"])
                assertEquals(2, fixture.creates); assertEquals(0, fixture.writes)
            }
        }
    }

    @Test fun androidSourceAllowsOnlyTrustedRootAliasesWithoutRewritingOriginalPath() {
        CaptureSourceFixture(alias = true).use { f ->
            assertArrayEquals(byteArrayOf(1, 2, 3), f.read().bytes)
            assertArrayEquals(byteArrayOf(1, 2, 3), f.read("${f.canonical}/TangentStaging/fixture-reservation.opus").bytes)
            assertTrue(f.canonicalCalls.isNotEmpty())
            assertTrue(f.canonicalCalls.all { it == f.root })
            assertTrue(f.opens.all { it == f.root || it == f.canonical })
        }
    }
    @Test fun androidSourceRejectsForeignPrefixAndTraversalBeforeOpeningSource() {
        CaptureSourceFixture(readableAncestors = true).use { f ->
            val foreign = f.root.substringBefore("/data/") + "/foreign/fixture-reservation.opus"
            for (path in listOf(foreign, f.root + "-sibling/TangentStaging/fixture-reservation.opus",
                f.root + "/../cache/TangentStaging/fixture-reservation.opus", f.root + "/./TangentStaging/fixture-reservation.opus",
                f.path + "/", f.path + '\u0000', "relative.opus", f.root)) {
                assertThrows(NativeStorageException::class.java) { f.read(path) }
            }
            assertTrue("Invalid containment must fail before source open", f.opens.isEmpty())
        }
    }
    @Test fun androidSourceRejectsSuffixFinalCacheAndApplicationLinks() {
        for (kind in listOf("finalLink", "suffixLink", "rootLink", "appLink", "directoryFile")) {
            CaptureSourceFixture(readableAncestors = true).use { f ->
                f.change(kind)
                assertThrows(NativeStorageException::class.java) { f.read() }
            }
        }
    }
    @Test fun androidSourceRejectsReplacementAndRootSwapEvenWithSameFinalInode() {
        for (kind in listOf("replaceFile", "rootSwap", "suffixSwap")) {
            CaptureSourceFixture(readableAncestors = true).use { f ->
                var reached = false
                f.afterRead = { f.change(kind); reached = true }
                assertThrows(NativeStorageException::class.java) { f.read() }
                assertTrue("Mutation barrier must actually execute: $kind", reached)
            }
        }
    }

    @Test fun androidSourceAliasProofSurvivesPreparePublishAndColdInspect() {
        CaptureSourceFixture(alias = true).use { f ->
            val fixture = CapturePublicationFixture()
            fixture.sourceReader = { f.read(it) }
            val reservation = fixture.reservation + ("stagingPath" to f.path)
            val policy = CapturePublication(fixture)
            val prepared = policy.prepare(fixture.args() + ("reservation" to reservation))
            assertEquals("prepared", prepared["state"])
            val proof = prepared["preparation"] as Map<*, *>
            assertEquals(f.path, proof["stagingPath"])
            val args = fixture.preparedArgs(proof) + ("reservation" to reservation)
            policy.publish(args)
            val cold = CapturePublication(fixture)
            assertEquals("complete", (cold.inspect(args)["audio"] as Map<*, *>)["state"])
            assertEquals(2, fixture.writes)
            f.change("replaceFile") // identical bytes, different opened-file identity
            assertThrows(NativeStorageException::class.java) { cold.publish(args) }
            assertEquals(2, fixture.writes); assertEquals(2, fixture.creates)
        }
    }
    @Test fun androidSourceDetectsLinksIntroducedDuringRead() {
        for (kind in listOf("finalLink", "suffixLink", "rootLink", "appLink")) {
            CaptureSourceFixture(alias = true).use { f ->
                var reached = false
                f.afterRead = { f.change(kind); reached = true }
                assertThrows(NativeStorageException::class.java) { f.read() }
                assertTrue(reached)
            }
        }
    }
    @Test fun androidSourceRejectsNonPlatformAliasOwnershipAtDecisionSeam() {
        CaptureSourceFixture(alias = true).use { f ->
            // Inject only ownership metadata; real-host gate still performs actual
            // lstat. Never chown a fixture or system path to fake another UID.
            val io = object : AndroidCaptureSource.Io<Int> by f.io {
                override fun lstat(path: String): AndroidCaptureSource.Node {
                    val node = f.io.lstat(path)
                    return if (node.link) node.copy(uid = 12345) else node
                }
            }
            assertThrows(NativeStorageException::class.java) { AndroidCaptureSource(f.root, io).read(f.path) }
            assertTrue(f.opens.isEmpty())
        }
    }
    @Test fun androidSourceRejectsRootSwapBetweenValidationAndPinAndClosesFailedStat() {
        for (statFailure in listOf(false, true)) {
            CaptureSourceFixture().use { f ->
                var reached = false
                val io = object : AndroidCaptureSource.Io<Int> by f.io {
                    override fun open(path: String): Int {
                        reached = true
                        if (!statFailure) f.change("rootSwap")
                        return f.io.open(path)
                    }
                    override fun stat(handle: Int): AndroidCaptureSource.Node {
                        if (statFailure) throw NativeStorageException("io", "Injected fstat failure after open")
                        return f.io.stat(handle)
                    }
                }
                assertThrows(NativeStorageException::class.java) { AndroidCaptureSource(f.root, io).read(f.path) }
                assertTrue(reached)
            } // teardown asserts zero outstanding descriptors on every failure
        }
    }

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

    // An amplified capture (microphone gain above unity) is raw PCM in a WAV
    // container, not Opus. The suffix therefore comes from the reservation's
    // own staging path: recomputing it from the mode here would reject a valid
    // reservation as "Invalid reservation staging path" and lose a finished
    // recording at save time.
    @Test fun amplifiedCaptureAcceptsWavStagingPath() {
        val f=CapturePublicationFixture()
        val reservation=f.reservation + mapOf("stagingPath" to "/fixture/fixture-reservation.wav")
        CaptureWire.reservation(reservation)
        assertEquals(".wav",CaptureWire.contentSuffix("brain_dump","/fixture/fixture-reservation.wav"))
    }

    @Test fun unityGainStillUsesOpus() {
        assertEquals(".opus",CaptureWire.contentSuffix("brain_dump","/fixture/fixture-reservation.opus"))
    }

    @Test fun textNoteIgnoresAudioSuffixes() {
        assertEquals(".md",CaptureWire.contentSuffix("text_note","/fixture/fixture-reservation.md"))
    }

    // A staging path with an extension nothing can publish must fault rather
    // than silently publishing a file the SAF port can never find again.
    @Test fun unknownAudioSuffixIsRejected() {
        val f=CapturePublicationFixture()
        val reservation=f.reservation + mapOf("stagingPath" to "/fixture/fixture-reservation.mp3")
        assertThrows(NativeStorageException::class.java) { CaptureWire.reservation(reservation) }
    }

    private fun noteArgs(f:CapturePublicationFixture):Map<String,Any?> {
        val reservation=f.reservation + mapOf("mode" to "text_note","stagingPath" to "/fixture/fixture-reservation.md")
        val metadata="{ \"schemaVersion\": 2, \"id\": \"fixture-dump\", \"mode\": \"text_note\", \"title\": \"café 🧪\", \"transcript\": \"body\" }"
        return mapOf("operationId" to "capture-fixture-reservation-prepare","reservation" to reservation,"metadataJson" to metadata,"audioSha256" to CaptureWire.sha(f.source))
    }
    @Test fun textNotePairPublishesInsideCreatedTangentTextNotesDirectory() {
        val f=CapturePublicationFixture(); val p=CapturePublication(f)
        val args=noteArgs(f)
        val prepared=p.prepare(args)
        assertEquals("prepared",prepared["state"])
        val directories=f.documents.values.filter { it.node.directory }
        assertEquals(1,directories.size)
        assertEquals(CaptureWire.TEXT_NOTE_DIRECTORY,directories.single().node.name)
        assertTrue(f.documents.values.any { it.node.name == "fixture-dump.md" && !it.node.directory })
        assertTrue(f.documents.values.any { it.node.name == "fixture-dump.meta.json" && !it.node.directory })
        val publishArgs=args + mapOf("operationId" to "fixture-note-publish","preparation" to prepared["preparation"])
        p.publish(publishArgs)
        assertEquals(2,f.writes)
        val cold=CapturePublication(f)
        assertEquals("complete",(cold.inspect(publishArgs)["audio"] as Map<*,*>)["state"])
        assertEquals("complete",(cold.inspect(publishArgs)["metadata"] as Map<*,*>)["state"])
    }
    @Test fun textNoteReusesExistingDirectoryAndRejectsNonDirectoryHomonym() {
        val existing=CapturePublicationFixture()
        val node=NativeNode("existing:notes/dir",CaptureWire.TEXT_NOTE_DIRECTORY,true)
        existing.documents[node.id]=CapturePublicationFixture.Document(node)
        val prepared=CapturePublication(existing).prepare(noteArgs(existing))
        assertEquals("prepared",prepared["state"])
        // Reuse: exactly the two content creates; no second directory create.
        assertEquals(2,existing.creates)
        assertEquals(1,existing.documents.values.count { it.node.directory })
        val foreign=CapturePublicationFixture()
        val file=NativeNode("foreign:notes/file",CaptureWire.TEXT_NOTE_DIRECTORY,false)
        foreign.documents[file.id]=CapturePublicationFixture.Document(file,byteArrayOf(7))
        val conflicted=CapturePublication(foreign).prepare(noteArgs(foreign))
        assertEquals("notStarted",conflicted["state"])
        assertEquals("conflict",(conflicted["problem"] as Map<*,*>)["code"])
        assertEquals(0,foreign.creates)
        assertArrayEquals(byteArrayOf(7),foreign.documents.getValue(file.id).bytes)
    }
    @Test fun audioModesNeverCreateTheTextNoteDirectory() {
        val f=CapturePublicationFixture(); val p=CapturePublication(f)
        val prepared=p.prepare(f.args())
        assertEquals("prepared",prepared["state"])
        assertEquals(2,f.creates)
        assertTrue(f.documents.values.none { it.node.directory })
        p.publish(f.preparedArgs(prepared["preparation"]))
        assertTrue(f.documents.values.none { it.node.name == CaptureWire.TEXT_NOTE_DIRECTORY })
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
