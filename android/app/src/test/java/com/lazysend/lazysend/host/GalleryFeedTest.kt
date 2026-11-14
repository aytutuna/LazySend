package com.lazysend.lazysend.host

import android.app.Application
import android.net.Uri
import com.lazysend.lazysend.transfer.Asset
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

fun libraryOf(count: Int, taken: Long = 1_615_809_600_000, sizes: Map<Int, Long> = emptyMap()) =
    (1..count).map { Asset("external_primary:image:$it", Uri.parse("content://media/$it"), "IMG_$it.jpg", sizes[it] ?: 3, "image/jpeg", taken + it * 1000L) }

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36], application = Application::class)
class GalleryFeedTest {
    private val dir = File.createTempFile("feed", "").also { it.delete(); it.mkdirs() }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val guest = "phone-0001"
    private val opened = AtomicInteger()
    private var library = libraryOf(50)
    private var free = Long.MAX_VALUE
    private val failures = HashMap<String, Int>()
    private var queueBytes = FEED_QUEUE_BYTES
    private var readMs = 0L
    private var outbox = newOutbox()
    private var feed = newFeed()

    private val outgoing get() = File(dir, "outgoing")

    private fun newOutbox() = Outbox(File(dir, "outbox.json"), outgoing, freeSpace = { free })

    private fun newFeed() = GalleryFeed(
        outbox, GalleryIndex(File(dir, "feed-index")), File(dir, "feeds.json"), scope, { Thread.sleep(readMs); library },
        { asset ->
            opened.incrementAndGet()
            val failing = failures[asset.sourceId] ?: 0
            if (failing > 0) {
                failures[asset.sourceId] = failing - 1
                throw IOException("gone")
            }
            ByteArrayInputStream(ByteArray(asset.size.toInt()) { 1 })
        },
        retryMs = 50,
        queueBytes = queueBytes,
    )

    // What a restart does: the same files, new objects.
    private fun restart() {
        outbox = newOutbox()
        feed = newFeed()
    }

    private fun queued() = outbox.pending(guest).filter { it.sourceId != null }

    private fun copies() = outgoing.listFiles()?.size ?: 0

    private fun waitFor(what: String, condition: () -> Boolean) {
        val end = System.currentTimeMillis() + 10_000
        while (System.currentTimeMillis() < end && !condition()) Thread.sleep(10)
        assertTrue(what, condition())
    }

    @After
    fun tearDown() {
        scope.cancel()
    }

    @Test
    fun neverMoreThanTwentyAreQueuedAndNothingIsCopiedAhead() = runBlocking {
        feed.start(guest).join()
        assertEquals(20, queued().size)
        assertEquals(20, opened.get())
        assertEquals(20, copies())
        assertEquals(FeedProgress(0, 50, false), feed.progress.value[guest])
        val first = queued().first()
        assertEquals("external_primary:image:1", first.sourceId)
        assertEquals("IMG_1.jpg", first.name)
        assertEquals(1_615_809_601_000, first.taken)
    }

    @Test
    fun anAcknowledgementMarksTheItemSentAndTopsUp() = runBlocking {
        feed.start(guest).join()
        val first = queued().first()
        outbox.acknowledge(guest, first.id)
        waitFor("topped up") { queued().size == 20 && opened.get() == 21 }
        assertEquals(1, feed.progress.value[guest]?.sent)
        assertTrue(queued().none { it.sourceId == first.sourceId })
        assertFalse(File(first.path!!).exists())
        waitFor("copies") { copies() == 20 }
    }

    @Test
    fun aRestartResumesWithoutSendingAgain() = runBlocking {
        feed.start(guest).join()
        val done = queued().take(5)
        done.forEach { outbox.acknowledge(guest, it.id) }
        waitFor("topped up") { queued().size == 20 }
        val waiting = queued().map { it.sourceId }.toSet()
        restart()
        assertEquals(setOf(guest), feed.running())
        feed.resume().join()
        assertEquals(waiting, queued().map { it.sourceId }.toSet())
        assertEquals(5, feed.progress.value[guest]?.sent)
        assertEquals(50, feed.progress.value[guest]?.total)
        queued().forEach { outbox.acknowledge(guest, it.id) }
        waitFor("topped up") { queued().size == 20 }
        val seen = done.map { it.sourceId }.toSet() + waiting
        assertTrue(queued().none { it.sourceId in seen })
    }

    @Test
    fun stopClearsTheQueueAndTheCopies() = runBlocking {
        feed.start(guest).join()
        feed.stop(guest)
        assertTrue(queued().isEmpty())
        assertEquals(0, copies())
        assertNull(feed.progress.value[guest])
        restart()
        assertTrue(feed.running().isEmpty())
    }

    @Test
    fun stopKeepsWhatTheGuestAlreadyHas() = runBlocking {
        feed.start(guest).join()
        outbox.acknowledge(guest, queued().first().id)
        waitFor("topped up") { opened.get() == 21 && queued().size == 20 }
        feed.stop(guest)
        feed.start(guest).join()
        assertEquals(49, feed.progress.value[guest]?.total)
        assertTrue(queued().none { it.sourceId == "external_primary:image:1" })
    }

    @Test
    fun removingTheGuestClearsEverything() = runBlocking {
        feed.start(guest).join()
        outbox.acknowledge(guest, queued().first().id)
        waitFor("topped up") { opened.get() == 21 && queued().size == 20 }
        feed.reconcile(emptySet())
        assertTrue(queued().isEmpty())
        assertEquals(0, copies())
        assertNull(feed.progress.value[guest])
        feed.start(guest).join()
        assertEquals(50, feed.progress.value[guest]?.total)
    }

