package com.lazysend.lazysend.ui

import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/** The lens buttons to show: the camera's own widest zoom when it zooms out past 1x, 1x, and 2x only when it zooms in that far. */
fun lensStops(min: Float, max: Float): List<Float> = buildList {
    if (min < 0.95f) add(min)
    add(1f)
    if (max >= 2f) add(2f)
}

fun zoomLabel(ratio: Float): String =
    if (abs(ratio - ratio.roundToInt()) < 0.05f) "${ratio.roundToInt()}×" else String.format(Locale.getDefault(), "%.1f×", ratio)
