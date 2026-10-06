// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.pdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
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
    fun closeShutsDownOwnedWorkerAndSuppressesDetachedReply() {
        val worker = Executors.newSingleThreadExecutor()
        val replyValue = AtomicReference<Any?>()
        val dispatcher = PdfRendererChannelDispatcher(
            PdfRendererMethodRouter(object : PdfRendererBackend {
                override fun inspect(sourcePath: String) = PdfDocumentInfo(emptyList())
                override fun render(
                    sourcePath: String,
                    outputPath: String,
                    pageNumber: Int,
                    width: Int,
                    height: Int,
                ) = Unit
            }),
            replyExecutor = Executor { command -> command.run() },
            worker = worker,
        )

        dispatcher.close()
        dispatcher.dispatch(
            "inspectDocument",
            mapOf("sourcePath" to "/private/source.pdf"),
            object : PdfRendererReply {
                override fun success(value: Any?) = replyValue.set(value)
                override fun error(code: String, message: String?) = replyValue.set(code)
                override fun notImplemented() = replyValue.set("notImplemented")
            },
        )

        assertTrue(worker.isShutdown)
        assertNull(replyValue.get())
    }
}
