// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.pdf

import android.graphics.pdf.RenderParams
import org.junit.Assert.assertEquals
import org.junit.Test

class AndroidPdfRenderPathTest {
    @Test
    fun api35AndNewerSelectAnnotationAwareRenderParamsOverload() {
        assertEquals(PdfRenderPath.LEGACY_CONTENT_ONLY, pdfRenderPathForSdk(34))
        assertEquals(PdfRenderPath.ANNOTATIONS_AND_FORMS, pdfRenderPathForSdk(35))
        assertEquals(PdfRenderPath.ANNOTATIONS_AND_FORMS, pdfRenderPathForSdk(36))
    }

    @Test
    fun api35FlagsAreExactlyTextAndHighlightAnnotations() {
        assertEquals(
            RenderParams.FLAG_RENDER_TEXT_ANNOTATIONS or
                RenderParams.FLAG_RENDER_HIGHLIGHT_ANNOTATIONS,
            PDF_ANNOTATION_RENDER_FLAGS,
        )
        assertEquals(6, PDF_ANNOTATION_RENDER_FLAGS)
    }
}