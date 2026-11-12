package com.lazysend.lazysend.transfer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.lazysend.lazysend.MainActivity
import com.lazysend.lazysend.R

class Notifications(private val context: Context) {
    init {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(TRANSFERS, context.getString(R.string.channel_transfers), NotificationManager.IMPORTANCE_LOW),
        )
        manager.createNotificationChannel(
            NotificationChannel(RECEIVED, context.getString(R.string.channel_received), NotificationManager.IMPORTANCE_DEFAULT),
        )
    }

    private fun openApp() = PendingIntent.getActivity(
        context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    fun received(id: Int, title: String, text: String) {
        val notification = NotificationCompat.Builder(context, RECEIVED)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(openApp())
            .setAutoCancel(true)
            .build()
        try {
            NotificationManagerCompat.from(context).notify(id, notification)
        } catch (e: SecurityException) {
            // Notifications are off for the app.
        }
    }

    fun progress(title: String, text: String, done: Long, total: Long, stop: PendingIntent?): Notification =
        NotificationCompat.Builder(context, TRANSFERS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setContentIntent(openApp())
            .setProgress(if (total > 0) 1000 else 0, if (total > 0) (done * 1000 / total).toInt() else 0, total <= 0)
            .also { if (stop != null) it.addAction(0, context.getString(R.string.stop), stop) }
            .build()

    private companion object {
        const val TRANSFERS = "transfers"
        const val RECEIVED = "received"
    }
}
