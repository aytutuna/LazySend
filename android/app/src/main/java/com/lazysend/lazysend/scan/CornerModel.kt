package com.lazysend.lazysend.scan

/**
 * The heatmaps a corner model gives (`CornerHeatmap` reads them): four channels of `width` x `height`
 * values from 0 to 1, top left, top right, bottom right and bottom left, one channel after another, each
 * row after row.
 */
class CornerHeatmaps(val values: FloatArray, val width: Int, val height: Int)

/** An outline a finder proposed, with how sure it is (0 to 1). */
data class QuadCandidate(val quad: Quad, val confidence: Double)

/** A model that finds a page's corners in a photo; tests give it fakes. */
fun interface CornerModel {
    /** The heatmaps for `input` (`CornerModelInput.make`); null when the model cannot run. */
    fun heatmaps(input: FloatArray): CornerHeatmaps?
}
