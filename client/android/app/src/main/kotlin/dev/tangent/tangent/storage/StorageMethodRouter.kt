// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage

/** Android-independent result boundary; MainActivity adapts the real MethodChannel result. */
interface StorageReply {
    fun success(value: Any?)
    fun error(code: String, message: String?)
    fun notImplemented()
}

/** The sole outer storage dispatcher. No legacy ID/current-root aliases or fallback. */
class StorageMethodRouter(
    private val pickDirectory: (StorageReply) -> Unit,
    private val setKeepScreenAwake: (Boolean) -> Unit,
    private val storage: (String, Map<String, Any?>) -> Any?,
) {
    fun handle(method: String, arguments: Any?, result: StorageReply) {
        when {
            method == "pickDirectory" -> pickDirectory(result)
            method == "setKeepScreenAwake" -> {
                setKeepScreenAwake((arguments as? Map<*, *>)?.get("enabled") == true)
                result.success(null)
            }
            method in StorageChannel.methods || method in operationMethods -> {
                try {
                    val raw = arguments as? Map<*, *> ?: emptyMap<Any?, Any?>()
                    val args = raw.entries.associate { (key, value) -> key.toString() to value }
                    result.success(storage(method, args))
                } catch (error: NativeStorageException) {
                    result.error(error.code, error.message)
                } catch (error: Exception) {
                    result.error("invalid", "Invalid storage request")
                }
            }
            else -> result.notImplemented()
        }
    }

    private companion object {
        val operationMethods = setOf("activeOperations", "operationState", "acknowledgeOperation")
    }
}

/** Candidate-only pending-result logic. Android owns launch, grant and candidate operations. */
class CandidatePicker<T : Any>(
    private val launch: () -> Unit,
    private val takeGrant: (T, Int) -> Unit,
    private val candidate: (T) -> Any?,
    private val grantMask: Int,
) {
    private var pendingTreeResult: StorageReply? = null

    fun start(result: StorageReply) {
        if (pendingTreeResult != null) {
            result.error("picker_active", "A recording-folder picker is already open")
            return
        }
        pendingTreeResult = result
        launch()
    }

    fun complete(matchingRequest: Boolean, accepted: Boolean, selected: T?, flags: Int) {
        if (!matchingRequest) return
        val pending = pendingTreeResult ?: return
        pendingTreeResult = null
        if (!accepted || selected == null) {
            pending.success(null)
            return
        }
        try {
            takeGrant(selected, flags and grantMask)
            pending.success(candidate(selected))
        } catch (error: Exception) {
            pending.error("storage_permission", error.message)
        }
    }

    fun interrupt() {
        val pending = pendingTreeResult ?: return
        pendingTreeResult = null
        pending.error("activity_destroyed", "Folder picker was interrupted")
    }
}
