package com.lazysend.lazysend.scan

import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

/**
 * The pages of a scan in a folder of the app's own, so they outlive the process: a folder per page holding its JPEG, its
 * photo as the camera wrote it and the rest in `page.json`, and `order.json` with the page ids in the order they go. Only
 * the pages are kept in memory; the photo is read back when a page is cut again.
 *
 * A page is written into a folder of its own named `.tmp-...` and moved into place whole, so its JPEG and its `page.json`
 * always belong together. Nothing is deleted because it could not be read; only folders that are not a complete page, and
 * that `order.json` does not list, are cleaned up. The store does no locking: the caller uses it from one thread.
 */
class ScanPageStore(private val folder: File) {
    @Serializable
    private class Meta(
        val corners: Quad,
        val filter: CaptureFilter,
        val width: Int,
        val height: Int,
        val dpi: Int,
        val gray: Boolean,
    )

    private val orderFile get() = File(folder, "order.json")

    /**
     * `source` is the photo the page was cut from; null for a page the store already has, which keeps its photo. A page
     * saved again (a cut again) keeps its place.
     */
    fun save(page: ScanPage, source: ByteArray?) {
        prepareFolder()
        val dir = pageFolder(page.id)
        val temp = File(folder, TEMP + UUID.randomUUID())
        try {
            check(temp.mkdirs()) { "Cannot create $temp" }
            val photo = File(temp, "source.jpg")
            if (source != null) photo.writeBytes(source) else File(dir, "source.jpg").copyTo(photo)
            File(temp, "page.jpg").writeBytes(page.jpeg)
            val meta = Meta(page.corners, page.filter, page.width, page.height, page.dpi, page.gray)
            File(temp, "page.json").writeText(json.encodeToString(Meta.serializer(), meta))
            if (dir.exists()) {
                // Moved aside, not deleted first: a kill between the two moves leaves the old page for load to put back.
                val aside = asideFolder(page.id)
                aside.deleteRecursively()
                Files.move(dir.toPath(), aside.toPath())
                Files.move(temp.toPath(), dir.toPath())
                aside.deleteRecursively()
            } else {
                Files.move(temp.toPath(), dir.toPath())
            }
        } catch (e: Exception) {
            temp.deleteRecursively()
            throw e
        }
        val ids = order() ?: emptyList()
        if (page.id !in ids) setOrder(ids + page.id)
    }

    fun source(id: UUID): ByteArray? = try {
        File(pageFolder(id), "source.jpg").readBytes()
    } catch (e: IOException) {
        null
    }

    /**
     * The pages in order. A page `order.json` lists but that cannot be read is left out of the result and stays on disk
     * and in the list. A complete page it does not list (it was lost from the list, or the process ended between the two
     * writes) is added at the end. With a list that was read, folders that are not a complete page, and the temporary
     * ones, are removed.
     */
    fun load(): List<ScanPage> {
        restoreAsides()
        val listed = order()
        val ids = listed ?: emptyList()
        val pages = ids.mapNotNull(::read).toMutableList()
        val adopted = ArrayList<UUID>()
        val strays = ArrayList<File>()
        for (file in folder.listFiles().orEmpty()) {
            val id = parse(file.name)
            if (id == null) {
                if (file.name.startsWith(TEMP)) strays.add(file)
                continue
            }
            if (id in ids) continue
            if (isComplete(file)) adopted.add(id) else strays.add(file)
        }
        adopted.sortBy { pageFolder(it).lastModified() }
        pages += adopted.mapNotNull(::read)
        if (listed != null) {
            if (adopted.isNotEmpty()) runCatching { setOrder(ids + adopted) }
            for (stray in strays) stray.deleteRecursively()
        }
        return pages
    }

    fun setOrder(ids: List<UUID>) {
        prepareFolder()
        val temp = File(folder, TEMP + "order.json")
        temp.writeText(json.encodeToString(ListSerializer(String.serializer()), ids.map { it.toString() }))
        Files.move(temp.toPath(), orderFile.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }

    /**
     * The folder goes first: a kill before the list is written leaves a listed id with no folder, which a load skips,
     * where the other way round would leave a whole folder the next load takes in again.
     */
    fun remove(id: UUID) {
        pageFolder(id).deleteRecursively()
        order()?.let { ids -> runCatching { setOrder(ids.filter { it != id }) } }
    }

    fun removeAll() {
        folder.deleteRecursively()
    }

    private fun pageFolder(id: UUID) = File(folder, id.toString())

    private fun asideFolder(id: UUID) = File(folder, "$TEMP$ASIDE$id")

    private fun prepareFolder() {
        if (!folder.isDirectory && !folder.mkdirs()) throw IOException("Cannot create $folder")
    }

    /** A page moved aside by a save that was cut short, whose new folder never arrived, goes back. */
    private fun restoreAsides() {
        for (file in folder.listFiles().orEmpty()) {
            if (!file.name.startsWith(TEMP + ASIDE)) continue
            val id = parse(file.name.removePrefix(TEMP + ASIDE)) ?: continue
            if (!pageFolder(id).exists() && isComplete(file)) {
                runCatching { Files.move(file.toPath(), pageFolder(id).toPath()) }
            }
        }
    }

    /** Null when the file is not there or cannot be read, which is not the same as an empty list. */
    private fun order(): List<UUID>? = try {
        json.decodeFromString(ListSerializer(String.serializer()), orderFile.readText()).map(UUID::fromString)
    } catch (e: Exception) {
        null
    }

    private fun parse(name: String): UUID? =
        if (name.length == 36) runCatching { UUID.fromString(name) }.getOrNull() else null

    private fun isComplete(dir: File) = PARTS.all { File(dir, it).exists() }

    private fun read(id: UUID): ScanPage? {
        val dir = pageFolder(id)
        return try {
            val jpeg = File(dir, "page.jpg").readBytes()
            val meta = json.decodeFromString(Meta.serializer(), File(dir, "page.json").readText())
            ScanPage(id, meta.corners, meta.filter, jpeg, meta.width, meta.height, meta.dpi, meta.gray)
        } catch (e: Exception) {
            null
        }
    }

    private companion object {
        const val TEMP = ".tmp-"
        const val ASIDE = "old-"
        val PARTS = listOf("page.jpg", "source.jpg", "page.json")
        val json = Json
    }
}
