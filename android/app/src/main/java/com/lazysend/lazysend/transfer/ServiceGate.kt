package com.lazysend.lazysend.transfer

import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.launch

/**
 * When the foreground service may end: it has nothing to do once no send runs and no host is kept going. Sends run here, under
 * a job of their own, so stopping them leaves the service's other work alone.
 */
class ServiceGate(private val hosting: () -> Boolean, private val finish: () -> Unit) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val running = AtomicInteger()
    private var wasHosting = hosting()

    private val idle: Boolean get() = running.get() == 0

    fun launch(block: suspend () -> Unit) {
        running.incrementAndGet()
        scope.launch {
            try {
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // Sender reports its own failures in the timeline; nothing here may take the process down.
            } finally {
                if (running.decrementAndGet() == 0 && !hosting()) finish()
            }
        }
    }

    fun cancelSends() = scope.coroutineContext.cancelChildren()

    /** After the service went to the foreground for a command: nothing was started and nothing is hosted. */
    fun started() {
        if (idle && !hosting()) finish()
    }

    /** Hosting stopped for good. Only a change from hosting counts; the value the service starts with is not one. */
    fun hostingChanged(now: Boolean) {
        val ended = wasHosting && !now
        wasHosting = now
        if (ended && idle) finish()
    }

    fun hostStopped() {
        if (idle) finish()
    }

    fun close() = scope.cancel()
}
