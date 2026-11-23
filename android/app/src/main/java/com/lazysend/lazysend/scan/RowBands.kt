package com.lazysend.lazysend.scan

import java.util.stream.IntStream
import kotlin.math.min

/** Calls `body(start, end)` with disjoint row ranges covering 0 until rows, on all cores; `body` may only write its own rows. */
internal fun forRowBands(rows: Int, body: (start: Int, end: Int) -> Unit) {
    val bands = min(rows, Runtime.getRuntime().availableProcessors() * 4)
    if (bands <= 1) {
        body(0, rows)
        return
    }
    val size = (rows + bands - 1) / bands
    IntStream.range(0, bands).parallel().forEach { band ->
        val start = band * size
        val end = min(rows, start + size)
        if (start < end) body(start, end)
    }
}
