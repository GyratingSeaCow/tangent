// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Parses widget-tap intents. String-based on purpose: no Uri, no
// Robolectric — the routing decision runs under plain JUnit exactly as
// it runs in production (Uri.toString() in, id out).

package dev.tangent.tangent.widget

object WidgetLaunchIntents {

    const val ACTION_VIEW = "android.intent.action.VIEW"
    private const val PREFIX = "tangent://notebook/"

    /** The notebook a VIEW tangent://notebook/<id> intent names, or null
     *  for every other intent (normal launches, share sheets, etc.). */
    fun notebookId(action: String?, dataString: String?): String? {
        if (action != ACTION_VIEW) return null
        if (dataString == null || !dataString.startsWith(PREFIX)) return null
        val id = dataString.removePrefix(PREFIX).substringBefore('?')
        return id.trim().ifEmpty { null }
    }
}
