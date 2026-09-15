// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage

/** A replaceable channel owner over process-owned operations, also used by JVM tests. */
class StorageChannel(private val supervisor: NativeIoSupervisor,
                     private val dispatch: (String,Map<String,Any?>)->Any?) {
    @Volatile private var attached = true
    fun detach() { attached = false }
    fun handle(method: String, args: Map<String,Any?>): Any? {
        if (!attached) throw NativeStorageException("unavailable","Channel owner detached")
        fun id() = args["operationId"] as? String ?: throw NativeStorageException("invalid","Missing operation ID")
        return when(method) {
            "activeOperations" -> supervisor.retained().map { op ->
                mapOf("operationId" to op.id,"key" to op.description["key"],"kind" to op.description["kind"])
            }
            "operationState" -> {
                if (supervisor.wasAcknowledged(id())) return mapOf("state" to "settled","problem" to mapOf("code" to "interrupted","message" to "Result already acknowledged"))
                val op = supervisor.operation(id()) ?: throw NativeStorageException("unknown","Operation is not retained")
                if (!op.settled.isDone) mapOf("state" to "pending")
                else try { mapOf("state" to "settled","result" to op.result.join()) }
                catch (e: java.util.concurrent.CompletionException) {
                    val cause = e.cause
                    val problem = when(cause) {
                        is NativeStorageException -> cause
                        is SecurityException -> NativeStorageException("denied","Provider access denied")
                        else -> NativeStorageException("io","Native storage operation failed")
                    }
                    mapOf("state" to "settled","problem" to mapOf("code" to problem.code,"message" to problem.message))
                }
            }
            "acknowledgeOperation" -> { supervisor.acknowledge(id()); null }
            else -> {
                if (method !in methods) throw NativeStorageException("unsupported","Unknown storage operation")
                val payload = (args["binding"] ?: args["reservation"]) as? Map<*,*>
                val key = payload?.get("key") as? Map<*,*> ?: mapOf("dumpId" to "catalog", "incarnation" to id())
                val dumpId = key["dumpId"] as? String ?: throw NativeStorageException("invalid","Missing recording ID")
                val incarnation = key["incarnation"] as? String ?: throw NativeStorageException("invalid","Missing incarnation")
                val kind = when(method) {
                    "writeMetadataAt" -> "publication"; "deleteComponentAt" -> "deletion"; "publishCaptureAt" -> "capture"
                    "playbackSourceAt" -> "playback"; else -> "read"
                }
                val descriptor = mapOf("key" to key,"kind" to kind,"method" to method,"args" to args)
                val op = supervisor.submit(id(),"${dumpId.length}:$dumpId${incarnation.length}:$incarnation",descriptor) { dispatch(method,args) }
                mapOf("operationId" to op.id)
            }
        }
    }
    companion object {
        val methods = setOf("inspectLegacyStorage","validateCandidate","readAudioAt","playbackSourceAt","publishCaptureAt","writeMetadataAt","deleteComponentAt","listRecordingsAt")
    }
}
