// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The widget deep-link contract, from the intent side: only a VIEW on
// tangent://notebook/<id> may open a notebook — anything else must be
// ignored, and a blank id must never leak through to the editor.

package dev.tangent.tangent.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WidgetLaunchIntentsTest {

    @Test
    fun viewIntentWithNotebookUriYieldsTheId() {
        assertEquals(
            "nb-42",
            WidgetLaunchIntents.notebookId(
                WidgetLaunchIntents.ACTION_VIEW,
                "tangent://notebook/nb-42",
            ),
        )
    }

    @Test
    fun wrongActionYieldsNull() {
        assertNull(
            WidgetLaunchIntents.notebookId(
                "android.intent.action.MAIN",
                "tangent://notebook/nb-42",
            ),
        )
    }

    @Test
    fun wrongSchemeOrHostYieldsNull() {
        assertNull(
            WidgetLaunchIntents.notebookId(
                WidgetLaunchIntents.ACTION_VIEW,
                "https://notebook/nb-42",
            ),
        )
        assertNull(
            WidgetLaunchIntents.notebookId(
                WidgetLaunchIntents.ACTION_VIEW,
                "tangent://dump/nb-42",
            ),
        )
    }

    @Test
    fun missingOrBlankIdYieldsNull() {
        assertNull(
            WidgetLaunchIntents.notebookId(
                WidgetLaunchIntents.ACTION_VIEW,
                "tangent://notebook/",
            ),
        )
        assertNull(
            WidgetLaunchIntents.notebookId(
                WidgetLaunchIntents.ACTION_VIEW,
                "tangent://notebook",
            ),
        )
        assertNull(
            WidgetLaunchIntents.notebookId(WidgetLaunchIntents.ACTION_VIEW, null),
        )
    }

    @Test
    fun queryStringsDoNotRideIntoTheId() {
        assertEquals(
            "nb-42",
            WidgetLaunchIntents.notebookId(
                WidgetLaunchIntents.ACTION_VIEW,
                "tangent://notebook/nb-42?utm=launcher",
            ),
        )
    }
}
