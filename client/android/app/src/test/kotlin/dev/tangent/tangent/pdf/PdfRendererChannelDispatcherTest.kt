// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.pdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

class PdfRendererChannelDispatcherTest {
    @Test
    fun backendRunsOffCallingThreadAndReplyUsesReplyExecutor() {
        val callerThread = Thread.currentThread().name
        val backendThread = AtomicReference<String>()
        val replyThread = AtomicReference<String>()
        val replied = CountDownLatch(1)
        val replyWorker = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "pdf-test-replies")
        }
        val backend = object : PdfRendererBackend {
            override fun inspect(sourcePath: String): PdfDocumentInfo {
                backendThread.set(Thread.currentThread().name)
                return PdfDocumentInfo(listOf(PdfPageSize(10, 20)))
            }

            override fun render(
                sourcePath: String,
                outputPath: String,
                pageNumber: Int,
                width: Int,
                height: Int,
            ) = error("not used")
        }
        PdfRendererChannelDispatcher(
            PdfRendererMethodRouter(backend),
            replyExecutor = Executor { command -> replyWorker.execute(command) },
        ).use { dispatcher ->
            dispatcher.dispatch(
                "inspectDocument",
                mapOf("sourcePath" to "/private/source.pdf"),
                object : PdfRendererReply {
                    override fun success(value: Any?) {
                        replyThread.set(Thread.currentThread().name)
                        replied.countDown()
                    }

                    override fun error(code: String, message: String?) =
                        throw AssertionError("unexpected $code: $message")

                    override fun notImplemented() =
                        throw AssertionError("unexpected notImplemented")
                },
            )

            assertTrue("worker reply timed out", replied.await(5, TimeUnit.SECONDS))
            assertNotEquals(callerThread, backendThread.get())
            assertTrue(backendThread.get().startsWith("tangent-pdf-renderer"))
            assertEquals("pdf-test-replies", replyThread.get())
        }
        replyWorker.shutdownNow()
    }

    @Test
    fun concurrentRenderRequestsHoldOnlyOneBackendPageAtATime() {
        val firstEntered = CountDownLatch(1)
        val releaseFirst = CountDownLatch(1)
        val secondEntered = CountDownLatch(1)
        val replies = CountDownLatch(2)
        val active = AtomicInteger()
        val maximumActive = AtomicInteger()
        val calls = AtomicInteger()
        val backend = object : PdfRendererBackend {
            override fun inspect(sourcePath: String) = error("not used")

            override fun render(
                sourcePath: String,
                outputPath: String,
                pageNumber: Int,
                width: Int,
                height: Int,
            ) {
                val call = calls.incrementAndGet()
                val nowActive = active.incrementAndGet()
                maximumActive.accumulateAndGet(nowActive, ::maxOf)
                try {
                    if (call == 1) {
                        firstEntered.countDown()
                        check(releaseFirst.await(5, TimeUnit.SECONDS))
                    } else {
                        secondEntered.countDown()
                    }
                } finally {
                    active.decrementAndGet()
                }
            }
        }
        val dispatcher = PdfRendererChannelDispatcher(
            PdfRendererMethodRouter(backend),
            replyExecutor = Executor { command -> command.run() },
        )
        try {
            val reply = object : PdfRendererReply {
                override fun success(value: Any?) = replies.countDown()
                override fun error(code: String, message: String?) =
                    throw AssertionError("unexpected $code: $message")
                override fun notImplemented() =
                    throw AssertionError("unexpected notImplemented")
            }
            val args = mapOf(
                "sourcePath" to "/private/source.pdf",
                "outputPath" to "/private/page.png",
                "pageNumber" to 1,
                "width" to 8000,
                "height" to 8000,
                "format" to "png",
            )

            dispatcher.dispatch("renderPage", args, reply)
            dispatcher.dispatch("renderPage", args, reply)

            assertTrue("first render did not start", firstEntered.await(5, TimeUnit.SECONDS))
            assertFalse(
                "second render entered while the first still owned its page bitmap",
                secondEntered.await(250, TimeUnit.MILLISECONDS),
            )
            releaseFirst.countDown()
            assertTrue("render replies timed out", replies.await(5, TimeUnit.SECONDS))
            assertEquals(2, calls.get())
            assertEquals(1, maximumActive.get())
        } finally {
            releaseFirst.countDown()
            dispatcher.close()
        }
    }

    @Test
    fun fastFlingOf100PagesKeepsOnlyActiveAndNewestPendingRequest() {
        val firstEntered = CountDownLatch(1)
        val releaseFirst = CountDownLatch(1)
        val replies = CountDownLatch(100)
        val calls = AtomicInteger()
        val errors = AtomicInteger()
        val pages = java.util.Collections.synchronizedList(mutableListOf<Int>())
        val backend = object : PdfRendererBackend {
            override fun inspect(sourcePath: String) = error("not used")
            override fun render(
                sourcePath: String,
                outputPath: String,
                pageNumber: Int,
                width: Int,
                height: Int,
            ) {
                pages.add(pageNumber)
                if (calls.incrementAndGet() == 1) {
                    firstEntered.countDown()
                    check(releaseFirst.await(5, TimeUnit.SECONDS))
                }
            }
        }
        val dispatcher = PdfRendererChannelDispatcher(
            PdfRendererMethodRouter(backend),
            replyExecutor = Executor { command -> command.run() },
        )
        val reply = object : PdfRendererReply {
            override fun success(value: Any?) = replies.countDown()
            override fun error(code: String, message: String?) {
                assertEquals("render_cancelled", code)
                errors.incrementAndGet()
                replies.countDown()
            }
            override fun notImplemented() = throw AssertionError("unexpected notImplemented")
        }
        try {
            fun args(page: Int) = mapOf(
                "requestId" to "page-$page",
                "sourcePath" to "/private/source.pdf",
                "outputPath" to "/private/page-$page.png",
                "pageNumber" to page,
                "width" to 100,
                "height" to 100,
                "format" to "png",
            )
            dispatcher.dispatch("renderPage", args(1), reply)
            assertTrue("first render did not start", firstEntered.await(5, TimeUnit.SECONDS))
            for (page in 2..100) dispatcher.dispatch("renderPage", args(page), reply)
            releaseFirst.countDown()

            assertTrue("render replies timed out", replies.await(5, TimeUnit.SECONDS))
            assertEquals(listOf(1, 100), pages)
            assertEquals(2, calls.get())
            assertEquals(98, errors.get())
        } finally {
            releaseFirst.countDown()
            dispatcher.close()
        }
    }

    @Test
    fun cancellingActiveRenderDeletesStaleOutputAndRepliesExactlyOnce() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val renderReply = CountDownLatch(1)
        val cancelReply = CountDownLatch(1)
        val renderReplies = AtomicInteger()
        val output = kotlin.io.path.createTempFile("stale-pdf-", ".png").toFile()
        output.delete()
        val backend = object : PdfRendererBackend {
            override fun inspect(sourcePath: String) = error("not used")
            override fun render(
                sourcePath: String,
                outputPath: String,
                pageNumber: Int,
                width: Int,
                height: Int,
            ) {
                entered.countDown()
                check(release.await(5, TimeUnit.SECONDS))
                File(outputPath).writeBytes(byteArrayOf(1, 2, 3))
            }
        }
        val dispatcher = PdfRendererChannelDispatcher(
            PdfRendererMethodRouter(backend),
            replyExecutor = Executor { command -> command.run() },
        )
        try {
            dispatcher.dispatch(
                "renderPage",
                mapOf(
                    "requestId" to "stale",
                    "sourcePath" to "/private/source.pdf",
                    "outputPath" to output.path,
                    "pageNumber" to 1,
                    "width" to 100,
                    "height" to 100,
                    "format" to "png",
                ),
                object : PdfRendererReply {
                    override fun success(value: Any?) = throw AssertionError("stale success")
                    override fun error(code: String, message: String?) {
                        assertEquals("render_cancelled", code)
                        renderReplies.incrementAndGet()
                        renderReply.countDown()
                    }
                    override fun notImplemented() = throw AssertionError("unexpected")
                },
            )
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            dispatcher.dispatch(
                "cancelRender",
                mapOf("requestId" to "stale"),
                object : PdfRendererReply {
                    override fun success(value: Any?) = cancelReply.countDown()
                    override fun error(code: String, message: String?) =
                        throw AssertionError("unexpected $code")
                    override fun notImplemented() = throw AssertionError("unexpected")
                },
            )
            release.countDown()
            assertTrue(cancelReply.await(5, TimeUnit.SECONDS))
            assertTrue(renderReply.await(5, TimeUnit.SECONDS))
            assertEquals(1, renderReplies.get())
            assertFalse(output.exists())
        } finally {
            release.countDown()
            output.delete()
            dispatcher.close()
        }
    }
}
