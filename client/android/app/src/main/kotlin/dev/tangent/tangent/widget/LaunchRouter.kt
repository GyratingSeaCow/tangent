// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The launch channel's state, kept out of MainActivity so the cold/warm
// contract runs under plain JUnit:
//
//   cold start  — the intent that created the activity is stashed until
//                 Dart asks (takeLaunchNotebook / takeLaunchCommand),
//                 each read-once so a hot restart cannot replay it;
//   warm start  — onNewIntent (singleTop) pushes straight to Dart when the
//                 channel is attached, or stashes when it is not yet.
//
// No android.* types: `push` is a plain callback the activity supplies.

package dev.tangent.tangent.widget

class LaunchRouter {

    /** Method name pushed for a warm notebook open. */
    val methodOpenNotebook = "openNotebook"

    /** Method name pushed for a warm launch command ("record"). */
    val methodCommand = "command"

    /** Method name pushed for a warm recording open (spec 2026-09-28 N2). */
    val methodOpenDump = "openDump"

    private var pendingNotebook: String? = null
    private var pendingCommand: String? = null
    private var pendingDump: String? = null

    /** The intent the activity was created with. */
    fun onCold(action: String?, dataString: String?) {
        pendingNotebook = WidgetLaunchIntents.notebookId(action, dataString)
        pendingCommand = WidgetLaunchIntents.command(action, dataString)
        pendingDump = WidgetLaunchIntents.dumpId(action, dataString)
    }

    /** An intent delivered to the running activity. [push] is null while
     *  the Dart channel is not attached; then the payload waits for the
     *  read-once take* calls exactly like a cold start. */
    fun onWarm(
        action: String?,
        dataString: String?,
        push: ((method: String, argument: String) -> Unit)?,
    ) {
        val id = WidgetLaunchIntents.notebookId(action, dataString)
        if (id != null) {
            if (push != null) push(methodOpenNotebook, id) else pendingNotebook = id
        }
        val command = WidgetLaunchIntents.command(action, dataString)
        if (command != null) {
            if (push != null) push(methodCommand, command) else pendingCommand = command
        }
        val dump = WidgetLaunchIntents.dumpId(action, dataString)
        if (dump != null) {
            if (push != null) push(methodOpenDump, dump) else pendingDump = dump
        }
    }

    /** A warm push Dart did not answer (handler not registered yet):
     *  keep the payload for the take* call instead of losing the tap. */
    fun stash(method: String, argument: String) {
        when (method) {
            methodOpenNotebook -> pendingNotebook = argument
            methodCommand -> pendingCommand = argument
            methodOpenDump -> pendingDump = argument
        }
    }

    /** Read-once: a hot restart must not reopen the notebook. */
    fun takeNotebook(): String? {
        val id = pendingNotebook
        pendingNotebook = null
        return id
    }

    /** Read-once: a hot restart must not start a second recording. */
    fun takeCommand(): String? {
        val command = pendingCommand
        pendingCommand = null
        return command
    }

    /** Read-once: a hot restart must not reopen the recording. */
    fun takeDump(): String? {
        val id = pendingDump
        pendingDump = null
        return id
    }
}
