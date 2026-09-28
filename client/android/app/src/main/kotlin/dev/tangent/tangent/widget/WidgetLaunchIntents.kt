// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Parses widget-tap intents. String-based on purpose: no Uri, no
// Robolectric — the routing decision runs under plain JUnit exactly as
// it runs in production (Uri.toString() in, id out).

package dev.tangent.tangent.widget

object WidgetLaunchIntents {

    const val ACTION_VIEW = "android.intent.action.VIEW"
    private const val PREFIX = "tangent://notebook/"

    /** The hands-free record spine (spec 2026-09-28): Assistant, the 1x1
     *  mic widget and the launcher shortcut all fire exactly this URI. */
    const val RECORD_URI = "tangent://record"

    /** The one launch command the Dart side understands today. */
    const val COMMAND_RECORD = "record"

    /** The notebook a VIEW tangent://notebook/<id> intent names, or null
     *  for every other intent (normal launches, share sheets, etc.). */
    fun notebookId(action: String?, dataString: String?): String? {
        if (action != ACTION_VIEW) return null
        if (dataString == null || !dataString.startsWith(PREFIX)) return null
        val id = dataString.removePrefix(PREFIX).substringBefore('?')
        return id.trim().ifEmpty { null }
    }

    /** The launch command a VIEW intent carries ("record" for
     *  tangent://record), or null for every other intent. A trailing slash
     *  or a query string does not change the command; a different host
     *  (tangent://notebook/...) or scheme is not a command at all. */
    fun command(action: String?, dataString: String?): String? {
        if (action != ACTION_VIEW || dataString == null) return null
        val bare = dataString.substringBefore('?').trimEnd('/')
        return if (bare == RECORD_URI) COMMAND_RECORD else null
    }

    /** H3 guard: only a launch carrying the record intent may show over
     *  the lock screen. Everything else — the launcher icon, a notebook
     *  widget, a share — must NOT, or the app becomes a keyguard bypass. */
    fun showOverLockScreen(action: String?, dataString: String?): Boolean =
        command(action, dataString) == COMMAND_RECORD
}
