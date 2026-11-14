package com.lazysend.lazysend.data

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TimelineTest {
    @Test
    fun anEntryWrittenBeforeSendIdsLoadsWithoutOne() {
        val file = File.createTempFile("timeline", ".json")
        file.writeText("""[{"id":"a","time":1,"direction":"Sent","kind":"File","pcName":"PC","title":"a.bin","state":"Done"}]""")

        val entry = Timeline(file).entries.value.single()

        assertEquals("a.bin", entry.title)
        assertNull(entry.sendId)
        file.delete()
    }

    @Test
    fun aSendIdSurvivesASave() {
        val file = File.createTempFile("timeline", ".json")
        val timeline = Timeline(file)
        timeline.add(TimelineEntry("a", 1, Direction.Sent, EntryKind.Text, "PC", "hi", sendId = "AbCdEfGhIjKlMnOpQrStUv"))

        assertEquals("AbCdEfGhIjKlMnOpQrStUv", Timeline(file).get("a")!!.sendId)
        file.delete()
    }
}
