package com.lazysend.lazysend.host

import java.io.File
import kotlinx.serialization.Serializable

@Serializable
class SentItem(val deviceId: String, val sendId: String, val kind: String, val id: String, val at: Long)

@Serializable
private class SentFile(val items: List<SentItem> = emptyList())

/** The texts and links guests sent with a send id, kept for a day so a repeated post is not shown twice. */
class SendLog(private val file: File, private val clock: () -> Long = System::currentTimeMillis) {
    private var items = loadJson(file) { SentFile() }.items

    @Synchronized
    fun find(deviceId: String, sendId: String): SentItem? {
        val now = clock()
        return items.firstOrNull { it.deviceId == deviceId && it.sendId == sendId && now - it.at <= DAY_MS }
    }

    @Synchronized
    fun add(deviceId: String, sendId: String, kind: String, id: String) {
        val now = clock()
        items = items.filter { now - it.at <= DAY_MS } + SentItem(deviceId, sendId, kind, id, now)
        runCatching { file.saveJson(SentFile(items)) }
    }

    @Synchronized
    fun removeDevice(deviceId: String) {
        items = items.filter { it.deviceId != deviceId }
        runCatching { file.saveJson(SentFile(items)) }
    }

    private companion object {
        const val DAY_MS = 24 * 60 * 60 * 1000L
    }
}
