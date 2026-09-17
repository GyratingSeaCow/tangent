// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage
import java.util.UUID
import java.util.concurrent.*
class NativeOperation<T>(val id: String, val key: String, val description: Map<String,Any?> = emptyMap()) {
    val result = CompletableFuture<T>()
    val settled = CompletableFuture<Unit>()
}
class NativeIoSupervisor(private val executor: ExecutorService) : AutoCloseable {
    private val operations = linkedMapOf<String,NativeOperation<*>>()
    private val tails = mutableMapOf<String,CompletableFuture<Unit>>()
    private val acknowledged = mutableMapOf<String,String>()
    private fun fingerprint(key:String, description:Map<String,Any?>):String =
        java.security.MessageDigest.getInstance("SHA-256").digest((key + description.toString()).toByteArray()).joinToString("") { "%02x".format(it) }
    private var closed = false
    fun <T> submit(key: String, action: () -> T): NativeOperation<T> = submit(UUID.randomUUID().toString(),key,emptyMap(),action)
    @Synchronized fun <T> submit(id: String, key: String, description: Map<String,Any?>, action: () -> T): NativeOperation<T> {
        check(!closed)
        if (acknowledged.containsKey(id)) {
            if (acknowledged[id] != fingerprint(key,description)) throw NativeStorageException("conflict","Operation ID has another payload")
            val receipt = NativeOperation<T>(id,key)
            receipt.result.completeExceptionally(NativeStorageException("interrupted","Result was already acknowledged"))
            receipt.settled.complete(Unit)
            return receipt
        }
        val existing = operations[id]
        if (existing != null) {
            if (existing.key != key || existing.description != description) throw NativeStorageException("conflict","Operation ID has another payload")
            @Suppress("UNCHECKED_CAST") return existing as NativeOperation<T>
        }
        val op = NativeOperation<T>(id,key,description); operations[id] = op
        val before = tails[key] ?: CompletableFuture.completedFuture(Unit)
        tails[key] = op.settled
        before.thenRunAsync({
            try { op.result.complete(action()) }
            catch(e: Throwable) { op.result.completeExceptionally(e) }
            finally { op.settled.complete(Unit); synchronized(this) { if (tails[key] === op.settled) tails.remove(key) } }
        },executor)
        return op
    }
    @Synchronized fun operation(id: String): NativeOperation<*>? = operations[id]
    @Synchronized fun retained(): List<NativeOperation<*>> = operations.values.toList()
    @Synchronized fun wasAcknowledged(id:String):Boolean = acknowledged.containsKey(id)
    @Synchronized fun acknowledge(id: String) {
        val op = operations[id] ?: return
        if (!op.settled.isDone) throw NativeStorageException("busy","Worker has not settled")
        acknowledged[id] = fingerprint(op.key,op.description)
        operations.remove(id)
    }
    override fun close() {
        val pending = synchronized(this) { closed = true; operations.values.map { it.settled }.toTypedArray() }
        CompletableFuture.allOf(*pending).join()
        executor.shutdown(); check(executor.awaitTermination(10,TimeUnit.SECONDS))
    }
    companion object { val process by lazy { NativeIoSupervisor(Executors.newFixedThreadPool(4)) } }
}
