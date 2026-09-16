// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage
import java.util.concurrent.*
import org.junit.Assert.*
import org.junit.Test
class NativeIoSupervisorTest {
    @Test fun renamedProbeReceiptsSurviveWorkerSettlementAndChannelReplacement() {
        for (cleanupThrows in listOf(false, true)) {
            val entered = CountDownLatch(1); val release = CountDownLatch(1)
            val supervisor = NativeIoSupervisor(Executors.newFixedThreadPool(2))
            val receipts = ProbeReceipts()
            val port = ProbeRenameFailureFixture(receipts, cleanupThrows) {
                entered.countDown(); check(release.await(5, TimeUnit.SECONDS))
            }
            val dispatch: (String, Map<String, Any?>) -> Any? = { _, _ ->
                receipts.capture { SafPolicy(port).probe(ProbeRenameFailureFixture.DIRECTORY, "fixture-probe") }
            }
            val args = mapOf("operationId" to "fixture-probe-$cleanupThrows")
            try {
                val old = StorageChannel(supervisor, dispatch)
                old.handle("validateCandidate", args)
                assertTrue(entered.await(5, TimeUnit.SECONDS))
                old.detach()
                val replacement = StorageChannel(supervisor, dispatch)
                assertEquals("pending", (replacement.handle("operationState", args) as Map<*, *>)["state"])
                release.countDown()
                supervisor.operation(args["operationId"]!!)!!.settled.get(5, TimeUnit.SECONDS)
                val state = replacement.handle("operationState", args) as Map<*, *>
                assertEquals("settled", state["state"])
                assertEquals(mapOf("owned" to listOf(ProbeRenameFailureFixture.A, ProbeRenameFailureFixture.B), "cleaned" to false), state["result"])
                assertEquals(listOf("A/opaque"), port.deleted)
                assertEquals(setOf("unrelated", "B/Opaque"), port.nodes.map { it.id }.toSet())
                replacement.detach()
                val third = StorageChannel(supervisor, dispatch)
                assertEquals(state, third.handle("operationState", args))
                third.handle("acknowledgeOperation", args)
                assertNull(supervisor.operation(args["operationId"]!!))
            } finally { release.countDown(); supervisor.close() }
        }
    }
    @Test fun detachedRealStorageChannelReattachesSettlementAndRetainedResult() {
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val deleted = CountDownLatch(1)
        val supervisor = NativeIoSupervisor(Executors.newFixedThreadPool(2))
        val key = mapOf("dumpId" to "fixture-a", "incarnation" to "inc-a")
        val binding = mapOf("key" to key)
        val writeArgs = mapOf("operationId" to "fixture-write", "binding" to binding)
        val deleteArgs = mapOf("operationId" to "fixture-delete", "binding" to binding)
        val dispatch: (String,Map<String,Any?>)->Any? = { method,_ ->
            if (method == "writeMetadataAt") { entered.countDown(); check(release.await(5,TimeUnit.SECONDS)); "written" }
            else { deleted.countDown(); "deleted" }
        }
        try {
            val old = StorageChannel(supervisor,dispatch)
            old.handle("writeMetadataAt",writeArgs)
            assertTrue(entered.await(5,TimeUnit.SECONDS)); old.detach()
            val replacement = StorageChannel(supervisor,dispatch)
            val active = replacement.handle("activeOperations",emptyMap()) as List<*>
            assertEquals("fixture-write",(active.single() as Map<*,*>)["operationId"])
            val pending = replacement.handle("operationState",mapOf("operationId" to "fixture-write")) as Map<*,*>
            assertEquals("pending",pending["state"])
            replacement.handle("deleteComponentAt",deleteArgs)
            assertFalse(deleted.await(150,TimeUnit.MILLISECONDS))
            release.countDown(); supervisor.operation("fixture-write")!!.settled.get(5,TimeUnit.SECONDS)
            supervisor.operation("fixture-delete")!!.settled.get(5,TimeUnit.SECONDS)
            val state = replacement.handle("operationState",mapOf("operationId" to "fixture-write")) as Map<*,*>
            assertEquals("settled",state["state"]); assertEquals("written",state["result"])
            replacement.detach()
            val third = StorageChannel(supervisor,dispatch)
            assertEquals(state,third.handle("operationState",mapOf("operationId" to "fixture-write")))
            third.handle("acknowledgeOperation",mapOf("operationId" to "fixture-write"))
            assertNull(supervisor.operation("fixture-write"))
            // An observer may have snapshotted activeOperations before another
            // owner acknowledged it. Keep settlement proof without result bytes.
            assertEquals("settled",(third.handle("operationState",mapOf("operationId" to "fixture-write")) as Map<*,*>)["state"])
            assertEquals("fixture-write",(third.handle("writeMetadataAt",writeArgs) as Map<*,*>)["operationId"])
        } finally { release.countDown(); supervisor.close() }
    }
    @Test fun replacementObserverCannotLoseOutstandingWriter() {
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val deleted = CountDownLatch(1)
        val order = java.util.Collections.synchronizedList(mutableListOf<String>())
        val supervisor = NativeIoSupervisor(Executors.newFixedThreadPool(2))
        try {
            val write = supervisor.submit("fixture/root/a") {
                entered.countDown(); check(release.await(5,TimeUnit.SECONDS)); order.add("write")
            }
            assertTrue(entered.await(5,TimeUnit.SECONDS)); assertFalse(write.settled.isDone)
            assertSame(write,supervisor.operation(write.id))
            val delete = supervisor.submit("fixture/root/a") { deleted.countDown(); order.add("delete") }
            assertFalse(deleted.await(150,TimeUnit.MILLISECONDS)); assertFalse(delete.settled.isDone)
            release.countDown(); write.settled.get(5,TimeUnit.SECONDS); delete.settled.get(5,TimeUnit.SECONDS)
            assertEquals(listOf("write","delete"),order.toList())
        } finally { release.countDown(); supervisor.close() }
    }
}
