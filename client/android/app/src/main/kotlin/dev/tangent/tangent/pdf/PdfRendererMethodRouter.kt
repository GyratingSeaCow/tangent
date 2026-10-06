// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.pdf

/** Pure routing/validation layer for the Flutter PDF renderer channel. */
class PdfRendererMethodRouter(private val backend: PdfRendererBackend) {
    fun handle(method: String, arguments: Any?): Any = when (method) {
        "inspectDocument" -> {
            val args = arguments.asArguments()
            backend.inspect(args.requiredString("sourcePath")).toChannelValue()
        }
        "renderPage" -> {
            val args = arguments.asArguments()
            val format = args.requiredString("format")
            if (format != "png") {
                throw PdfRendererFailure("unsupported_format", "Only PNG output is supported")
            }
            backend.render(
                sourcePath = args.requiredString("sourcePath"),
                outputPath = args.requiredString("outputPath"),
                pageNumber = args.requiredPositiveInt("pageNumber"),
                width = args.requiredPositiveInt("width"),
                height = args.requiredPositiveInt("height"),
            )
            mapOf("outputPath" to args.requiredString("outputPath"))
        }
        else -> throw PdfRendererNotImplemented(method)
    }

    private fun Any?.asArguments(): Map<*, *> =
        this as? Map<*, *>
            ?: throw PdfRendererFailure("invalid_arguments", "PDF renderer arguments must be a map")

    private fun Map<*, *>.requiredString(name: String): String =
        (this[name] as? String)?.takeIf { it.isNotBlank() }
            ?: throw PdfRendererFailure("invalid_arguments", "Missing $name")

    private fun Map<*, *>.requiredPositiveInt(name: String): Int {
        val number = this[name] as? Number
            ?: throw PdfRendererFailure("invalid_arguments", "Missing $name")
        val value = number.toInt()
        if (value <= 0 || number.toDouble() != value.toDouble()) {
            throw PdfRendererFailure("invalid_arguments", "$name must be a positive integer")
        }
        return value
    }
}

interface PdfRendererBackend {
    fun inspect(sourcePath: String): PdfDocumentInfo

    fun render(
        sourcePath: String,
        outputPath: String,
        pageNumber: Int,
        width: Int,
        height: Int,
    )
}

data class PdfPageSize(val width: Int, val height: Int)

data class PdfDocumentInfo(val pages: List<PdfPageSize>) {
    fun toChannelValue(): Map<String, Any> = mapOf(
        "pageCount" to pages.size,
        "pages" to pages.map { page ->
            mapOf("width" to page.width, "height" to page.height)
        },
    )
}

class PdfRendererFailure(val code: String, message: String, cause: Throwable? = null) :
    RuntimeException(message, cause)

class PdfRendererNotImplemented(val method: String) : RuntimeException(method)
