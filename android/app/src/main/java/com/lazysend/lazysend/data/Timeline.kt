package com.lazysend.lazysend.data

import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import com.lazysend.lazysend.link.LinkJson

enum class Direction { Sent, Received }

enum class EntryKind { Text, Link, File, Gallery }

enum class EntryState { Active, Paused, Done, Failed }

@Serializable
data class TimelineEntry(
    val id: String,
    val time: Long,
    val direction: Direction,
    val kind: EntryKind,
    val pcName: String,
    /** The text or address for a note, the file name for a file, "Photos and videos" for a gallery sync. */
    val title: String,
    val detail: String = "",
    val state: EntryState = EntryState.Active,
    val bytes: Long = 0,
    val totalBytes: Long = 0,
    val count: Int = 0,
    val totalCount: Int = 0,
    /** Where a received file was saved, or the half-saved file of a download in progress. */
    val uri: String? = null,
    val mime: String? = null,
)

/** Sent and received things, newest first, kept in a JSON file. */
class Timeline(private val file: File, private val limit: Int = 500) {
    private val state = MutableStateFlow(load())

    val entries: StateFlow<List<TimelineEntry>> get() = state

    private fun load(): List<TimelineEntry> {
        val saved = runCatching { LinkJson.decodeFromString<List<TimelineEntry>>(file.readText()) }.getOrDefault(emptyList())
        // Nothing is running when the app starts, so what was in progress is paused.
        return saved.map { if (it.state == EntryState.Active) it.copy(state = EntryState.Paused) else it }
    }

    fun get(id: String): TimelineEntry? = state.value.firstOrNull { it.id == id }

    fun add(entry: TimelineEntry) {
        state.update { (listOf(entry) + it.filterNot { e -> e.id == entry.id }).take(limit) }
        save()
    }

    fun update(id: String, change: (TimelineEntry) -> TimelineEntry) {
        state.update { list -> list.map { if (it.id == id) change(it) else it } }
    }

    /** Progress changes often and only the state at the end matters, so it is written when [save] is called. */
    @Synchronized
    fun save() {
        val temp = File(file.parentFile, file.name + ".tmp")
        temp.writeText(LinkJson.encodeToString(state.value))
        temp.renameTo(file)
    }

    fun remove(id: String) {
        state.update { list -> list.filterNot { it.id == id } }
        save()
    }

    fun clear() {
        state.value = emptyList()
        save()
    }
}
