package com.lazysend.lazysend.transfer

import android.app.Application
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import com.lazysend.lazysend.data.EntryState
import com.lazysend.lazysend.data.Pc
import com.lazysend.lazysend.data.PcStore
import com.lazysend.lazysend.data.Timeline
import com.lazysend.lazysend.link.FakePc
import com.lazysend.lazysend.link.TEST_SECRET
import com.lazysend.lazysend.link.encodeBase64Url
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36], application = Application::class)
class SenderTest {
    private val pc = FakePc()
    private val dir = File.createTempFile("sender", "").also { it.delete(); it.mkdirs() }
    private val store = PcStore(File(dir, "pcs.json"), { it }, { it })
    private val timeline = Timeline(File(dir, "timeline.json"))
    private val paired = Pc("desktop-test-01", "Test PC", encodeBase64Url(pc.pin), listOf(pc.endpoint.host), pc.endpoint.port, TEST_SECRET)

    @After
    fun stop() {
        pc.close()
        dir.deleteRecursively()
    }

    private fun sender(vararg assets: Asset): Sender {
        val context = ApplicationProvider.getApplicationContext<Application>()
        store.put(paired)
        val list = object : MediaAssets(context) {
            override fun list() = assets.toList()
        }
        return Sender(context, PcConnector(store, null), timeline, list)
    }

    @Test
    fun anAssetThatCannotBeReadIsSkippedNotRetried() = runBlocking {
        val gone = Asset("external_primary:image:1", Uri.parse("content://nothing/1"), "gone.jpg", 10, "image/jpeg", 0)

        sender(gone).syncGallery(paired)

        val entry = timeline.get("gallery-desktop-test-01")!!
        assertEquals(EntryState.Done, entry.state)
        assertEquals("1 could not be sent", entry.detail)
        assertEquals(0, pc.requests.count { it.startsWith("PUT") })
        assertTrue(pc.requests.count { it == "GET /v1/hello" } <= 2)
    }
}
