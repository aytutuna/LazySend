package com.lazysend.lazysend.transfer

import com.lazysend.lazysend.data.EntryKind
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ClipTest {
    private val zone = ZoneId.of("UTC")
    private val time = 1_794_751_402_123L

    @Test
    fun textLinkAndFileEntriesBecomeClipContent() {
        assertEquals(ClipContent.Text("hello"), clipContent(EntryKind.Text, "hello", null, null))
        assertEquals(ClipContent.Link("https://alazy.app/"), clipContent(EntryKind.Link, "https://alazy.app/", null, null))
        assertEquals(ClipContent.Saved("content://media/1", "image/png", "a.png"), clipContent(EntryKind.File, "a.png", "content://media/1", "image/png"))
    }

    @Test
    fun nothingIsClippedForAnEmptyNoteAnUnsavedFileOrAGallery() {
        assertNull(clipContent(EntryKind.Text, "", null, null))
        assertNull(clipContent(EntryKind.File, "a.png", null, "image/png"))
        assertNull(clipContent(EntryKind.Gallery, "Photos and videos", "content://media/1", null))
    }

    @Test
    fun aPhotoIsNamedByItsTimeAndGetsMillisecondsOnlyWhenTheNameIsTaken() {
        val plain = photoName(time, zone)
        assertEquals("Photo 2026-11-15 14.03.22.jpg", plain)
        assertEquals(plain, photoName(time, zone) { false })
        assertEquals("Photo 2026-11-15 14.03.22.123.jpg", photoName(time, zone) { it == plain })
    }

    @Test
    fun aClipboardFileIsNamedByItsTimeAndType() {
        assertEquals("Clipboard 2026-11-15 14.03.22.png", clipboardName(time, "png", zone))
    }

    @Test
    fun aPictureOrFileOnTheClipboardWinsOverTextAndBlankIsNothing() {
        assertEquals(Pasted.Attachment("content://x/1", "image/png"), pasted("a.png", "content://x/1", "image/png"))
        assertEquals(Pasted.Note("hello"), pasted("hello", "content://x/2", "text/plain"))
        assertEquals(Pasted.Note("https://alazy.app/"), pasted("https://alazy.app/", null, null))
        assertNull(pasted("  ", null, null))
        assertNull(pasted(null, "content://x/3", null))
    }
}
