package com.lazysend.lazysend.transfer

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ServiceGateTest {
    private var hosting = false
    private val finished = AtomicInteger()
    private val gate = ServiceGate({ hosting }, { finished.incrementAndGet() })

    @Test
    fun theValueTheServiceStartsWithEndsNothing() {
        gate.hostingChanged(false)
        assertEquals(0, finished.get())
    }

    @Test
    fun aSendToAPcWithNoGuestRunsAndThenEndsTheService() {
        val inside = CountDownLatch(1)
        val release = CountDownLatch(1)
        gate.hostingChanged(false)
        gate.launch {
            inside.countDown()
            release.await()
        }
        gate.started()
        assertTrue(inside.await(5, TimeUnit.SECONDS))
        assertEquals(0, finished.get())
        release.countDown()
        val until = System.currentTimeMillis() + 5000
        while (finished.get() == 0 && System.currentTimeMillis() < until) Thread.sleep(10)
        assertEquals(1, finished.get())
    }

    @Test
    fun aCommandThatStartedNothingEndsTheServiceAtOnce() {
        gate.started()
        assertEquals(1, finished.get())
    }

    @Test
    fun hostingEndingEndsTheServiceOnlyWhenNoSendRuns() {
        hosting = true
        val busy = ServiceGate({ hosting }, { finished.incrementAndGet() })
        val release = CountDownLatch(1)
        busy.launch { release.await() }
        hosting = false
        busy.hostingChanged(false)
        assertEquals(0, finished.get())
        release.countDown()
        val until = System.currentTimeMillis() + 5000
        while (finished.get() == 0 && System.currentTimeMillis() < until) Thread.sleep(10)
        assertEquals(1, finished.get())
    }

    @Test
    fun hostingWithNothingElseRunningKeepsTheServiceUntilItEnds() {
        hosting = true
        val hosted = ServiceGate({ hosting }, { finished.incrementAndGet() })
        hosted.started()
        assertEquals(0, finished.get())
        hosting = false
        hosted.hostingChanged(false)
        assertEquals(1, finished.get())
    }
}
