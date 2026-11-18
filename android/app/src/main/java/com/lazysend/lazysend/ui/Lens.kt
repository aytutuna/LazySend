package com.lazysend.lazysend.ui

import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/** The lens buttons to show: 0.5x only when the camera zooms out that far, 2x only when it zooms in that far. */
fun lensStops(min: Float, max: Float): List<Float> = buildList {
    if (min <= 0.6f) add(0.5f)
    add(1f)
    if (max >= 2f) add(2f)
}

fun zoomLabel(ratio: Float): String =
    if (abs(ratio - ratio.roundToInt()) < 0.05f) "${ratio.roundToInt()}×" else String.format(Locale.getDefault(), "%.1f×", ratio)
