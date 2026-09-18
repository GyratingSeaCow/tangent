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
                mapOf("operationId" to op.id,"key" to op.description["key"],"kind" to op.description["kind"],"method" to op.description["method"])
            }
            "operationState" -> {
                if (supervisor.wasAcknowledged(id())) return mapOf("state" to "settled","problem" to mapOf("code" to "interrupted","message" to "Result already acknowledged"))
                val op = supervisor.operation(id()) ?: throw NativeStorageException("unknown","Operation is not retained")
                if (args.containsKey("capturePayload")) {
                    val expected = args["capturePayload"] as? Map<*,*> ?: throw NativeStorageException("invalid","Missing capture observation payload")
                    if (op.description["method"] != "prepareCaptureAt" || expected["operationId"] != id() || op.description["args"] != expected)
                        throw NativeStorageException("conflict","Preparation observation has another payload")
                }
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
            "acknowledgeOperation" -> {
                val op = supervisor.operation(id())
                val preparation = op?.description?.get("method") == "prepareCaptureAt"
                if (args["preparationOnly"] == true) {
                    if (op == null) throw NativeStorageException("unresolved","Preparation receipt is not retained")
                    if (!preparation) throw NativeStorageException("conflict","Not a preparation receipt")
                    val payload = op.description["args"] as? Map<*,*> ?: throw NativeStorageException("invalid","Missing retained preparation payload")
                    val reservation = CaptureWire.reservation(payload["reservation"])
                    if (id() != "capture-${reservation["id"]}-prepare") throw NativeStorageException("conflict","Preparation operation ID differs")
                } else if (preparation) throw NativeStorageException("conflict","Preparation requires explicit owner acknowledgement")
                supervisor.acknowledge(id()); null
            }
            else -> {
                if (method !in methods) throw NativeStorageException("unsupported","Unknown storage operation")
                if (method in captureMethods) {
                    val fields = if (method == "prepareCaptureAt") setOf("operationId","reservation","metadataJson","audioSha256") else setOf("operationId","reservation","preparation")
                    if (args.keys != fields) throw NativeStorageException("invalid","Unexpected capture payload fields")
                    CaptureWire.literal(id())
                    val reservation = CaptureWire.reservation(args["reservation"])
                    if (method == "prepareCaptureAt") {
                        if (id() != "capture-${reservation["id"]}-prepare") throw NativeStorageException("invalid","Wrong preparation operation ID")
                        CaptureWire.metadata(CaptureWire.text(args["metadataJson"]),reservation)
                        CaptureWire.digest(args["audioSha256"])
                    } else CaptureWire.preparation(args["preparation"],reservation)
                }
                if (method in documentMethods) {
                    val fields = when(method) {
                        "publishDocumentAt" -> setOf("operationId","location","directoryName","name","content","publicationId")
                        "listDocumentsAt" -> setOf("operationId","location","directoryName","suffix")
                        else -> setOf("operationId","location","directoryName","name","locator","deletionId")
                    }
                    if (args.keys != fields) throw NativeStorageException("invalid","Unexpected document payload fields")
                    CaptureWire.literal(id())
                    CaptureWire.directory(args["location"]); DocumentWire.literal(args["directoryName"])
                }
                val payload = (args["binding"] ?: args["reservation"]) as? Map<*,*>
                val key = payload?.get("key") as? Map<*,*> ?: mapOf("dumpId" to "catalog", "incarnation" to id())
                val dumpId = key["dumpId"] as? String ?: throw NativeStorageException("invalid","Missing recording ID")
                val incarnation = key["incarnation"] as? String ?: throw NativeStorageException("invalid","Missing incarnation")
                val kind = when(method) {
                    "writeMetadataAt" -> "publication"; "deleteComponentAt" -> "deletion"
                    "prepareCaptureAt", "inspectPreparedCaptureAt", "publishPreparedCaptureAt" -> "capture"
                    "playbackSourceAt" -> "playback"; else -> "read"
                }
                val descriptor = mapOf("key" to key,"kind" to kind,"method" to method,"args" to args)
                val op = supervisor.submit(id(),"${dumpId.length}:$dumpId${incarnation.length}:$incarnation",descriptor) { dispatch(method,args) }
                mapOf("operationId" to op.id)
            }
        }
    }
    companion object {
        val captureMethods = setOf("prepareCaptureAt","inspectPreparedCaptureAt","publishPreparedCaptureAt")
        val documentMethods = setOf("publishDocumentAt","listDocumentsAt","deleteDocumentAt")
        val methods = setOf("inspectLegacyStorage","validateCandidate","probeLocationAt","readAudioAt","playbackSourceAt","writeMetadataAt","deleteComponentAt","listRecordingsAt","readRecordingAt") + captureMethods + documentMethods
    }
}
