// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage

import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class StorageMethodRouterTest {
    private class Reply : StorageReply {
        val successes = mutableListOf<Any?>()
        val errors = mutableListOf<Pair<String, String?>>()
        var unsupported = 0
        override fun success(value: Any?) { successes.add(value) }
        override fun error(code: String, message: String?) { errors.add(code to message) }
        override fun notImplemented() { unsupported++ }
        fun onlySuccess(value: Any?) {
            assertEquals(listOf(value), successes)
            assertTrue(errors.isEmpty()); assertEquals(0, unsupported)
        }
        fun onlyError(code: String) {
            assertTrue(successes.isEmpty()); assertEquals(0, unsupported)
            assertEquals(listOf(code), errors.map { it.first })
        }
    }

    @Test fun removedAndUnknownNamesRejectEveryPayloadBeforeAnyCallbackOrWorker() {
        val methods = listOf("persistRecording", "writeMetadata", "readAudio", "listRecordings",
            "deleteRecording", "hasStorageAccess", "chooseStorageFolder", "fixture-unknown")
        val payloads = listOf(null, emptyMap<String, Any?>(),
            mapOf("id" to "fixture-old", "sourcePath" to "fixture-only/no-file.opus", "metadataJson" to "{}"),
            mapOf("operationId" to "fixture-forged", "binding" to mapOf("key" to
                mapOf("dumpId" to "fixture-bound", "incarnation" to "fixture-incarnation"))),
            "malformed-not-a-map")
        var picker = 0; var awake = 0; var forwarded = 0; var worker = 0
        NativeIoSupervisor(Executors.newSingleThreadExecutor()).use { supervisor ->
            val owner = StorageChannel(supervisor) { _, _ -> worker++; null }
            val router = StorageMethodRouter({ picker++ }, { awake++ }) { method, args ->
                forwarded++; owner.handle(method, args)
            }
            for (method in methods) for (payload in payloads) {
                val reply = Reply(); router.handle(method, payload, reply)
                assertEquals("$method / $payload", 1, reply.unsupported)
                assertTrue(reply.successes.isEmpty()); assertTrue(reply.errors.isEmpty())
                assertEquals(0, picker); assertEquals(0, awake); assertEquals(0, forwarded)
                assertEquals(0, worker); assertTrue(supervisor.retained().isEmpty())
            }
        }
    }

    @Test fun directStorageChannelUnsupportedBoundaryIsSeparateFromOuterRejection() {
        var dispatches = 0
        NativeIoSupervisor(Executors.newSingleThreadExecutor()).use { supervisor ->
            val owner = StorageChannel(supervisor) { _, _ -> dispatches++; null }
            for (method in listOf("persistRecording", "writeMetadata", "readAudio", "listRecordings",
                "deleteRecording", "hasStorageAccess", "chooseStorageFolder", "fixture-unknown")) {
                val error = assertThrows(NativeStorageException::class.java) { owner.handle(method, emptyMap()) }
                assertEquals("unsupported", error.code)
            }
            assertEquals(0, dispatches); assertTrue(supervisor.retained().isEmpty())
        }
    }

    @Test fun everySupportedMethodAndLifecycleRouteForwardsExactMethodAndPayload() {
        val expected = setOf("inspectLegacyStorage", "validateCandidate",
            // Cheap reachability probe: answers "is the folder still there?"
            // without enumerating it. Routing that question to listRecordingsAt
            // cost 5.8s per record tap on a real 81-file folder.
            "probeLocationAt",
            "readAudioAt", "playbackSourceAt",
            "writeMetadataAt", "deleteComponentAt", "listRecordingsAt", "prepareCaptureAt",
            "inspectPreparedCaptureAt", "publishPreparedCaptureAt",
            // Durable notebook documents publish through the same router.
            "publishDocumentAt", "listDocumentsAt", "deleteDocumentAt")
        assertEquals(expected, StorageChannel.methods)
        var picker = 0; var awake = 0
        val calls = mutableListOf<Pair<String, Map<String, Any?>>>()
        val returned = mapOf("fixture" to "unaltered-result")
        val router = StorageMethodRouter({ picker++ }, { awake++ }) { method, args ->
            calls.add(method to args); returned
        }
        for (method in expected + setOf("activeOperations", "operationState", "acknowledgeOperation")) {
            val payload = mapOf("operationId" to "fixture-$method", "binding" to mapOf("key" to
                mapOf("dumpId" to "fixture-forward", "incarnation" to "fixture-incarnation")),
                "capturePayload" to mapOf("fixture" to listOf(null, "unaltered")))
            val reply = Reply(); router.handle(method, payload, reply)
            reply.onlySuccess(returned); assertSame(returned, reply.successes.single())
            assertEquals(method to payload, calls.last())
            assertSame(payload["binding"], calls.last().second["binding"])
            assertSame(payload["capturePayload"], calls.last().second["capturePayload"])
        }
        // One forwarded call per supported method plus the three lifecycle routes.
        assertEquals(expected.size + 3, calls.size); assertEquals(0, picker); assertEquals(0, awake)
    }

    @Test fun routerUsesLiveOwnerAndRealValidationSettlementAndAcknowledgement() {
        NativeIoSupervisor(Executors.newSingleThreadExecutor()).use { supervisor ->
            var dispatched = 0
            val dispatch: (String, Map<String, Any?>) -> Any? = { _, args -> dispatched++; args }
            var owner: StorageChannel? = StorageChannel(supervisor, dispatch)
            val router = StorageMethodRouter({ fail("picker") }, { fail("awake") }) { method, args ->
                (owner ?: throw NativeStorageException("unavailable", "Storage channel detached")).handle(method, args)
            }
            val invalid = Reply(); router.handle("readAudioAt", null, invalid); invalid.onlyError("invalid")
            assertTrue(supervisor.retained().isEmpty())
            owner!!.detach()
            val detached = Reply(); router.handle("activeOperations", null, detached); detached.onlyError("unavailable")
            owner = null
            val missing = Reply(); router.handle("activeOperations", null, missing); missing.onlyError("unavailable")
            owner = StorageChannel(supervisor, dispatch)
            val payload = mapOf("operationId" to "fixture-router-read", "binding" to mapOf("key" to
                mapOf("dumpId" to "fixture-read", "incarnation" to "fixture-incarnation")))
            val submitted = Reply(); router.handle("readAudioAt", payload, submitted)
            submitted.onlySuccess(mapOf("operationId" to "fixture-router-read"))
            supervisor.operation("fixture-router-read")!!.settled.get(5, TimeUnit.SECONDS)
            val inventory = Reply(); router.handle("activeOperations", null, inventory)
            assertEquals("fixture-router-read", ((inventory.successes.single() as List<*>).single() as Map<*,*>)["operationId"])
            val state = Reply(); router.handle("operationState", payload, state)
            state.onlySuccess(mapOf("state" to "settled", "result" to payload))
            val ack = Reply(); router.handle("acknowledgeOperation", payload, ack); ack.onlySuccess(null)
            assertTrue(supervisor.retained().isEmpty()); assertEquals(1, dispatched)
        }
    }

    @Test fun realCaptureValidationAndPreparationAcknowledgementAreNotIntercepted() {
        val fixture = CapturePublicationFixture(); val policy = CapturePublication(fixture)
        NativeIoSupervisor(Executors.newSingleThreadExecutor()).use { supervisor ->
            val owner = StorageChannel(supervisor, policy::execute)
            val router = StorageMethodRouter({ fail("picker") }, { fail("awake") }, owner::handle)
            val args = fixture.args(); val id = args["operationId"] as String
            val invalid = Reply(); router.handle("prepareCaptureAt", args + ("unexpected" to true), invalid)
            invalid.onlyError("invalid"); assertTrue(supervisor.retained().isEmpty())
            val submitted = Reply(); router.handle("prepareCaptureAt", args, submitted)
            submitted.onlySuccess(mapOf("operationId" to id))
            supervisor.operation(id)!!.settled.get(5, TimeUnit.SECONDS)
            val wrongObserve = Reply()
            router.handle("operationState", mapOf("operationId" to id, "capturePayload" to (args + ("metadataJson" to "{}"))), wrongObserve)
            wrongObserve.onlyError("conflict")
            val wrongAck = Reply(); router.handle("acknowledgeOperation", mapOf("operationId" to id), wrongAck)
            wrongAck.onlyError("conflict"); assertNotNull(supervisor.operation(id))
            val rightAck = Reply()
            router.handle("acknowledgeOperation", mapOf("operationId" to id, "preparationOnly" to true), rightAck)
            rightAck.onlySuccess(null); assertNull(supervisor.operation(id)); assertEquals(0, fixture.writes)
        }
    }

    @Test fun delegatedNativeAndUnexpectedErrorsKeepTheirWireMapping() {
        for (error in listOf(NativeStorageException("denied", "fixture-denial"), IllegalStateException("private-detail"))) {
            val router = StorageMethodRouter({ fail("picker") }, { fail("awake") }) { _, _ -> throw error }
            val reply = Reply(); router.handle("readAudioAt", emptyMap<String, Any?>(), reply)
            reply.onlyError(if (error is NativeStorageException) "denied" else "invalid")
            assertEquals(if (error is NativeStorageException) "fixture-denial" else "Invalid storage request", reply.errors.single().second)
        }
    }

    @Test fun screenAwakeExclusivelyEnablesAndDisablesAndReturnsNull() {
        val flags = mutableListOf<Boolean>()
        val router = StorageMethodRouter({ fail("picker") }, { flags.add(it) }) { _, _ -> fail("storage"); null }
        for (enabled in listOf(true, false)) {
            val reply = Reply(); router.handle("setKeepScreenAwake", mapOf("enabled" to enabled), reply)
            reply.onlySuccess(null)
        }
        val missing = Reply(); router.handle("setKeepScreenAwake", null, missing); missing.onlySuccess(null)
        assertEquals(listOf(true, false, false), flags)
    }

    @Test fun pickerCancellationIsNullAndPendingExclusionDoesNotLaunchAgain() {
        var launches = 0; var grants = 0; var candidates = 0
        val picker = CandidatePicker<String>({ launches++ }, { _, _ -> grants++ }, { candidates++; it }, 3)
        val router = StorageMethodRouter(picker::start, { fail("awake") }) { _, _ -> fail("storage"); null }
        val first = Reply(); router.handle("pickDirectory", null, first)
        assertTrue(first.successes.isEmpty()); assertTrue(first.errors.isEmpty())
        val second = Reply(); router.handle("pickDirectory", null, second); second.onlyError("picker_active")
        assertEquals(1, launches)
        picker.complete(false, true, "ignored-other-request", 3)
        assertTrue(first.successes.isEmpty())
        picker.complete(true, false, "ignored-cancelled-selection", 3); first.onlySuccess(null)
        val third = Reply(); router.handle("pickDirectory", null, third)
        picker.complete(true, true, null, 3); third.onlySuccess(null)
        assertEquals(2, launches); assertEquals(0, grants); assertEquals(0, candidates)
    }

    @Test fun pickerForwardsOnlyReadWriteFlagsAndExactCandidateWithoutDefaultMutation() {
        for (flags in listOf(0, 1, 2, 3, 67, 131, 255)) {
            val events = mutableListOf<String>()
            val candidate = mapOf("id" to "fixture-location", "directory" to mapOf("kind" to "saf",
                "treeUri" to "content://fixture/tree/opaque%3Aroot", "authority" to "fixture", "documentId" to "opaque:root", "path" to ""), "label" to "Any folder")
            val picker = CandidatePicker<String>({ events.add("launch") }, { selected, forwarded ->
                assertEquals("content://fixture/tree/opaque%3Aroot", selected)
                assertEquals(flags and 3, forwarded); events.add("grant")
            }, { selected -> assertEquals("content://fixture/tree/opaque%3Aroot", selected); events.add("candidate"); candidate }, 3)
            val reply = Reply(); picker.start(reply)
            picker.complete(true, true, "content://fixture/tree/opaque%3Aroot", flags)
            reply.onlySuccess(candidate); assertSame(candidate, reply.successes.single())
            assertEquals(listOf("launch", "grant", "candidate"), events)
            picker.complete(true, true, "duplicate-result", flags); reply.onlySuccess(candidate)
        }
    }

    @Test fun pickerClearsPendingBeforeCompletionAndPreservesPermissionErrorsAndInterruption() {
        for (failGrant in listOf(true, false)) {
            var candidates = 0
            val picker = CandidatePicker<String>({}, { _, _ -> if (failGrant) throw SecurityException("fixture-grant") }, {
                candidates++; throw IllegalStateException("fixture-candidate")
            }, 3)
            val first = Reply(); picker.start(first); picker.complete(true, true, "fixture-selection", 3)
            first.onlyError("storage_permission")
            assertEquals(if (failGrant) "fixture-grant" else "fixture-candidate", first.errors.single().second)
            assertEquals(if (failGrant) 0 else 1, candidates)
            val pending = Reply(); picker.start(pending); picker.interrupt(); pending.onlyError("activity_destroyed")
            picker.interrupt(); picker.complete(true, true, "late", 3); pending.onlyError("activity_destroyed")
            val next = Reply(); picker.start(next); picker.complete(true, false, null, 0); next.onlySuccess(null)
        }
        lateinit var picker: CandidatePicker<String>
        val nested = Reply()
        picker = CandidatePicker({}, { _, _ -> }, { it }, 3)
        val reentrant = object : StorageReply {
            override fun success(value: Any?) { picker.start(nested) }
            override fun error(code: String, message: String?) { fail(code) }
            override fun notImplemented() { fail("unsupported") }
        }
        picker.start(reentrant); picker.complete(true, false, null, 0)
        assertTrue(nested.errors.isEmpty()); picker.interrupt(); nested.onlyError("activity_destroyed")
    }
}
