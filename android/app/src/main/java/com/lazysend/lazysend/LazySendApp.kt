package com.lazysend.lazysend

import android.app.Application
import android.os.Build
import android.os.storage.StorageManager
import android.provider.Settings
import com.lazysend.lazysend.data.PcStore
import com.lazysend.lazysend.data.SecretBox
import com.lazysend.lazysend.data.Timeline
import com.lazysend.lazysend.host.GalleryIndex
import com.lazysend.lazysend.host.HostAdvertiser
import com.lazysend.lazysend.host.HostController
import com.lazysend.lazysend.host.HostIdentity
import com.lazysend.lazysend.transfer.MediaAssets
import com.lazysend.lazysend.transfer.NsdFinder
import com.lazysend.lazysend.transfer.GalleryParts
import com.lazysend.lazysend.transfer.Notifications
import com.lazysend.lazysend.transfer.PcCheckWorker
import com.lazysend.lazysend.transfer.PcConnector
import com.lazysend.lazysend.transfer.MediaFiles
import com.lazysend.lazysend.transfer.Receiver
import com.lazysend.lazysend.transfer.Sender
import com.lazysend.lazysend.ui.PhotoAccess
import java.io.File
import java.io.IOException
import okhttp3.OkHttpClient

class AppGraph(private val app: Application) {
    private val box = SecretBox()
    private val files = MediaFiles(app)
    val pcs = PcStore(File(app.filesDir, "pcs.json"), box::seal, box::open)
    val timeline = Timeline(File(app.filesDir, "timeline.json"))
    val notifications = Notifications(app)
    val connector = PcConnector(pcs, NsdFinder(app), OkHttpClient())
    private val media = MediaAssets(app)
    val sender = Sender(app, connector, timeline, media)
    val receiver = Receiver(
        connector, timeline, files, GalleryIndex(File(app.filesDir, "guest-index")), GalleryParts(File(app.filesDir, "gallery-parts.json")),
        notifications::received,
    )

    private fun deviceName() = Settings.Global.getString(app.contentResolver, "device_name")?.takeIf { it.isNotBlank() } ?: Build.MODEL

    // What the storage manager can free counts as free, so a phone full of cache still takes a file.
    private fun freeBytes() = runCatching {
        app.getSystemService(StorageManager::class.java).getAllocatableBytes(StorageManager.UUID_DEFAULT)
    }.getOrDefault(0L)

    /** This phone as a host: its id as a host is the id it gives hosts as a guest. */
    val host = HostController(
        File(app.filesDir, "host"), files, timeline, { pcs.phoneId }, ::deviceName, ::freeBytes,
        {
            val key = HostIdentity.androidKey()
            HostIdentity(File(app.filesDir, "host/cert.der"), key.private, key.public, ::deviceName)
        },
        advertiser = HostAdvertiser(app), notifyReceived = notifications::received,
        assets = { if (MainActivity.photoAccess(app) == PhotoAccess.None) null else media.list() },
        openAsset = { app.contentResolver.openInputStream(it.uri) ?: throw IOException("Cannot open ${it.uri}") },
    )
}

class LazySendApp : Application() {
    val graph by lazy { AppGraph(this) }

    override fun onCreate() {
        super.onCreate()
        PcCheckWorker.schedule(this)
    }
}
