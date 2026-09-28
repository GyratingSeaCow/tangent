// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The tangent://dump/<id> spine from the intent side (spec 2026-09-28
// completion notifications, N2): a completion-notice tap opens the
// recording it names, cold (stashed, read-once) and warm (pushed, or held
// while the Dart channel is not attached). Mirrors RecordLaunchTest.

package dev.tangent.tangent.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DumpLaunchTest {

    private val view = WidgetLaunchIntents.ACTION_VIEW

    @Test
    fun dumpUriMapsToTheDumpId() {
        assertEquals("d-1", WidgetLaunchIntents.dumpId(view, "tangent://dump/d-1"))
        assertEquals("d-1", WidgetLaunchIntents.dumpId(view, "tangent://dump/d-1?src=notice"))
    }

    @Test
    fun otherIntentsAreNotDumps() {
        assertNull(WidgetLaunchIntents.dumpId("android.intent.action.MAIN", "tangent://dump/d-1"))
        assertNull(WidgetLaunchIntents.dumpId(view, "tangent://dump/"))
        assertNull(WidgetLaunchIntents.dumpId(view, "tangent://record"))
        assertNull(WidgetLaunchIntents.dumpId(view, "tangent://notebook/nb-1"))
        assertNull(WidgetLaunchIntents.dumpId(view, null))
        assertNull("a dump uri is not a record command", WidgetLaunchIntents.command(view, "tangent://dump/d-1"))
        assertNull("a dump uri is not a notebook", WidgetLaunchIntents.notebookId(view, "tangent://dump/d-1"))
    }

    @Test
    fun coldDumpIntentIsTakenExactlyOnce() {
        val router = LaunchRouter()
        router.onCold(view, "tangent://dump/d-cold")
        assertEquals("d-cold", router.takeDump())
        assertNull("a hot restart must not reopen the recording", router.takeDump())
        assertNull(router.takeNotebook())
        assertNull(router.takeCommand())
    }

    @Test
    fun warmDumpIntentIsPushedOnTheDumpMethod() {
        val router = LaunchRouter()
        val pushed = mutableListOf<Pair<String, String>>()
        router.onWarm(view, "tangent://dump/d-warm") { m, a -> pushed += m to a }
        assertEquals(listOf(router.methodOpenDump to "d-warm"), pushed)
        assertNull("pushed, so nothing is left to take", router.takeDump())
    }

    @Test
    fun warmDumpIntentWithoutChannelIsHeldForTheColdRead() {
        val router = LaunchRouter()
        router.onWarm(view, "tangent://dump/d-held", null)
        assertEquals("d-held", router.takeDump())
        assertNull(router.takeDump())
    }

    @Test
    fun unansweredDumpPushIsStashed() {
        val router = LaunchRouter()
        router.stash(router.methodOpenDump, "d-stash")
        assertEquals("d-stash", router.takeDump())
    }
}
