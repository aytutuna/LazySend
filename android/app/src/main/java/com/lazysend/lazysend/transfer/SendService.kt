package com.lazysend.lazysend.transfer

import android.app.PendingIntent
import android.app.Service
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.IBinder
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.lazysend.lazysend.LazySendApp
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch

/** Runs uploads in the foreground so they go on when the app is in the background. */
class SendService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val running = AtomicInteger()
    private lateinit var notifications: Notifications

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val graph = (application as LazySendApp).graph
        notifications = graph.notifications
        graph.sender.progress.onEach { shown ->
            val notification = notifications.progress(
                shown?.title ?: getString(com.lazysend.lazysend.R.string.sending), shown?.text.orEmpty(), shown?.done ?: 0, shown?.total ?: 0, stopIntent(),
            )
            getSystemService(android.app.NotificationManager::class.java).notify(NOTIFICATION_ID, notification)
        }.launchIn(scope)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ServiceCompat.startForeground(
            this, NOTIFICATION_ID,
            notifications.progress(getString(com.lazysend.lazysend.R.string.sending), "", 0, 0, stopIntent()),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
        )
        val graph = (application as LazySendApp).graph
        val pc = intent?.getStringExtra(EXTRA_PC)?.let(graph.pcs::get)
        when (intent?.action) {
            ACTION_FILES -> if (pc != null) launch { graph.sender.sendFiles(pc, uris(intent)) }
            ACTION_GALLERY -> if (pc != null) launch { graph.sender.syncGallery(pc) }
            ACTION_STOP -> scope.coroutineContext.cancelChildren()
        }
        if (running.get() == 0) finish()
        return START_NOT_STICKY
    }

    // Android 15 limits how long a data sync service may run in a day; what is half done is paused and can be resumed.
    override fun onTimeout(startId: Int, fgsType: Int) {
        scope.coroutineContext.cancelChildren()
        finish()
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun launch(block: suspend () -> Unit) {
        running.incrementAndGet()
        scope.launch {
            try {
                block()
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                // Sender reports its own failures in the timeline; nothing here may take the process down.
            } finally {
                if (running.decrementAndGet() == 0) finish()
            }
        }
    }

    private fun finish() {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun uris(intent: Intent): List<Uri> {
        val clip = intent.clipData ?: return emptyList()
        return (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri }
    }

    private fun stopIntent() = PendingIntent.getService(
        this, 1, Intent(this, SendService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE,
    )

    companion object {
        private const val ACTION_FILES = "com.lazysend.lazysend.SEND_FILES"
        private const val ACTION_GALLERY = "com.lazysend.lazysend.SEND_GALLERY"
        private const val ACTION_STOP = "com.lazysend.lazysend.STOP"
        private const val EXTRA_PC = "pc"
        private const val NOTIFICATION_ID = 1

        fun sendFiles(context: Context, pcId: String, uris: List<Uri>) {
            if (uris.isEmpty()) return
            val intent = Intent(context, SendService::class.java).setAction(ACTION_FILES).putExtra(EXTRA_PC, pcId)
            intent.clipData = ClipData.newRawUri(null, uris.first()).also { clip -> uris.drop(1).forEach { clip.addItem(ClipData.Item(it)) } }
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            ContextCompat.startForegroundService(context, intent)
        }

        fun syncGallery(context: Context, pcId: String) {
            ContextCompat.startForegroundService(
                context, Intent(context, SendService::class.java).setAction(ACTION_GALLERY).putExtra(EXTRA_PC, pcId),
            )
        }

        fun stop(context: Context) {
            context.startService(Intent(context, SendService::class.java).setAction(ACTION_STOP))
        }
    }
}
