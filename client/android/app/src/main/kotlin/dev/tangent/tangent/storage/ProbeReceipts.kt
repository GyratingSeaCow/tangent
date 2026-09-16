// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage

/** Operation-local exact provider URI receipts; workers can share this adapter. */
internal class ProbeReceipts {
    private val active = ThreadLocal<MutableList<String>>()

    fun <T> observe(uri: String, observation: () -> T): T {
        active.get()?.add(uri)
        return observation()
    }

    fun capture(probe: () -> Map<String, Any?>): Map<String, Any?> {
        val receipts = mutableListOf<String>()
        active.set(receipts)
        try {
            val result = probe()
            val owned = (result["owned"] as List<*>).map { it as String }
            // The policy may catch a post-mutation query failure and return
            // normally. Always retain the exact provider returns, not only the
            // nodes whose follow-up queries succeeded.
            return mapOf(
                "owned" to (receipts + owned).distinct(),
                "cleaned" to (result["cleaned"] == true && receipts.all { it in owned })
            )
        } catch (e: Exception) {
            if (receipts.isEmpty()) throw e
            return mapOf("owned" to receipts.toList(), "cleaned" to false)
        } finally {
            active.remove()
        }
    }
}
