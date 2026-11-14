package com.lazysend.lazysend.host

/** Requests and failed secrets per peer address over a sliding minute. */
class RateLimiter {
    private class Entry {
        val failures = ArrayDeque<Long>()
        val requests = ArrayDeque<Long>()
        var lastUsed = 0L
    }

    private val entries = HashMap<String, Entry>()

    @Synchronized
    fun isBlocked(peer: String, now: Long): Boolean {
        val entry = entries[peer] ?: return false
        prune(entry.failures, now)
        return entry.failures.size >= MAX_FAILURES
    }

    /** Counts a request; false when the peer is over its limit or blocked. */
    @Synchronized
    fun tryRequest(peer: String, now: Long): Boolean {
        val entry = entryFor(peer, now)
        prune(entry.failures, now)
        prune(entry.requests, now)
        if (entry.failures.size >= MAX_FAILURES || entry.requests.size >= MAX_REQUESTS) return false
        entry.requests.addLast(now)
        return true
    }

    @Synchronized
    fun recordFailure(peer: String, now: Long) {
        val entry = entryFor(peer, now)
        prune(entry.failures, now)
        entry.failures.addLast(now)
        while (entry.failures.size > MAX_FAILURES) entry.failures.removeFirst()
    }

    private fun entryFor(peer: String, now: Long): Entry {
        val entry = entries.getOrPut(peer) {
            if (entries.size >= MAX_TRACKED) entries.minByOrNull { it.value.lastUsed }?.key?.let(entries::remove)
            Entry()
        }
        entry.lastUsed = now
        return entry
    }

    private fun prune(times: ArrayDeque<Long>, now: Long) {
        while (times.isNotEmpty() && (now - times.first() >= WINDOW_MS || times.first() > now)) times.removeFirst()
    }

    companion object {
        const val MAX_FAILURES = 10
        const val MAX_REQUESTS = 3000
        const val MAX_TRACKED = 1024
        const val WINDOW_MS = 60_000L
    }
}
