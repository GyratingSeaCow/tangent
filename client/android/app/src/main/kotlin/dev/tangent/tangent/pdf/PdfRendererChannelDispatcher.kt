// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.pdf

import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

/** Result seam kept independent of Flutter so worker dispatch is unit-testable. */
interface PdfRendererReply {
    fun success(value: Any?)
    fun error(code: String, message: String?)
    fun notImplemented()
}

/**
 * Serializes PDF metadata and page raster work away from Android's main thread.
 *
 * A single worker is deliberate: [AndroidPdfRendererBackend] owns one page and
 * one ARGB bitmap only for the duration of a render. Serial dispatch prevents
 * concurrent channel requests from multiplying that raw 64 MP allocation.
 * Replies are handed to [replyExecutor], which production binds to the Android
 * main thread. Closing the dispatcher interrupts queued work and suppresses
 * replies after the Flutter engine has detached.
 */
class PdfRendererChannelDispatcher(
    private val router: PdfRendererMethodRouter,
    private val replyExecutor: Executor,
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "tangent-pdf-renderer").apply { isDaemon = true }
    },
) : AutoCloseable {
    private val closed = AtomicBoolean(false)

    fun dispatch(method: String, arguments: Any?, reply: PdfRendererReply) {
        if (closed.get()) {
            post(reply) {
                error("pdf_renderer_closed", "PDF renderer channel is detached")
            }
            return
        }
        try {
            worker.execute {
                try {
                    val value = router.handle(method, arguments)
                    post(reply) { success(value) }
                } catch (_: PdfRendererNotImplemented) {
                    post(reply) { notImplemented() }
                } catch (error: PdfRendererFailure) {
                    post(reply) { error(error.code, error.message) }
                } catch (error: Exception) {
                    post(reply) {
                        error(
                            "pdf_renderer",
                            error.message ?: "Android PDF renderer failed",
                        )
                    }
                }
            }
        } catch (_: RejectedExecutionException) {
            post(reply) {
                error("pdf_renderer_closed", "PDF renderer channel is detached")
            }
        }
    }

    private fun post(reply: PdfRendererReply, action: PdfRendererReply.() -> Unit) {
        replyExecutor.execute {
            if (!closed.get()) reply.action()
        }
    }

    override fun close() {
        if (closed.compareAndSet(false, true)) {
            worker.shutdownNow()
        }
    }
}
