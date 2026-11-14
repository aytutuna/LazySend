package com.lazysend.lazysend.host

import java.io.File

/**
 * The source ids (a guest's own asset ids) already received from each guest, so a gallery sync sends only what is new. One
 * text file per guest, an id on each line, appended to as files arrive and read whole once per run.
 */
class GalleryIndex(private val directory: File) {
    private val byDevice = HashMap<String, HashSet<String>>()

    @Synchronized
    fun contains(deviceId: String, sourceId: String) = load(deviceId).contains(sourceId)

    /** The ids not received from [deviceId] yet, in the order given, each once. */
    @Synchronized
    fun missing(deviceId: String, ids: List<String>): List<String> {
        val known = load(deviceId)
        val seen = HashSet<String>()
        return ids.filter { it !in known && seen.add(it) }
    }

    @Synchronized
    fun add(deviceId: String, sourceId: String) {
        if (!load(deviceId).add(sourceId)) return
        directory.mkdirs()
        File(directory, "$deviceId.txt").appendText(sourceId + "\n")
    }

    private fun load(deviceId: String): HashSet<String> = byDevice.getOrPut(deviceId) {
        val file = File(directory, "$deviceId.txt")
        if (file.exists()) file.readLines().filterTo(HashSet()) { it.isNotEmpty() } else HashSet()
    }
}
