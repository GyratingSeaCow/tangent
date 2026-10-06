// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.pdf

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.graphics.pdf.RenderParams
import android.os.Build
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileOutputStream

/** Android framework implementation; no bundled PDF engine is required. */
class AndroidPdfRendererBackend(
    context: Context,
    private val sdkInt: Int = Build.VERSION.SDK_INT,
) : PdfRendererBackend {
    private val cacheRoot = context.cacheDir.canonicalFile

    override fun inspect(sourcePath: String): PdfDocumentInfo =
        withRenderer(privateSource(sourcePath)) { renderer ->
            if (renderer.pageCount <= 0) {
                throw PdfRendererFailure("invalid_pdf", "The PDF has no pages")
            }
            val pages = ArrayList<PdfPageSize>(renderer.pageCount)
            for (index in 0 until renderer.pageCount) {
                renderer.openPage(index).use { page ->
                    pages.add(PdfPageSize(page.width, page.height))
                }
            }
            PdfDocumentInfo(pages)
        }

    override fun render(
        sourcePath: String,
        outputPath: String,
        pageNumber: Int,
        width: Int,
        height: Int,
    ) {
        if (width > MAX_DIMENSION || height > MAX_DIMENSION || width.toLong() * height > MAX_PIXELS) {
            throw PdfRendererFailure(
                "render_too_large",
                "Requested PDF raster exceeds the 8000px/64MP cache limit",
            )
        }
        val source = privateSource(sourcePath)
        val output = privateOutput(outputPath)
        var completed = false
        try {
            withRenderer(source) { renderer ->
                if (pageNumber > renderer.pageCount) {
                    throw PdfRendererFailure(
                        "page_out_of_range",
                        "Page $pageNumber is outside 1..${renderer.pageCount}",
                    )
                }
                renderer.openPage(pageNumber - 1).use { page ->
                    val bitmap = try {
                        Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                    } catch (error: OutOfMemoryError) {
                        throw PdfRendererFailure("render_memory", "Not enough memory to render PDF page", error)
                    }
                    try {
                        bitmap.eraseColor(Color.WHITE)
                        val matrix = Matrix().apply {
                            setScale(width.toFloat() / page.width, height.toFloat() / page.height)
                        }
                        renderPdfPage(page, bitmap, matrix, sdkInt)
                        FileOutputStream(output, false).use { stream ->
                            if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)) {
                                throw PdfRendererFailure("encode_failed", "Could not encode PDF page")
                            }
                            stream.fd.sync()
                        }
                        if (output.length() <= 0L) {
                            throw PdfRendererFailure("encode_failed", "PDF page output is empty")
                        }
                        completed = true
                    } finally {
                        bitmap.recycle()
                    }
                }
            }
        } finally {
            if (!completed) output.delete()
        }
    }

    private fun privateSource(path: String): File {
        val file = privateFile(path, "source")
        if (!file.isFile || file.length() <= 0L) {
            throw PdfRendererFailure("source_missing", "PDF source is missing or empty")
        }
        return file
    }

    private fun privateOutput(path: String): File {
        val file = privateFile(path, "output")
        file.parentFile?.mkdirs()
        if (file.parentFile?.isDirectory != true) {
            throw PdfRendererFailure("output_unavailable", "PDF output directory is unavailable")
        }
        return file
    }

    private fun privateFile(path: String, purpose: String): File {
        val file = try {
            File(path).canonicalFile
        } catch (error: Exception) {
            throw PdfRendererFailure("invalid_path", "Invalid PDF $purpose path", error)
        }
        val prefix = cacheRoot.path + File.separator
        if (!file.path.startsWith(prefix)) {
            throw PdfRendererFailure(
                "unsafe_path",
                "PDF $purpose must be inside the app cache",
            )
        }
        return file
    }

    private fun <T> withRenderer(source: File, action: (PdfRenderer) -> T): T {
        try {
            ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                PdfRenderer(descriptor).use { renderer ->
                    return action(renderer)
                }
            }
        } catch (error: PdfRendererFailure) {
            throw error
        } catch (error: SecurityException) {
            throw PdfRendererFailure("pdf_security", error.message ?: "PDF access denied", error)
        } catch (error: Exception) {
            throw PdfRendererFailure("invalid_pdf", error.message ?: "Could not open PDF", error)
        }
    }

    private companion object {
        const val MAX_DIMENSION = 8000
        const val MAX_PIXELS = 64_000_000L
    }
}

/** Selects the annotation-aware Android 15 overload without calling it below 35. */
internal fun renderPdfPage(
    page: PdfRenderer.Page,
    bitmap: Bitmap,
    matrix: Matrix,
    sdkInt: Int,
) {
    if (pdfRenderPathForSdk(sdkInt) == PdfRenderPath.ANNOTATIONS_AND_FORMS) {
        val params = RenderParams.Builder(RenderParams.RENDER_MODE_FOR_DISPLAY)
            .setRenderFlags(PDF_ANNOTATION_RENDER_FLAGS)
            .build()
        page.render(bitmap, null, matrix, params)
    } else {
        page.render(bitmap, null, matrix, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
    }
}

internal enum class PdfRenderPath { LEGACY_CONTENT_ONLY, ANNOTATIONS_AND_FORMS }

internal fun pdfRenderPathForSdk(sdkInt: Int): PdfRenderPath =
    if (sdkInt >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
        PdfRenderPath.ANNOTATIONS_AND_FORMS
    } else {
        PdfRenderPath.LEGACY_CONTENT_ONLY
    }

internal const val PDF_ANNOTATION_RENDER_FLAGS =
    RenderParams.FLAG_RENDER_TEXT_ANNOTATIONS or
        RenderParams.FLAG_RENDER_HIGHLIGHT_ANNOTATIONS
