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
    val sourceId: String? = null,
    /** When the asset was taken, epoch milliseconds. */
    val taken: Long? = null,
    val queued: Long,
    val clip: Boolean = false,
)

/** The guest already has as many items waiting as the outbox holds. */
class OutboxFullException : IllegalStateException("Too many items wait for this device.")

/** The phone is too full to make another copy. */
class LowStorageException : IllegalStateException("This phone is almost out of storage.")

@Serializable
private data class OutboxFile(val items: List<OutboxItem> = emptyList())

/**
 * What waits for each guest to pick it up, kept in a JSON file so it survives a restart. An item stays until the guest
 * acknowledges it; the copy of a file goes with it. A guest that asks with nothing queued waits and is woken when
 * something is. Safe to use from any thread.
 */
class Outbox(
    private val file: File,
    private val copies: File,
    private val clock: () -> Long = System::currentTimeMillis,
    private val freeSpace: () -> Long = { Long.MAX_VALUE },
) {
    private var items = loadJson(file) { OutboxFile() }.items
    private val changes = MutableStateFlow(0)

    // Items whose file is being sent right now, by how many downloads.
    private val serving = HashMap<String, Int>()

    /** Called with each item the guest acknowledges, after it is removed and before anything else can see it gone; it must not call back into the outbox. */
    @Volatile
    var onAcknowledged: (OutboxItem) -> Unit = {}

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

    fun queueText(deviceId: String, text: String, clip: Boolean = false): OutboxItem {
        require(text.isNotEmpty() && text.toByteArray().size <= MAX_TEXT_BYTES) { "The text is empty or too long." }
        return add(OutboxItem(newId(), deviceId, "text", text = text, queued = clock(), clip = clip))
    }

    fun queueLink(deviceId: String, url: String, clip: Boolean = false): OutboxItem {
        require(isAcceptableUrl(url)) { "Only http and https addresses can be sent." }
        return add(OutboxItem(newId(), deviceId, "link", url = url, queued = clock(), clip = clip))
    }

    /**
     * Copies what [open] reads (about [size] bytes, when known) into the app's storage and queues it; the copy is deleted once
     * the guest has it. A file from this phone's library carries its [sourceId] and when it was [taken].
     */
    fun queueFile(
        deviceId: String,
        name: String,
        mime: String?,
        size: Long? = null,
        sourceId: String? = null,
        taken: Long? = null,
        clip: Boolean = false,
        open: () -> InputStream,
    ): OutboxItem {
        if (pending(deviceId).size >= MAX_QUEUED) throw OutboxFullException()
        // The copy is made here, so the 1 GiB floor holds for it as it does for what arrives.
        if (freeSpace() - (size ?: 0) < MIN_FREE_BYTES) throw LowStorageException()
        val id = newId()
        val copy = File(copies, id)
        copies.mkdirs()
        try {
            open().use { input -> copy.outputStream().use { input.copyTo(it) } }
            return add(OutboxItem(id, deviceId, "file", path = copy.path, name = cleanFileName(name), size = copy.length(), mime = mime, sourceId = sourceId, taken = taken, queued = clock(), clip = clip))
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
            onAcknowledged(item)
            item
        }
        removed.path?.let { File(it).delete() }
        changes.value++
        return removed
    }

    /** The router is about to send the item's file; the item stays through [removeGalleryItems] until [endServing]. */
    @Synchronized
    fun beginServing(id: String) {
        serving[id] = (serving[id] ?: 0) + 1
    }

    @Synchronized
    fun endServing(id: String) {
        val left = (serving[id] ?: 1) - 1
        if (left <= 0) serving.remove(id) else serving[id] = left
    }

    @Synchronized
    fun isServing(id: String) = id in serving

    /**
     * Takes the gallery items back out for the guest without acknowledging them, with their copies, except the ones being
     * downloaded right now, which the guest acknowledges as usual; returns how many.
     */
    fun removeGalleryItems(deviceId: String): Int {
        val gone = synchronized(this) {
            val mine = items.filter { it.deviceId == deviceId && it.sourceId != null && it.id !in serving }
            if (mine.isEmpty()) return 0
            items = items - mine.toSet()
            save()
            mine
        }
        gone.forEach { item -> item.path?.let { File(it).delete() } }
        changes.value++
        return gone.size
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
        if (items.count { it.deviceId == item.deviceId } >= MAX_QUEUED) throw OutboxFullException()
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
