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
import com.lazysend.lazysend.AppGraph
import com.lazysend.lazysend.LazySendApp
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.withContext

/**
 * Runs uploads in the foreground so they go on when the app is in the background, and keeps this phone's host running while
 * a guest is paired, so it takes what arrives with the screen off.
 */
class SendService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private lateinit var gate: ServiceGate
    private lateinit var graph: AppGraph
    private lateinit var notifications: Notifications

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        graph = (application as LazySendApp).graph
        notifications = graph.notifications
        combine(graph.sender.progress, graph.host.state, graph.host.keepAlive) { shown, host, hosting ->
            when {
                shown != null -> notifications.progress(shown.title, shown.text, shown.done, shown.total, stopIntent())
                hosting -> notifications.hosting(host.link, hostStopIntent())
                else -> notifications.progress(getString(com.lazysend.lazysend.R.string.sending), "", 0, 0, stopIntent())
            }
        }.onEach { getSystemService(android.app.NotificationManager::class.java).notify(NOTIFICATION_ID, it) }.launchIn(scope)
        // Hosting ended, by the person or for good: nothing keeps the service but a send in progress.
        gate = ServiceGate({ graph.host.keepAlive.value }, ::finish)
        graph.host.keepAlive.onEach(gate::hostingChanged).launchIn(scope)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val first = if (intent?.action == ACTION_HOST && graph.host.keepAlive.value) {
            notifications.hosting(graph.host.state.value.link, hostStopIntent())
        } else {
            notifications.progress(getString(com.lazysend.lazysend.R.string.sending), "", 0, 0, stopIntent())
        }
        ServiceCompat.startForeground(this, NOTIFICATION_ID, first, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        val pc = intent?.getStringExtra(EXTRA_PC)?.let(graph.pcs::get)
        when (intent?.action) {
            ACTION_FILES -> if (pc != null) {
                val clip = intent.getBooleanExtra(EXTRA_CLIP, false)
                val at = intent.getLongExtra(EXTRA_AT, System.currentTimeMillis())
                val format = format(intent)
                // Each picture is converted and sent before the next is begun, so the first is on its way at once.
                gate.launch { for (uri in uris(intent)) graph.sender.sendFiles(pc, listOf(prepared(uri, format)), clip, at) }
            }
            ACTION_GALLERY -> if (pc != null) gate.launch { graph.sender.syncGallery(pc) }
            ACTION_STAGED -> intent.getStringArrayExtra(EXTRA_IDS)?.let { ids -> gate.launch { ids.forEach { graph.sender.sendStaged(it) } } }
            ACTION_PENDING -> gate.launch { graph.sender.resumePending() }
            ACTION_TEXT -> if (pc != null) textOf(intent)?.let { text -> gate.launch { graph.sender.sendText(pc, text, intent.getBooleanExtra(EXTRA_CLIP, false), intent.getLongExtra(EXTRA_AT, System.currentTimeMillis())) } }
            ACTION_QUEUE -> intent.getStringExtra(EXTRA_GUEST)?.let(graph.host.core.guests::get)?.let { guest ->
                val text = textOf(intent)
                val clip = intent.getBooleanExtra(EXTRA_CLIP, false)
                val format = format(intent)
                gate.launch {
                    withContext(Dispatchers.IO) {
                        if (text != null) graph.host.queueText(guest, text, clip)
                        else for (uri in uris(intent)) graph.host.queueUris(guest, contentResolver, listOf(preparedNow(uri, format)), clip)
                    }
                }
            }
            ACTION_STOP -> gate.cancelSends()
            ACTION_STOP_HOST -> {
                graph.host.stop()
                gate.hostStopped()
            }
        }
        gate.started()
        return START_NOT_STICKY
    }

    // Android 15 limits how long a data sync service may run in a day; what is half done is paused and can be resumed.
    override fun onTimeout(startId: Int, fgsType: Int) {
        if (graph.host.keepAlive.value) notifications.hostingPaused()
        gate.cancelSends()
        graph.host.suspendHosting()
        finish()
    }

    override fun onDestroy() {
        scope.cancel()
        gate.close()
        getSystemService(android.app.NotificationManager::class.java).cancel(NOTIFICATION_ID)
        super.onDestroy()
    }

    private fun finish() {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    // A long text came by a file: an intent that carries over a few hundred kilobytes is refused by the system.
    private fun textOf(intent: Intent): String? = intent.getStringExtra(EXTRA_TEXT) ?: intent.getStringExtra(EXTRA_TEXT_FILE)?.let { path ->
        File(path).let { file -> runCatching { file.readText() }.getOrNull().also { file.delete() } }
    }

    private fun format(intent: Intent) = intent.getStringExtra(EXTRA_FORMAT)?.let(PhotoFormat::valueOf)

    private fun preparedNow(uri: Uri, format: PhotoFormat?) = if (format == null) uri else preparedForSend(this, uri, format)

    private suspend fun prepared(uri: Uri, format: PhotoFormat?) = withContext(Dispatchers.IO) { preparedNow(uri, format) }

    private fun uris(intent: Intent): List<Uri> {
        val clip = intent.clipData ?: return emptyList()
        return (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri }
    }

    private fun stopIntent() = PendingIntent.getService(
        this, 1, Intent(this, SendService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE,
    )

    private fun hostStopIntent() = PendingIntent.getService(
        this, 2, Intent(this, SendService::class.java).setAction(ACTION_STOP_HOST), PendingIntent.FLAG_IMMUTABLE,
    )

    companion object {
        private const val ACTION_FILES = "com.lazysend.lazysend.SEND_FILES"
        private const val ACTION_GALLERY = "com.lazysend.lazysend.SEND_GALLERY"
        private const val ACTION_TEXT = "com.lazysend.lazysend.SEND_TEXT"
        private const val ACTION_STAGED = "com.lazysend.lazysend.SEND_STAGED"
        private const val ACTION_PENDING = "com.lazysend.lazysend.SEND_PENDING"
        private const val ACTION_QUEUE = "com.lazysend.lazysend.QUEUE"
        private const val ACTION_HOST = "com.lazysend.lazysend.HOST"
        private const val ACTION_STOP = "com.lazysend.lazysend.STOP"
        private const val ACTION_STOP_HOST = "com.lazysend.lazysend.STOP_HOST"
        private const val EXTRA_PC = "pc"
        private const val EXTRA_IDS = "ids"
        private const val EXTRA_GUEST = "guest"
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_TEXT_FILE = "textFile"
        private const val INLINE_TEXT_CHARS = 50_000
        private const val EXTRA_CLIP = "clip"
        private const val EXTRA_AT = "at"
        private const val EXTRA_FORMAT = "format"
        private const val NOTIFICATION_ID = 1

        fun sendFiles(context: Context, pcId: String, uris: List<Uri>, clip: Boolean = false, at: Long = System.currentTimeMillis(), format: PhotoFormat? = null) {
            if (uris.isEmpty()) return
            val intent = Intent(context, SendService::class.java).setAction(ACTION_FILES).putExtra(EXTRA_PC, pcId).putExtra(EXTRA_CLIP, clip).putExtra(EXTRA_AT, at).putExtra(EXTRA_FORMAT, format?.name)
            intent.clipData = clip(uris)
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            ContextCompat.startForegroundService(context, intent)
        }

        /** Uploads files the sender has already copied into its own folder, by the id of their rows. */
        fun sendStaged(context: Context, ids: List<String>) {
            ContextCompat.startForegroundService(
                context, Intent(context, SendService::class.java).setAction(ACTION_STAGED).putExtra(EXTRA_IDS, ids.toTypedArray()),
            )
        }

        /** Sends everything that was kept because it did not get through. */
        fun sendPending(context: Context) {
            ContextCompat.startForegroundService(context, Intent(context, SendService::class.java).setAction(ACTION_PENDING))
        }

        fun sendText(context: Context, pcId: String, text: String, clip: Boolean = false, at: Long = System.currentTimeMillis()) {
            val intent = Intent(context, SendService::class.java).setAction(ACTION_TEXT).putExtra(EXTRA_PC, pcId).putExtra(EXTRA_CLIP, clip).putExtra(EXTRA_AT, at)
            ContextCompat.startForegroundService(context, withText(context, intent, text))
        }

        /** Queues what was picked or shared for a guest of this phone; it is copied here, so the source can go away. */
        fun queueFiles(context: Context, guestId: String, uris: List<Uri>, clip: Boolean = false, format: PhotoFormat? = null) {
            if (uris.isEmpty()) return
            val intent = Intent(context, SendService::class.java).setAction(ACTION_QUEUE).putExtra(EXTRA_GUEST, guestId).putExtra(EXTRA_CLIP, clip).putExtra(EXTRA_FORMAT, format?.name)
            intent.clipData = clip(uris)
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            ContextCompat.startForegroundService(context, intent)
        }

        fun queueText(context: Context, guestId: String, text: String, clip: Boolean = false) {
            val intent = Intent(context, SendService::class.java).setAction(ACTION_QUEUE).putExtra(EXTRA_GUEST, guestId).putExtra(EXTRA_CLIP, clip)
            ContextCompat.startForegroundService(context, withText(context, intent, text))
        }

        /** Keeps the host running with the screen off; called while the app is in front. */
        fun keepHosting(context: Context) {
            ContextCompat.startForegroundService(context, Intent(context, SendService::class.java).setAction(ACTION_HOST))
        }

        fun syncGallery(context: Context, pcId: String) {
            ContextCompat.startForegroundService(
                context, Intent(context, SendService::class.java).setAction(ACTION_GALLERY).putExtra(EXTRA_PC, pcId),
            )
        }

        fun stop(context: Context) {
            context.startService(Intent(context, SendService::class.java).setAction(ACTION_STOP))
        }

        private fun withText(context: Context, intent: Intent, text: String): Intent {
            if (text.length <= INLINE_TEXT_CHARS) return intent.putExtra(EXTRA_TEXT, text)
            val file = File(File(context.cacheDir, "notes").also { it.mkdirs() }, UUID.randomUUID().toString())
            file.writeText(text)
            return intent.putExtra(EXTRA_TEXT_FILE, file.path)
        }

        private fun clip(uris: List<Uri>) = ClipData.newRawUri(null, uris.first()).also { clip -> uris.drop(1).forEach { clip.addItem(ClipData.Item(it)) } }
    }
}
