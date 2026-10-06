// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.pdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class PdfRendererMethodRouterTest {
    @Test
    fun inspectReturnsPageCountAndDimensions() {
        val backend = FakeBackend()
        val result = PdfRendererMethodRouter(backend).handle(
            "inspectDocument",
            mapOf("sourcePath" to "/private/source.pdf"),
        ) as Map<*, *>

        assertEquals("/private/source.pdf", backend.inspected)
        assertEquals(2, result["pageCount"])
        assertEquals(
            listOf(
                mapOf("width" to 612, "height" to 792),
                mapOf("width" to 400, "height" to 200),
            ),
            result["pages"],
        )
    }

    @Test
    fun renderUsesOneBasedPageAndExactRequestedSize() {
        val backend = FakeBackend()
        val result = PdfRendererMethodRouter(backend).handle(
            "renderPage",
            mapOf(
                "sourcePath" to "/private/source.pdf",
                "outputPath" to "/private/page.png",
                "pageNumber" to 3,
                "width" to 1376,
                "height" to 1782,
                "format" to "png",
            ),
        )

        assertEquals(
            RenderCall("/private/source.pdf", "/private/page.png", 3, 1376, 1782),
            backend.rendered,
        )
        assertEquals(mapOf("outputPath" to "/private/page.png"), result)
    }

    @Test
    fun rejectsMissingArgumentsAndNonPngOutput() {
        val router = PdfRendererMethodRouter(FakeBackend())

        assertEquals(
            "invalid_arguments",
            assertThrows(PdfRendererFailure::class.java) {
                router.handle("inspectDocument", emptyMap<String, Any>())
            }.code,
        )
        assertEquals(
            "unsupported_format",
            assertThrows(PdfRendererFailure::class.java) {
                router.handle(
                    "renderPage",
                    mapOf(
                        "sourcePath" to "/private/source.pdf",
                        "outputPath" to "/private/page.jpg",
                        "pageNumber" to 1,
                        "width" to 100,
                        "height" to 100,
                        "format" to "jpeg",
                    ),
                )
            }.code,
        )
    }

    @Test
    fun unknownMethodsRemainNotImplemented() {
        assertThrows(PdfRendererNotImplemented::class.java) {
            PdfRendererMethodRouter(FakeBackend()).handle("deleteEverything", null)
        }
    }

    private class FakeBackend : PdfRendererBackend {
        var inspected: String? = null
        var rendered: RenderCall? = null

        override fun inspect(sourcePath: String): PdfDocumentInfo {
            inspected = sourcePath
            return PdfDocumentInfo(
                listOf(PdfPageSize(612, 792), PdfPageSize(400, 200)),
            )
        }

        override fun render(
            sourcePath: String,
            outputPath: String,
            pageNumber: Int,
            width: Int,
            height: Int,
        ) {
            rendered = RenderCall(sourcePath, outputPath, pageNumber, width, height)
        }
    }

    private data class RenderCall(
        val sourcePath: String,
        val outputPath: String,
        val pageNumber: Int,
        val width: Int,
        val height: Int,
    )
}
