package com.lazysend.lazysend.transfer

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.lazysend.lazysend.LazySendApp
import java.io.IOException

/** Now and then, when a PC can be reached, takes what it has queued for this phone. */
class PcCheckWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val graph = (applicationContext as LazySendApp).graph
        for (pc in graph.pcs.pcs.value) {
            val reached = graph.connector.connect(pc) as? Reach.Reached ?: continue
            try {
                graph.receiver.collect(pc, reached.client, wait = 0)
            } catch (e: IOException) {
                graph.connector.lost(pc.id)
            } catch (e: com.lazysend.lazysend.link.LinkException) {
                // This PC will be tried again at the next check.
            }
        }
        return Result.success()
    }

    companion object {
        fun schedule(context: Context) {
            val request = androidx.work.PeriodicWorkRequestBuilder<PcCheckWorker>(15, java.util.concurrent.TimeUnit.MINUTES).build()
            androidx.work.WorkManager.getInstance(context)
                .enqueueUniquePeriodicWork("pc-check", androidx.work.ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }
}
