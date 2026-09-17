// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage

/** Provider rows plus the status extras that determine whether they are complete. */
internal data class ProviderQuerySnapshot(
    val rows: List<NativeNode>,
    val loading: Boolean,
    val error: String?
) {
    fun completedRows(): List<NativeNode> {
        // Non-null and even nonempty cursors can be incomplete. No consumer may
        // use their rows as proof of ownership, absence, or a free target name.
        if (error != null) throw NativeStorageException("io", "Provider query failed")
        if (loading) throw NativeStorageException("unavailable", "Provider query is still loading")
        return rows
    }
}
