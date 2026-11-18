package com.lazysend.lazysend.ui

import com.lazysend.lazysend.data.Direction
import com.lazysend.lazysend.data.EntryKind
import com.lazysend.lazysend.data.TimelineEntry
import org.junit.Assert.assertEquals
import org.junit.Test

class FilesFilterTest {
    private fun entry(id: String, kind: EntryKind, direction: Direction = Direction.Sent, clip: Boolean = false) =
        TimelineEntry(id, 0, direction, kind, "PC", id, clip = clip)

    private val entries = listOf(
        entry("text", EntryKind.Text),
        entry("clipped link", EntryKind.Link, Direction.Received, clip = true),
        entry("photo", EntryKind.File, clip = true),
        entry("file", EntryKind.File, Direction.Received),
        entry("gallery", EntryKind.Gallery),
        entry("note", EntryKind.Text, Direction.Received),
    )

    @Test
    fun filesHoldFilesPhotosAndGalleriesOnly() {
        assertEquals(listOf("photo", "file", "gallery"), fileEntries(entries).map { it.id })
    }

    @Test
    fun theClipboardHoldsEveryTextAndLinkClippedOrNot() {
        assertEquals(listOf("text", "clipped link", "note"), textEntries(entries).map { it.id })
    }

    @Test
    fun lensButtonsFollowWhatTheCameraCanZoom() {
        assertEquals(listOf(0.5f, 1f, 2f), lensStops(0.5f, 8f))
        assertEquals(listOf(0.6f, 1f, 2f), lensStops(0.6f, 8f))
        assertEquals(listOf(1f, 2f), lensStops(1f, 5f))
        assertEquals(listOf(1f), lensStops(1f, 1.5f))
        assertEquals(listOf(1f), lensStops(0.95f, 1.9f))
        assertEquals(listOf(0.94f, 1f), lensStops(0.94f, 1.9f))
    }

    @Test
    fun zoomLabelsShowWholeValuesWithoutADecimal() {
        java.util.Locale.setDefault(java.util.Locale.US)
        assertEquals("1×", zoomLabel(1f))
        assertEquals("0.5×", zoomLabel(0.5f))
        assertEquals("1.4×", zoomLabel(1.4f))
    }
}
