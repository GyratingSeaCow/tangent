// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The tangent://record spine from the intent side (spec 2026-09-28):
//   - intent → command mapping, cold and warm (LaunchRouter);
//   - H3 guard: the record intent shows over the lock screen, a plain
//     launch (or a notebook widget tap) does not;
//   - RecordWidgetProvider's tap data is exactly tangent://record.

package dev.tangent.tangent.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RecordLaunchTest {

    private val view = WidgetLaunchIntents.ACTION_VIEW

    // ---- intent → command -------------------------------------------------

    @Test
    fun recordUriMapsToTheRecordCommand() {
        assertEquals("record", WidgetLaunchIntents.command(view, "tangent://record"))
        assertEquals("record", WidgetLaunchIntents.command(view, "tangent://record/"))
        assertEquals("record", WidgetLaunchIntents.command(view, "tangent://record?src=widget"))
    }

    @Test
    fun otherIntentsAreNotCommands() {
        assertNull(WidgetLaunchIntents.command("android.intent.action.MAIN", null))
        assertNull(WidgetLaunchIntents.command("android.intent.action.MAIN", "tangent://record"))
        assertNull(WidgetLaunchIntents.command(view, "tangent://notebook/nb-1"))
        assertNull(WidgetLaunchIntents.command(view, "tangent://recordings"))
        assertNull(WidgetLaunchIntents.command(view, "https://record"))
        assertNull(WidgetLaunchIntents.command(view, null))
    }

    @Test
    fun recordUriIsNotANotebookId() {
        assertNull(WidgetLaunchIntents.notebookId(view, "tangent://record"))
    }

    // ---- cold path: stashed, read-once ------------------------------------

    @Test
    fun coldRecordIntentIsTakenExactlyOnce() {
        val router = LaunchRouter()
        router.onCold(view, "tangent://record")
        assertEquals("record", router.takeCommand())
        assertNull("a hot restart must not start a second recording", router.takeCommand())
        assertNull("the record intent names no notebook", router.takeNotebook())
    }

    @Test
    fun coldPlainLaunchHasNoCommand() {
        val router = LaunchRouter()
        router.onCold("android.intent.action.MAIN", null)
        assertNull(router.takeCommand())
        assertNull(router.takeNotebook())
    }

    @Test
    fun coldNotebookIntentStillRoutesToTheNotebook() {
        val router = LaunchRouter()
        router.onCold(view, "tangent://notebook/nb-7")
        assertEquals("nb-7", router.takeNotebook())
        assertNull(router.takeNotebook())
        assertNull(router.takeCommand())
    }

    // ---- warm path: pushed over the channel, or held when it is down ------

    @Test
    fun warmRecordIntentPushesTheCommandMethod() {
        val router = LaunchRouter()
        val pushed = mutableListOf<Pair<String, String>>()
        router.onWarm(view, "tangent://record") { m, a -> pushed.add(m to a) }
        assertEquals(listOf("command" to "record"), pushed)
        assertNull("pushed, so nothing is left to take", router.takeCommand())
    }

    @Test
    fun warmNotebookIntentStillPushesOpenNotebook() {
        val router = LaunchRouter()
        val pushed = mutableListOf<Pair<String, String>>()
        router.onWarm(view, "tangent://notebook/nb-9") { m, a -> pushed.add(m to a) }
        assertEquals(listOf("openNotebook" to "nb-9"), pushed)
    }

    @Test
    fun warmIntentWithoutChannelIsHeldForTheColdRead() {
        val router = LaunchRouter()
        router.onWarm(view, "tangent://record", push = null)
        assertEquals("record", router.takeCommand())
        assertNull(router.takeCommand())
    }

    @Test
    fun unansweredWarmPushIsStashedNotLost() {
        val router = LaunchRouter()
        router.stash("command", "record")
        assertEquals("record", router.takeCommand())
        router.stash("openNotebook", "nb-3")
        assertEquals("nb-3", router.takeNotebook())
    }

    @Test
    fun warmPlainLaunchPushesNothing() {
        val router = LaunchRouter()
        val pushed = mutableListOf<Pair<String, String>>()
        router.onWarm("android.intent.action.MAIN", null) { m, a -> pushed.add(m to a) }
        assertTrue(pushed.isEmpty())
        assertNull(router.takeCommand())
    }

    // ---- H3 guard ---------------------------------------------------------

    @Test
    fun recordIntentShowsOverTheLockScreen() {
        assertTrue(WidgetLaunchIntents.showOverLockScreen(view, "tangent://record"))
    }

    @Test
    fun plainLaunchDoesNotShowOverTheLockScreen() {
        assertFalse(
            "a launcher-icon start must not bypass the keyguard",
            WidgetLaunchIntents.showOverLockScreen("android.intent.action.MAIN", null),
        )
        assertFalse(
            "a notebook widget tap opens review, which needs the unlock",
            WidgetLaunchIntents.showOverLockScreen(view, "tangent://notebook/nb-1"),
        )
        assertFalse(WidgetLaunchIntents.showOverLockScreen(view, null))
    }

    // ---- the widget's PendingIntent data ----------------------------------

    @Test
    fun recordWidgetTapIsExactlyTheRecordUri() {
        assertEquals("tangent://record", RecordWidgetProvider.tapUri())
        // And that URI is what the activity side turns into the command —
        // the two halves of the spine cannot drift apart.
        assertEquals("record", WidgetLaunchIntents.command(view, RecordWidgetProvider.tapUri()))
    }
}
