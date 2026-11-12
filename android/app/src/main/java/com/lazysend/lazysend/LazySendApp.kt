package com.lazysend.lazysend

import android.app.Application
import com.lazysend.lazysend.data.PcStore
import com.lazysend.lazysend.data.SecretBox
import com.lazysend.lazysend.data.Timeline
import com.lazysend.lazysend.transfer.MediaAssets
import com.lazysend.lazysend.transfer.NsdFinder
import com.lazysend.lazysend.transfer.Notifications
import com.lazysend.lazysend.transfer.PcCheckWorker
import com.lazysend.lazysend.transfer.PcConnector
import com.lazysend.lazysend.transfer.MediaFiles
import com.lazysend.lazysend.transfer.Receiver
import com.lazysend.lazysend.transfer.Sender
import java.io.File
import okhttp3.OkHttpClient

class AppGraph(app: Application) {
    private val box = SecretBox()
    val pcs = PcStore(File(app.filesDir, "pcs.json"), box::seal, box::open)
    val timeline = Timeline(File(app.filesDir, "timeline.json"))
    val notifications = Notifications(app)
    val connector = PcConnector(pcs, NsdFinder(app), OkHttpClient())
    val sender = Sender(app, connector, timeline, MediaAssets(app))
    val receiver = Receiver(connector, timeline, MediaFiles(app), notifications::received)
}

class LazySendApp : Application() {
    val graph by lazy { AppGraph(this) }

    override fun onCreate() {
        super.onCreate()
        PcCheckWorker.schedule(this)
    }
}
