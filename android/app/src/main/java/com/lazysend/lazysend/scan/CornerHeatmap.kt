package com.lazysend.lazysend.scan

import kotlin.math.max
import kotlin.math.min

/**
 * The page's corners from the heatmaps of DocAligner's corner models: four channels of `width` x `height`
 * values from 0 to 1, one per corner, top left, top right, bottom right and bottom left. In each channel
 * the values from `THRESHOLD` up are the corner's; of their 8-connected blobs the largest (most values) is
 * taken, and the corner is its centre weighted by the heat, as shares of the image (x right, y down; value
 * (x, y) stands for the point ((x + 0.5) / width, (y + 0.5) / height)). The confidence is the lowest of the
 * four channels' peaks. Null when a channel has no value from `THRESHOLD` up, or the four corners are not
 * a convex outline in their order.
 */
object CornerHeatmap {
    const val THRESHOLD = 0.3f

    private class Found(val point: Pt, val peak: Double)

    fun decode(heat: FloatArray, width: Int, height: Int): QuadCandidate? {
        if (width <= 0 || height <= 0) return null
        val plane = width * height
        if (heat.size < plane * 4) return null
        val visited = BooleanArray(plane)
        val stack = IntArray(plane)
        val corners = ArrayList<Pt>(4)
        var confidence = 1.0
        for (channel in 0 until 4) {
            val found = corner(heat, channel * plane, width, height, visited, stack) ?: return null
            corners.add(found.point)
            confidence = min(confidence, found.peak)
        }
        val quad = Quad(corners[0], corners[1], corners[2], corners[3])
        if (!quad.isConvex) return null
        return QuadCandidate(quad, confidence)
    }

    /** The heat-weighted centre of the largest blob in the channel starting at `base`, and the channel's peak. */
    private fun corner(heat: FloatArray, base: Int, width: Int, height: Int, visited: BooleanArray,
                       stack: IntArray): Found? {
        val plane = width * height
        visited.fill(false, 0, plane)
        var peak = 0f
        var bestCount = 0
        var bestX = 0.0
        var bestY = 0.0
        for (start in 0 until plane) {
            val value = heat[base + start]
            peak = max(peak, value)
            if (value >= THRESHOLD && !visited[start]) {
                visited[start] = true
                var top = 0
                stack[top++] = start
                var count = 0
                var sum = 0.0
                var sumX = 0.0
                var sumY = 0.0
                while (top > 0) {
                    val at = stack[--top]
                    val x = at % width
                    val y = at / width
                    val weight = heat[base + at].toDouble()
                    count++
                    sum += weight
                    sumX += weight * (x.toDouble() + 0.5)
                    sumY += weight * (y.toDouble() + 0.5)
                    for (ny in max(y - 1, 0)..min(y + 1, height - 1)) {
                        for (nx in max(x - 1, 0)..min(x + 1, width - 1)) {
                            val next = ny * width + nx
                            if (!visited[next] && heat[base + next] >= THRESHOLD) {
                                visited[next] = true
                                stack[top++] = next
                            }
                        }
                    }
                }
                if (count > bestCount) {
                    bestCount = count
                    bestX = sumX / sum
                    bestY = sumY / sum
                }
            }
        }
        if (bestCount == 0) return null
        return Found(Pt(bestX / width.toDouble(), bestY / height.toDouble()), peak.toDouble())
    }
}