    @Test
    fun aPairedGuestIsLeftAloneByTheCheck() = runBlocking {
        feed.start(guest).join()
        feed.reconcile(setOf(guest))
        assertEquals(20, queued().size)
    }

    @Test
    fun theRunEndsWhenEveryAssetIsSentAndAnotherRunSendsOnlyNewOnes() = runBlocking {
        library = libraryOf(25)
        feed.start(guest).join()
        waitFor("everything sent") {
            queued().forEach { outbox.acknowledge(guest, it.id) }
            feed.progress.value[guest]?.done == true
        }
        assertEquals(FeedProgress(25, 25, true), feed.progress.value[guest])
        assertTrue(feed.running().isEmpty())
        assertEquals(0, copies())
        library = libraryOf(26)
        feed.start(guest).join()
        assertEquals(FeedProgress(0, 1, false), feed.progress.value[guest])
        assertEquals(listOf("external_primary:image:26"), queued().map { it.sourceId })
    }

    @Test
    fun anAssetThatFailsToOpenIsTriedOnceMoreAtTheEnd() = runBlocking {
        library = libraryOf(3)
        failures["external_primary:image:2"] = 1
        feed.start(guest).join()
        assertEquals(listOf(1, 3, 2).map { "external_primary:image:$it" }, queued().map { it.sourceId })
        queued().forEach { outbox.acknowledge(guest, it.id) }
        waitFor("done") { feed.progress.value[guest]?.done == true }
        assertEquals(FeedProgress(3, 3, true), feed.progress.value[guest])
    }

    @Test
    fun anAssetThatFailsTwiceIsCountedAsNotSent() = runBlocking {
        library = libraryOf(3)
        failures["external_primary:image:2"] = 5
        feed.start(guest).join()
        assertEquals(2, queued().size)
        assertEquals(4, opened.get())
        queued().forEach { outbox.acknowledge(guest, it.id) }
        waitFor("done") { feed.progress.value[guest]?.done == true }
        assertEquals(FeedProgress(2, 3, true, failed = 1), feed.progress.value[guest])
        restart()
        assertEquals(1, feed.progress.value[guest]?.failed)
    }

    @Test
    fun oneOversizeItemStillGoesAndTheRestWaitForTheByteCap() = runBlocking {
        library = libraryOf(4, sizes = mapOf(1 to 150L, 2 to 60L, 3 to 60L))
        queueBytes = 100
        restart()
        feed.start(guest).join()
        assertEquals(listOf("external_primary:image:1"), queued().map { it.sourceId })
        outbox.acknowledge(guest, queued()[0].id)
        // 60 bytes fit under the cap of 100 once, 120 do not.
        waitFor("next") { queued().map { it.sourceId } == listOf("external_primary:image:2") }
        Thread.sleep(200)
        assertEquals(listOf("external_primary:image:2"), queued().map { it.sourceId })
    }

    @Test
    fun aFullOutboxMakesTheFeedWaitInsteadOfDroppingAssets() = runBlocking {
        repeat(MAX_QUEUED) { outbox.queueText(guest, "note $it") }
        feed.start(guest).join()
        assertEquals(FeedWait.Outbox, feed.progress.value[guest]?.wait)
        assertEquals(0, opened.get())
        assertTrue(queued().isEmpty())
        outbox.acknowledge(guest, outbox.pending(guest).first().id)
        waitFor("one queued") { queued().size == 1 }
        assertEquals("external_primary:image:1", queued().first().sourceId)
        assertEquals(1, opened.get())
        waitFor("waiting again") { feed.progress.value[guest]?.wait == FeedWait.Outbox }
    }

    @Test
    fun removingTheGuestWhileTheLibraryIsBeingReadCancelsTheStart() = runBlocking {
        readMs = 300
        restart()
        val starting = feed.start(guest)
        Thread.sleep(50)
        feed.reconcile(emptySet())
        starting.join()
        assertNull(feed.progress.value[guest])
        assertTrue(queued().isEmpty())
        assertEquals(0, opened.get())
        assertEquals(0, copies())
    }

    @Test
    fun theTotalNeverFallsBehindWhatWasSent() = runBlocking {
        library = libraryOf(2)
        feed.start(guest).join()
        library = libraryOf(3)
        queued().forEach { outbox.acknowledge(guest, it.id) }
        waitFor("done") { feed.progress.value[guest]?.done == true }
        val p = feed.progress.value[guest]!!
        assertTrue(p.total >= p.sent)
    }

    @Test
    fun aPhoneThatIsAlmostFullWaitsAndTriesAgain() = runBlocking {
        free = 0
        feed.start(guest)
        assertTrue(queued().isEmpty())
        waitFor("shown") { feed.progress.value[guest]?.wait == FeedWait.Storage }
        free = Long.MAX_VALUE
        waitFor("queued") { queued().size == 20 }
        assertEquals("external_primary:image:1", queued().first().sourceId)
        assertNull(feed.progress.value[guest]?.wait)
    }

    @Test
    fun nothingStartsWhileTheLibraryCannotBeRead() = runBlocking {
        val closed = GalleryFeed(outbox, GalleryIndex(File(dir, "other-index")), File(dir, "other.json"), scope, { null }, { ByteArrayInputStream(ByteArray(0)) })
        closed.start(guest).join()
        assertNull(closed.progress.value[guest])
        assertTrue(queued().isEmpty())
    }
}
