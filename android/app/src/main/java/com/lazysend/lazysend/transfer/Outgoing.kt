package com.lazysend.lazysend.transfer

import com.lazysend.lazysend.link.LinkJson
import java.io.File
import java.io.InputStream
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString

/** A file waiting to go to a PC. Its copy stays in the app's own folder until the PC has it. */
@Serializable
data class OutgoingSend(
    /** The id of the timeline row too. */
    val id: String,
    val pcId: String,
    val name: String,
    val size: Long,
    val mime: String?,
    val modified: String?,
    val clip: Boolean,
    val at: Long,
    /** Kept across attempts, so the PC knows a repeat for the file it already has. */
    val sendId: String,
)

/** The unfinished sends to PCs and their copies: `list.json` and one file per send in a folder the system never clears. */
class Outgoing(private val folder: File) {
    private val list = File(folder, "list.json")
    private var sends: List<OutgoingSend> = runCatching { LinkJson.decodeFromString<List<OutgoingSend>>(list.readText()) }.getOrDefault(emptyList())

    @get:Synchronized
    val pending: List<OutgoingSend> get() = sends

    @Synchronized
    fun get(id: String): OutgoingSend? = sends.firstOrNull { it.id == id }

    fun file(send: OutgoingSend) = File(folder, send.id)

    /** Copies [input] and records the send; the copy is removed again if it cannot be finished. */
    @Synchronized
    fun add(send: OutgoingSend, input: InputStream): OutgoingSend {
        folder.mkdirs()
        val copy = file(send)
        try {
            copy.outputStream().use { input.copyTo(it) }
            val kept = send.copy(size = copy.length())
            sends = sends.filterNot { it.id == send.id } + kept
            save()
            return kept
        } catch (e: Exception) {
            copy.delete()
            throw e
        }
    }

    @Synchronized
    fun remove(id: String) {
        sends.firstOrNull { it.id == id }?.let { file(it).delete() }
        sends = sends.filterNot { it.id == id }
        save()
    }

    private fun save() {
        val temp = File(folder, "list.json.tmp")
        temp.writeText(LinkJson.encodeToString(sends))
        temp.renameTo(list)
    }
}
