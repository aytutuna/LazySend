package com.lazysend.lazysend.ui

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import java.util.Locale
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.log2
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/** How far a finger travels on the zoom wheel for the zoom to double. */
const val POINTS_PER_DOUBLING = 90f

/**
 * The lens buttons to show: the camera's own widest zoom when it zooms out past 1x, 1x, 2x when it zooms in that far, and the
 * telephoto lens's ratio where the phone has one.
 */
fun lensStops(min: Float, max: Float, telephoto: Float? = null): List<Float> = buildList {
    if (min < 0.95f) add(min)
    add(1f)
    if (max >= 2f) add(2f)
    if (telephoto != null && telephoto <= max && abs(telephoto - 2f) > 0.05f) add(telephoto)
}

/** The longest of the physical lenses as a multiple of the main one, to the nearest half; nil when none is clearly longer. */
fun telephotoRatio(main: Float, physical: List<Float>): Float? {
    val ratio = (physical.maxOrNull() ?: return null) / main
    return if (ratio < 1.5f) null else (ratio * 2).roundToInt() / 2f
}

private fun equivalentFocal(c: CameraCharacteristics): Float? {
    val focal = c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.firstOrNull() ?: return null
    val size = c.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE) ?: return null
    return focal * 43.27f / hypot(size.width, size.height)
}

/** The telephoto lens's zoom ratio on a phone whose back camera is several lenses behind one logical camera. */
@androidx.annotation.OptIn(ExperimentalCamera2Interop::class)
fun telephotoOf(context: Context, camera: Camera): Float? {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return null
    return try {
        val manager = context.getSystemService(CameraManager::class.java)
        val logical = manager.getCameraCharacteristics(Camera2CameraInfo.from(camera.cameraInfo).cameraId)
        val main = equivalentFocal(logical) ?: return null
        telephotoRatio(main, logical.physicalCameraIds.mapNotNull { equivalentFocal(manager.getCameraCharacteristics(it)) })
    } catch (e: Exception) {
        null
    }
}

/** The wheel goes from the widest lens to the camera's top, at most 10x and at most five times the longest lens. */
fun dialRange(stops: List<Float>, top: Float): ClosedFloatingPointRange<Float> {
    val low = stops.first()
    return low..max(low, min(top, min(10f, stops.last() * 5)))
}

/** The zoom a finger that moved [dragged] pixels to the right of where it began gives; moving left zooms in. */
fun zoomAfterDrag(start: Float, dragged: Float, pxPerDoubling: Float, range: ClosedFloatingPointRange<Float>): Float =
    (start * 2f.pow(-dragged / pxPerDoubling)).coerceIn(range)

/** Where [zoom] sits to the right of [current] on the wheel. */
fun wheelOffset(zoom: Float, current: Float, pxPerDoubling: Float): Float = log2(zoom / current) * pxPerDoubling

fun crossesStop(old: Float, new: Float, stops: List<Float>): Boolean =
    stops.any { (old < it && new >= it) || (old > it && new <= it) }

fun stepStop(zoom: Float, stops: List<Float>, up: Boolean): Float? =
    if (up) stops.firstOrNull { it > zoom + 0.01f } else stops.lastOrNull { it < zoom - 0.01f }

/** The marks on the wheel: every 0.1 up to 2, every 0.5 up to 5, then whole numbers, and each stop. */
fun wheelTicks(range: ClosedFloatingPointRange<Float>, stops: List<Float>): List<Float> {
    val marks = stops.toMutableList()
    var value = kotlin.math.ceil(range.start * 10) / 10
    while (value <= range.endInclusive + 0.001f) {
        marks.add(value)
        value = ((value + if (value < 2f) 0.1f else if (value < 5f) 0.5f else 1f) * 1000).roundToInt() / 1000f
    }
    return marks.filter { it in range }.distinctBy { (it * 100).roundToInt() }.sorted()
}

fun zoomLabel(ratio: Float): String =
    if (abs(ratio - ratio.roundToInt()) < 0.05f) "${ratio.roundToInt()}×" else String.format(Locale.getDefault(), "%.1f×", ratio)

/** A button that is not the active one: ".5", "2". */
fun stopLabel(value: Float): String {
    if (abs(value - value.roundToInt()) < 0.05f) return value.roundToInt().toString()
    val text = String.format(Locale.getDefault(), "%.1f", value)
    return if (value < 1f && text.startsWith("0")) text.drop(1) else text
}
