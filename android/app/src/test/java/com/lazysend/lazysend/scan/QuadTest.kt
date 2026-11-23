package com.lazysend.lazysend.scan

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

class QuadTest {
    @Test
    fun roundTripsThroughJson() {
        val quad = Quad(Pt(1.5, 2.0), Pt(10.0, 2.5), Pt(11.0, 20.25), Pt(0.5, 19.0))
        assertEquals(quad, Json.decodeFromString<Quad>(Json.encodeToString(quad)))
    }
}
