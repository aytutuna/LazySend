package com.lazysend.lazysend.scan

import kotlin.math.max
import kotlin.math.sqrt

/**
 * Steadies the page found in successive live frames (pixels of one frame size) before it is drawn and
 * judged. A corner that moved at most `JITTER_SHARE` of the frame's diagonal since the outline before is
 * moved only `SMOOTHING` of the way (the outline stops trembling); one that moved further is followed at
 * once. A page that jumped more than `JUMP_SHARE` (a corner of it) is not believed on one frame: it is
 * passed over unless the next frame finds it away from the outline too, there or further on, when it is the
 * page from then on; while it keeps jumping, each frame is followed. A page seen for the first time is not
 * drawn until it is found again on the next frame; a page drawn and then missed keeps its outline for
 * `LiveQuadTracker.HOLD_MS` after it was last found. Corners are paired with the outline before whichever
 * corner the search named first. Pure logic, one frame after another in time order.
 */
class LiveQuadFilter {
    /**
     * What one frame gives: the steadied page for the shutter's judgement (null when none was found, or a
     * jump was passed over), and the outline to draw (null when there is none to draw).
     */
    data class Output(val page: Quad?, val shown: Quad?)

    private var current: Quad? = null
    private var drawn = false
    private var jumped: Quad? = null
    private var seenMs = Double.NEGATIVE_INFINITY

    /** The frame taken at `t` ms, where the page search found `found` (null: no page), in a frame whose diagonal is `diagonal` px. */
    fun update(found: Quad?, t: Double, diagonal: Double): Output {
        if (current != null && (t - seenMs > LiveQuadTracker.HOLD_MS || t < seenMs)) {
            current = null
            drawn = false
            jumped = null
        }
        if (found == null) {
            jumped = null
            if (!drawn) current = null
            return Output(null, if (drawn) current else null)
        }
        val before = current
        if (before == null) {
            current = found
            seenMs = t
            return Output(found, null)
        }
        val aligned = aligned(found, before)
        val limit = JUMP_SHARE * diagonal
        if (aligned.maxCornerDistance(before) > limit) {
            if (!drawn) {
                current = found
                seenMs = t
                return Output(found, null)
            }
            if (jumped != null) {
                current = found
                jumped = found
                seenMs = t
                return Output(found, found)
            }
            jumped = found
            return Output(null, before)
        }
        val steadied = blended(before, aligned, JITTER_SHARE * diagonal)
        current = steadied
        drawn = true
        jumped = null
        seenMs = t
        return Output(steadied, steadied)
    }

    companion object {
        /** How far a trembling corner moves toward where it was found. */
        const val SMOOTHING = 0.5

        /** A corner moving at most this share of the diagonal trembles; further, it moves. */
        const val JITTER_SHARE = 0.01

        /** A page whose corner jumped more than this share of the diagonal is believed on its second sighting. */
        const val JUMP_SHARE = 0.06

        /** `quad`'s corners renamed to pair with `reference`'s: shifted round by whichever of the four ways brings the farthest pair nearest. */
        internal fun aligned(quad: Quad, reference: Quad): Quad {
            var bestShift = 0
            var best = Double.MAX_VALUE
            for (shift in 0 until 4) {
                var worst = 0.0
                for (index in 0 until 4) {
                    val a = quad[index + shift]
                    val b = reference[index]
                    val dx = a.x - b.x
                    val dy = a.y - b.y
                    worst = max(worst, sqrt(dx * dx + dy * dy))
                }
                if (worst < best) {
                    best = worst
                    bestShift = shift
                }
            }
            return Quad(quad[bestShift], quad[bestShift + 1], quad[bestShift + 2], quad[bestShift + 3])
        }

        /** Each corner of `before` moved `SMOOTHING` of the way to `found`'s when within `jitter` px of it, else all the way. */
        internal fun blended(before: Quad, found: Quad, jitter: Double): Quad {
            val corners = ArrayList<Pt>(4)
            for (index in 0 until 4) {
                val a = before[index]
                val b = found[index]
                val dx = b.x - a.x
                val dy = b.y - a.y
                if (sqrt(dx * dx + dy * dy) <= jitter) {
                    corners.add(Pt(a.x + SMOOTHING * dx, a.y + SMOOTHING * dy))
                } else {
                    corners.add(b)
                }
            }
            return Quad(corners[0], corners[1], corners[2], corners[3])
        }
    }
}
