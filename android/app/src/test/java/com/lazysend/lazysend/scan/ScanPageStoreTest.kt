package com.lazysend.lazysend.scan

import java.io.File
import java.util.UUID
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

class ScanPageStoreTest {
    private lateinit var folder: File

    @Before
    fun setUp() {
        folder = File(System.getProperty("java.io.tmpdir"), "page-store-" + UUID.randomUUID())
    }

    @After
    fun tearDown() {
        folder.deleteRecursively()
    }

    private fun page(byte: Int, filter: CaptureFilter = CaptureFilter.Original): ScanPage {
        val corners = Quad(Pt(1.0, 2.0), Pt(90.0, 3.0), Pt(88.0, 120.0), Pt(4.0, 118.0))
        return ScanPage(corners = corners, filter = filter, jpeg = bytes(0xFF, 0xD8, byte), width = 600, height = 800,
            dpi = 150, gray = false)
    }

    private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }

    private fun exists(name: String) = File(folder, name).exists()

    private fun order() = File(folder, "order.json").readText()

    @Test
    fun aPageComesBackWithItsPictureCornersAndFilter() {
        val store = ScanPageStore(folder)
        val saved = page(1, CaptureFilter.Whiteboard)
        store.save(saved, bytes(9, 9))
        val loaded = ScanPageStore(folder).load().first()
        assertEquals(saved, loaded)
        assertEquals(CaptureFilter.Whiteboard, loaded.filter)
        assertEquals(listOf(600, 800, 150), listOf(loaded.width, loaded.height, loaded.dpi))
        assertEquals(bytes(9, 9).toList(), store.source(saved.id)!!.toList())
    }

    @Test
    fun pagesLoadInTheOrderTheyWereSavedAndReordered() {
        val store = ScanPageStore(folder)
        val pages = listOf(page(1), page(2), page(3))
        for (p in pages) store.save(p, ByteArray(0))
        assertEquals(pages.map { it.id }, store.load().map { it.id })
        store.setOrder(listOf(pages[2].id, pages[0].id, pages[1].id))
        assertEquals(listOf(pages[2].id, pages[0].id, pages[1].id), store.load().map { it.id })
    }

    @Test
    fun savingAPageAgainKeepsItsPlaceAndReplacesIt() {
        val store = ScanPageStore(folder)
        val pages = listOf(page(1), page(2))
        for (p in pages) store.save(p, bytes(1))
        store.save(pages[0].copy(jpeg = bytes(0xFF, 0xD8, 7)), bytes(2))
        val loaded = store.load()
        assertEquals(pages.map { it.id }, loaded.map { it.id })
        assertEquals(listOf(0xFF.toByte(), 0xD8.toByte(), 7.toByte()), loaded[0].jpeg.toList())
        assertEquals(listOf<Byte>(2), store.source(pages[0].id)!!.toList())
        assertEquals(emptyList<String>(), folder.list()!!.filter { it.startsWith(".tmp-") })
    }

    @Test
    fun aRemovedPageIsGoneFromDisk() {
        val store = ScanPageStore(folder)
        val pages = listOf(page(1), page(2))
        for (p in pages) store.save(p, bytes(5))
        store.remove(pages[0].id)
        assertEquals(listOf(pages[1].id), store.load().map { it.id })
        assertNull(store.source(pages[0].id))
        assertFalse(exists(pages[0].id.toString()))
    }

    @Test
    fun clearingRemovesEveryPage() {
        val store = ScanPageStore(folder)
        for (b in 1..3) store.save(page(b), ByteArray(0))
        store.removeAll()
        assertFalse(folder.exists())
        assertTrue(store.load().isEmpty())
        store.save(page(4), ByteArray(0))
        assertEquals(1, store.load().size)
    }

    @Test
    fun anIncompleteFolderThatIsNotListedAndTheTemporaryOnesAreRemoved() {
        val store = ScanPageStore(folder)
        val kept = page(1)
        store.save(kept, ByteArray(0))
        val stray = UUID.randomUUID().toString()
        File(folder, stray).mkdirs()
        File(folder, "$stray/page.jpg").writeBytes(bytes(1))
        val temp = ".tmp-" + UUID.randomUUID()
        File(folder, temp).mkdirs()
        assertEquals(listOf(kept.id), store.load().map { it.id })
        assertFalse(exists(stray))
        assertFalse(exists(temp))
    }

    @Test
    fun aListedPageThatCannotBeReadStaysOnDiskAndInTheList() {
        val store = ScanPageStore(folder)
        val pages = listOf(page(1), page(2))
        for (p in pages) store.save(p, bytes(3))
        File(folder, "${pages[0].id}/page.json").writeText("not json")
        assertEquals(listOf(pages[1].id), store.load().map { it.id })
        assertTrue(exists(pages[0].id.toString()))
        assertEquals(listOf<Byte>(3), store.source(pages[0].id)!!.toList())
        assertEquals(pages.map { it.id.toString() }, listIds())
    }

    private fun listIds() = Regex("[0-9a-f-]{36}").findAll(order()).map { it.value }.toList()

    @Test
    fun aCompletePageTheListLacksIsAddedAtTheEnd() {
        val store = ScanPageStore(folder)
        val pages = listOf(page(1), page(2), page(3))
        for (p in pages) store.save(p, bytes(1))
        store.setOrder(listOf(pages[2].id))
        val loaded = store.load()
        assertEquals(pages.map { it.id }.toSet(), loaded.map { it.id }.toSet())
        assertEquals(pages[2].id, loaded.first().id)
        assertEquals(3, store.load().size)
        assertTrue(exists(pages[0].id.toString()))
        val list = listIds()
        assertEquals(3, list.size)
        assertEquals(pages[2].id.toString(), list.first())
    }

    @Test
    fun aMissingOrUnreadableListDeletesNothing() {
        val store = ScanPageStore(folder)
        val pages = listOf(page(1), page(2))
        for (p in pages) store.save(p, bytes(1))
        val stray = UUID.randomUUID().toString()
        File(folder, stray).mkdirs()
        File(folder, "order.json").writeText("[")
        assertEquals(pages.map { it.id }.toSet(), store.load().map { it.id }.toSet())
        assertTrue(exists(stray))
        File(folder, "order.json").delete()
        assertEquals(pages.map { it.id }.toSet(), store.load().map { it.id }.toSet())
        assertTrue(exists(stray))
        assertTrue(exists(pages[0].id.toString()))
    }

    @Test
    fun savingWithoutAPhotoKeepsTheOneStored() {
        val store = ScanPageStore(folder)
        val saved = page(1)
        store.save(saved, bytes(4, 4))
        store.save(saved.copy(filter = CaptureFilter.Grayscale, jpeg = bytes(0xFF, 0xD8, 9)), null)
        assertEquals(listOf<Byte>(4, 4), store.source(saved.id)!!.toList())
        assertEquals(CaptureFilter.Grayscale, store.load().first().filter)
        assertEquals(9.toByte(), store.load().first().jpeg[2])
        try {
            store.save(page(2), null)
            fail("a new page needs its photo")
        } catch (expected: java.io.IOException) {
        }
        assertEquals(1, store.load().size)
        assertEquals(emptyList<String>(), folder.list()!!.filter { it.startsWith(".tmp-") })
    }

    @Test
    fun aPageMovedAsideByAKilledSaveComesBack() {
        val store = ScanPageStore(folder)
        val saved = page(1)
        store.save(saved, bytes(6))
        File(folder, saved.id.toString()).renameTo(File(folder, ".tmp-old-${saved.id}"))
        assertEquals(listOf(saved), store.load())
        assertEquals(listOf<Byte>(6), store.source(saved.id)!!.toList())
        assertFalse(exists(".tmp-old-${saved.id}"))
    }
}
