package com.lazysend.lazysend.scan

import kotlin.math.max
import kotlin.math.min

/** How the preview's picture sits in its view: `FILL_CENTER` covers the view and crops, `FIT_CENTER` shows the whole picture. */
enum class PreviewScale { Fill, Fit }

object OutlineMapping {
    /**
     * The corners of [outline] (shares of the analysis frame as the sensor gives it, `frameWidth` x `frameHeight` before any turn)
     * in the pixels of a view [viewWidth] x [viewHeight] showing the preview. [rotationDegrees] is the frame's
     * `ImageInfo.rotationDegrees`: the clockwise turn that makes it upright, which is how the preview is shown. The preview
     * and the analysis must see the same part of the scene (the same aspect ratio, or one `ViewPort`); the frame's size is
     * only used for its shape. The corners come in the outline's order.
     */
    fun toView(
        outline: Quad,
        rotationDegrees: Int,
        frameWidth: Int,
        frameHeight: Int,
        viewWidth: Double,
        viewHeight: Double,
        scale: PreviewScale,
    ): List<Pt> {
        val quarters = Math.floorMod(rotationDegrees, 360) / 90
        val sideways = quarters % 2 == 1
        val width = (if (sideways) frameHeight else frameWidth).toDouble()
        val height = (if (sideways) frameWidth else frameHeight).toDouble()
        val across = viewWidth / width
        val down = viewHeight / height
        val factor = if (scale == PreviewScale.Fill) max(across, down) else min(across, down)
        val left = (viewWidth - width * factor) / 2
        val top = (viewHeight - height * factor) / 2
        return outline.corners.map { corner ->
            // The same turn as `LiveQuadTracker.photoOutline`, point by point.
            val x: Double
            val y: Double
            when (quarters) {
                1 -> { x = 1.0 - corner.y; y = corner.x }
                2 -> { x = 1.0 - corner.x; y = 1.0 - corner.y }
                3 -> { x = corner.y; y = 1.0 - corner.x }
                else -> { x = corner.x; y = corner.y }
            }
            Pt(left + x * width * factor, top + y * height * factor)
        }
    }
}
