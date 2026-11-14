package com.lazysend.lazysend.host

import java.io.File
import java.io.IOException
import java.io.InputStream
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable

/** Something this phone wants a guest to have. A file is a copy in the app's storage until the guest has it. */
@Serializable
data class OutboxItem(
    val id: String,
    val deviceId: String,
    val kind: String,
    val text: String? = null,
    val url: String? = null,
    val path: String? = null,
    val name: String? = null,
    val size: Long? = null,
    val mime: String? = null,
    val queued: Long,
)

@Serializable
private data class OutboxFile(val items: List<OutboxItem> = emptyList())

/**
 * What waits for each guest to pick it up, kept in a JSON file so it survives a restart. An item stays until the guest
 * acknowledges it; the copy of a file goes with it. A guest that asks with nothing queued waits and is woken when
 * something is. Safe to use from any thread.
 */
class Outbox(private val file: File, private val copies: File, private val clock: () -> Long = System::currentTimeMillis) {
    private var items = loadJson(file) { OutboxFile() }.items
    private val changes = MutableStateFlow(0)

    init {
        // A copy no entry points to is left from a process that died while copying.
        val kept = items.mapNotNull { it.path }.toSet()
        copies.listFiles()?.filter { it.path !in kept }?.forEach { it.delete() }
    }

    /** How many items wait, so a screen can show it. */
    val count: Int @Synchronized get() = items.size

    @Synchronized
    fun pending(deviceId: String): List<OutboxItem> = items.filter { it.deviceId == deviceId }

    @Synchronized
    fun find(deviceId: String, id: String): OutboxItem? = items.firstOrNull { it.deviceId == deviceId && it.id == id }

    fun queueText(deviceId: String, text: String): OutboxItem {
        require(text.isNotEmpty() && text.toByteArray().size <= MAX_TEXT_BYTES) { "The text is empty or too long." }
        return add(OutboxItem(newId(), deviceId, "text", text = text, queued = clock()))
    }

    fun queueLink(deviceId: String, url: String): OutboxItem {
        require(isAcceptableUrl(url)) { "Only http and https addresses can be sent." }
        return add(OutboxItem(newId(), deviceId, "link", url = url, queued = clock()))
    }

    /** Copies what [open] reads into the app's storage and queues it; the copy is deleted once the guest has it. */
    fun queueFile(deviceId: String, name: String, mime: String?, open: () -> InputStream): OutboxItem {
        check(pending(deviceId).size < MAX_QUEUED) { "Too many items wait for this device." }
        val id = newId()
        val copy = File(copies, id)
        copies.mkdirs()
        try {
            open().use { input -> copy.outputStream().use { input.copyTo(it) } }
            return add(OutboxItem(id, deviceId, "file", path = copy.path, name = cleanFileName(name), size = copy.length(), mime = mime, queued = clock()))
        } catch (e: Exception) {
            copy.delete()
            throw e
        }
    }

    /** The guest's pending items; when there are none, waits up to [waitMs] for one to be queued. */
    suspend fun await(deviceId: String, waitMs: Long): List<OutboxItem> {
        val now = pending(deviceId)
        if (now.isNotEmpty() || waitMs <= 0) return now
        withTimeoutOrNull(waitMs) { changes.first { pending(deviceId).isNotEmpty() } }
        return pending(deviceId)
    }

    /** The guest has the item: removes it and its copy; null when it was not there. */
    fun acknowledge(deviceId: String, id: String): OutboxItem? {
        val removed = synchronized(this) {
            val item = items.firstOrNull { it.deviceId == deviceId && it.id == id } ?: return null
            items = items - item
            save()
            item
        }
        removed.path?.let { File(it).delete() }
        changes.value++
        return removed
    }

    /** Drops everything waiting for the guest (it was removed). */
    fun clear(deviceId: String) {
        val dropped = synchronized(this) {
            val mine = items.filter { it.deviceId == deviceId }
            if (mine.isEmpty()) return
            items = items - mine.toSet()
            save()
            mine
        }
        dropped.forEach { item -> item.path?.let { File(it).delete() } }
        changes.value++
    }

    /** Drops everything, as when this phone's key changed and every guest has to pair again. */
    fun clearAll() {
        val dropped = synchronized(this) {
            val all = items
            items = emptyList()
            save()
            all
        }
        dropped.forEach { item -> item.path?.let { File(it).delete() } }
        copies.listFiles()?.forEach { it.delete() }
        changes.value++
    }

    @Synchronized
    private fun add(item: OutboxItem): OutboxItem {
        if (items.count { it.deviceId == item.deviceId } >= MAX_QUEUED) throw IllegalStateException("Too many items wait for this device.")
        val before = items
        items = items + item
        try {
            save()
        } catch (e: IOException) {
            items = before
            throw e
        }
        changes.value++
        return item
    }

    private fun save() = file.saveJson(OutboxFile(items))
}
