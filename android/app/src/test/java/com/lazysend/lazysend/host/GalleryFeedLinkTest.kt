package com.lazysend.lazysend.host

import android.app.Application
import java.io.ByteArrayInputStream
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36], application = Application::class)
class GalleryFeedLinkTest {
    private fun fixture(
        library: () -> List<com.lazysend.lazysend.transfer.Asset>,
        open: (com.lazysend.lazysend.transfer.Asset) -> java.io.InputStream = { ByteArrayInputStream(byteArrayOf(1, 2, 3)) },
    ) = HostFixture(assets = library, openAsset = open)

    @Test
    fun aGuestGetsGalleryItemsWithTheirIdAndDateAndAcknowledgesThemOneByOne() = runBlocking {
        val library = libraryOf(25)
        fixture({ library }).use { host ->
            val guest = host.pair()
            host.core.feed.start(guest.deviceId).join()
            val client = host.client(guest)
            val first = client.outbox(0).items
            assertEquals(20, first.size)
            assertEquals("external_primary:image:1", first[0].sourceId)
            assertEquals("2021-03-15T12:00:01Z", first[0].taken)
            client.acknowledge(first[0].id)
            val deadline = System.currentTimeMillis() + 10_000
            while (System.currentTimeMillis() < deadline && client.outbox(0).items.size < 20) Thread.sleep(20)
            val next = client.outbox(0).items
            assertEquals(20, next.size)
            assertTrue(next.none { it.sourceId == first[0].sourceId })
            assertEquals(1, host.core.feed.progress.value[guest.deviceId]?.sent)
        }
    }

    @Test
    fun stopWhileTheGuestIsStillDownloadingKeepsThatItem() = runBlocking {
        // Big enough that the host cannot finish writing before the guest reads.
        val library = libraryOf(3, sizes = mapOf(1 to 64L * 1024 * 1024))
        fixture({ library }, { asset -> java.io.ByteArrayInputStream(ByteArray(asset.size.toInt())) }).use { host ->
            val guest = host.pair()
            host.core.feed.start(guest.deviceId).join()
            val client = host.client(guest)
            val busy = client.outbox(0).items.first()
            client.download(busy.id, 0).use { download ->
                val began = System.currentTimeMillis() + 10_000
                while (!host.core.outbox.isServing(busy.id) && System.currentTimeMillis() < began) Thread.sleep(20)
                assertTrue(host.core.outbox.isServing(busy.id))
                host.core.feed.stop(guest.deviceId)
                assertEquals(listOf(busy.id), host.core.outbox.pending(guest.deviceId).map { it.id })
                var total = 0L
                val buffer = ByteArray(1 shl 16)
                while (true) {
                    val n = download.body.read(buffer)
                    if (n < 0) break
                    total += n
                }
                assertEquals(64L * 1024 * 1024, total)
            }
            client.acknowledge(busy.id)
            assertTrue(host.core.outbox.pending(guest.deviceId).isEmpty())
            val end = System.currentTimeMillis() + 10_000
            while (host.core.outbox.isServing(busy.id) && System.currentTimeMillis() < end) Thread.sleep(20)
            assertTrue(!host.core.outbox.isServing(busy.id))
        }
    }

    @Test
    fun aDateOutsideTheUsableYearsIsLeftOutOfTheReply() = runBlocking {
        val library = libraryOf(1, taken = -5_000_000_000_000)
        fixture({ library }).use { host ->
            val guest = host.pair()
            host.core.feed.start(guest.deviceId).join()
            val item = host.client(guest).outbox(0).items.single()
            assertNull(item.taken)
            assertEquals("external_primary:image:1", item.sourceId)
        }
    }

    @Test
    fun removingTheGuestEndsItsFeed() = runBlocking {
        val library = libraryOf(25)
        fixture({ library }).use { host ->
            val guest = host.pair()
            host.core.feed.start(guest.deviceId).join()
            host.core.removeGuest(guest.deviceId)
            assertTrue(host.core.outbox.pending(guest.deviceId).isEmpty())
            assertNull(host.core.feed.progress.value[guest.deviceId])
            assertEquals(0, java.io.File(host.dir, "host/outgoing").listFiles()?.size ?: 0)
        }
    }
}
