// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.pdf

import java.io.File
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
 * Runs PDF work off-main with one active request and at most one pending request.
 *
 * A newly arrived request replaces stale pending work instead of accumulating in
 * an unbounded executor queue. The active request retains its page/bitmap until
 * completion; Dart can explicitly cancel it by request id when that page leaves
 * the viewport. A cancelled active render is allowed to leave framework code,
 * then its output is deleted and exactly one cancellation result is delivered.
 */
class PdfRendererChannelDispatcher(
    private val router: PdfRendererMethodRouter,
    private val replyExecutor: Executor,
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "tangent-pdf-renderer").apply { isDaemon = true }
    },
) : AutoCloseable {
    private val closed = AtomicBoolean(false)
    private val queueLock = Any()
    private var active: Request? = null
    private var pending: Request? = null

    fun dispatch(method: String, arguments: Any?, reply: PdfRendererReply) {
        if (method == "cancelRender") {
            cancelRender(arguments, reply)
            return
        }
        if (closed.get()) return

        val request = Request(method, arguments, reply)
        var start: Request? = null
        var dropped: Request? = null
        synchronized(queueLock) {
            if (closed.get()) return
            if (active == null) {
                active = request
                start = request
            } else {
                dropped = pending
                pending = request
            }
        }
        dropped?.let(::completeCancelled)
        start?.let(::launch)
    }

    private fun launch(request: Request) {
        try {
            worker.execute {
                execute(request)
                val next = synchronized(queueLock) {
                    if (active === request) active = pending
                    pending = null
                    active
                }
                if (next != null && !closed.get()) launch(next)
            }
        } catch (_: RejectedExecutionException) {
            synchronized(queueLock) {
                if (active === request) active = null
            }
            completeError(request, "pdf_renderer_closed", "PDF renderer channel is detached")
        }
    }

    private fun execute(request: Request) {
        if (request.cancelled.get()) {
            completeCancelled(request)
            return
        }
        try {
            val value = router.handle(request.method, request.arguments)
            if (request.cancelled.get()) {
                deleteCompletedRender(request)
                completeCancelled(request)
            } else {
                complete(request) { success(value) }
            }
        } catch (_: PdfRendererNotImplemented) {
            complete(request) { notImplemented() }
        } catch (error: PdfRendererFailure) {
            completeError(request, error.code, error.message)
        } catch (error: Exception) {
            completeError(
                request,
                "pdf_renderer",
                error.message ?: "Android PDF renderer failed",
            )
        }
    }

    private fun cancelRender(arguments: Any?, reply: PdfRendererReply) {
        if (closed.get()) return
        val requestId = (arguments as? Map<*, *>)?.get("requestId") as? String
        if (requestId.isNullOrBlank()) {
            post(reply) { error("invalid_arguments", "Missing requestId") }
            return
        }
        var cancelledPending: Request? = null
        val found = synchronized(queueLock) {
            when {
                active?.requestId == requestId -> {
                    active?.cancelled?.set(true)
                    true
                }
                pending?.requestId == requestId -> {
                    cancelledPending = pending
                    pending = null
                    true
                }
                else -> false
            }
        }
        cancelledPending?.let(::completeCancelled)
        post(reply) { success(mapOf("cancelled" to found)) }
    }

    private fun deleteCompletedRender(request: Request) {
        if (request.method != "renderPage") return
        val outputPath = (request.arguments as? Map<*, *>)?.get("outputPath") as? String
        if (!outputPath.isNullOrBlank()) File(outputPath).delete()
    }

    private fun completeCancelled(request: Request) =
        completeError(request, "render_cancelled", "PDF page render was superseded")

    private fun completeError(request: Request, code: String, message: String?) =
        complete(request) { error(code, message) }

    private fun complete(request: Request, action: PdfRendererReply.() -> Unit) {
        if (!request.completed.compareAndSet(false, true)) return
        post(request.reply, action)
    }

    private fun post(reply: PdfRendererReply, action: PdfRendererReply.() -> Unit) {
        replyExecutor.execute {
            if (!closed.get()) reply.action()
        }
    }

    override fun close() {
        if (closed.compareAndSet(false, true)) {
            synchronized(queueLock) {
                active?.cancelled?.set(true)
                pending = null
            }
            worker.shutdownNow()
        }
    }

    private class Request(
        val method: String,
        val arguments: Any?,
        val reply: PdfRendererReply,
    ) {
        val requestId: String? = (arguments as? Map<*, *>)?.get("requestId") as? String
        val cancelled = AtomicBoolean(false)
        val completed = AtomicBoolean(false)
    }
}
