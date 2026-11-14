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

fun libraryOf(count: Int, taken: Long = 1_615_809_600_000) =
    (1..count).map { Asset("external_primary:image:$it", Uri.parse("content://media/$it"), "IMG_$it.jpg", 3, "image/jpeg", taken + it * 1000L) }

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36], application = Application::class)
class GalleryFeedTest {
    private val dir = File.createTempFile("feed", "").also { it.delete(); it.mkdirs() }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val guest = "phone-0001"
    private val opened = AtomicInteger()
    private var library = libraryOf(50)
    private var free = Long.MAX_VALUE
    private var unreadable = emptySet<String>()
    private var outbox = newOutbox()
    private var feed = newFeed()

    private val outgoing get() = File(dir, "outgoing")

    private fun newOutbox() = Outbox(File(dir, "outbox.json"), outgoing, freeSpace = { free })

    private fun newFeed() = GalleryFeed(
        outbox, GalleryIndex(File(dir, "feed-index")), File(dir, "feeds.json"), scope, { library },
        { asset ->
            opened.incrementAndGet()
            if (asset.sourceId in unreadable) throw IOException("gone")
            ByteArrayInputStream(byteArrayOf(1, 2, 3))
        },
        retryMs = 50,
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
    fun anAssetThatCannotBeReadIsLeftOut() = runBlocking {
        unreadable = setOf("external_primary:image:2")
        feed.start(guest).join()
        assertEquals(20, queued().size)
        assertTrue(queued().none { it.sourceId == "external_primary:image:2" })
    }

    @Test
    fun aPhoneThatIsAlmostFullWaitsAndTriesAgain() = runBlocking {
        free = 0
        feed.start(guest)
        assertTrue(queued().isEmpty())
        waitFor("shown") { feed.progress.value[guest]?.lowStorage == true }
        free = Long.MAX_VALUE
        waitFor("queued") { queued().size == 20 }
        assertEquals("external_primary:image:1", queued().first().sourceId)
        assertEquals(false, feed.progress.value[guest]?.lowStorage)
    }

    @Test
    fun nothingStartsWhileTheLibraryCannotBeRead() = runBlocking {
        val closed = GalleryFeed(outbox, GalleryIndex(File(dir, "other-index")), File(dir, "other.json"), scope, { null }, { ByteArrayInputStream(ByteArray(0)) })
        closed.start(guest).join()
        assertNull(closed.progress.value[guest])
        assertTrue(queued().isEmpty())
    }
}
