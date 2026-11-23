package com.lazysend.lazysend.scan

import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** Where the camera's automatic shutter stands. */
enum class CaptureState {
    /** No page is seen clearly enough. */
    NoPage,

    /** A page is seen but moves. */
    Moving,

    /** The page holds still; the shutter fires when it has for long enough. */
    Steadying,

    /** The page was taken; waiting for it to go or move before the next. */
    Captured,
}

/** Whether a frame is good enough to be taken (`CaptureStability.judge`). */
enum class CaptureQuality {
    /** Sharp and lit, or not measured. */
    Good,

    /** Not sharp enough: the camera moves or has not focused yet. */
    Blurry,

    /** Too dark. */
    Dark,
}

/** Whether the page found fits the frame well (`CaptureStability.placement`). */
enum class CapturePlacement {
    /** Large enough and whole in the frame. */
    Fine,

    /** Covers too little of the frame to be read well. */
    Far,

    /** A corner lies on the frame's edge: part of the page is probably outside. */
    CutOff,
}

/**
 * One video frame's detection: the page found in the frame's pixels (null when none), the detection's
 * confidence 0..1, when the frame was taken in milliseconds on any steady clock, the frame's size (movement
 * is measured against its diagonal) and, when measured (`FrameQuality`), its sharpness and brightness.
 */
data class CaptureObservation(
    val quad: Quad?,
    val confidence: Double,
    val timestampMs: Double,
    val frameWidth: Int,
    val frameHeight: Int,
    val sharpness: Double? = null,
    val brightness: Double? = null,
)

/**
 * What the shutter should do after a frame: the state after it, whether to take the photo now (true on
 * exactly one frame per steady page), how far the page is through the steady time (0..1, for a ring in the
 * view), the frame's quality, and whether a page held still has waited `CaptureStability.SOFT_HINT_MS` for a
 * sharp frame so that tapping the shutter may do better.
 */
data class CaptureDecision(
    val state: CaptureState,
    val shouldCapture: Boolean,
    val progress: Double,
    val quality: CaptureQuality = CaptureQuality.Good,
    val suggestsShutter: Boolean = false,
)

/** The thresholds of `CaptureStability`; the defaults are its constants. */
data class CaptureStabilityOptions(
    /** The page must hold still this long before the shutter fires. */
    val steadyMs: Double = CaptureStability.STEADY_MS,
    /** To start holding still, no corner moved more than this share of the diagonal since the last frame. */
    val enterMovement: Double = CaptureStability.ENTER_MOVEMENT,
    /** While holding still, no corner strays more than this share from where it was when holding started. */
    val stayMovement: Double = CaptureStability.STAY_MOVEMENT,
    val enterConfidence: Double = CaptureStability.ENTER_CONFIDENCE,
    val stayConfidence: Double = CaptureStability.STAY_CONFIDENCE,
    /** A page missing from the frames for up to this long is still the same page. */
    val maxGapMs: Double = CaptureStability.MAX_GAP_MS,
    /** After a capture, the next page counts as new once a corner moved this share of the diagonal from the captured page. */
    val newPageMovement: Double = CaptureStability.NEW_PAGE_MOVEMENT,
    val minSharpness: Double = CaptureStability.MIN_SHARPNESS,
    val minBrightness: Double = CaptureStability.MIN_BRIGHTNESS,
)

/**
 * Decides when the camera may take the page by itself: the page must be seen with confidence for `steadyMs`
 * with its corners holding still. Hysteresis keeps the decision from flickering: holding still starts when
 * no corner moved more than `enterMovement` of the diagonal since the previous frame with confidence at
 * least `enterConfidence`, and lasts while no corner strays more than `stayMovement` from where it was then
 * and the confidence stays at least `stayConfidence`; a page missing for up to `maxGapMs` is waited for,
 * and the time it was missing does not count as holding still. Once taken, the same page is not taken
 * again: the shutter re-arms when frames without a page span more than `maxGapMs`, or a corner moved
 * `newPageMovement` from where it was taken, or on `reset()`. After the camera stopped for a while
 * `resume` takes the time without frames out. A page held still long enough is taken only from a frame that
 * is sharp and lit (`judge`); until one comes, the page stays steadying with its progress full. Corners are
 * compared whichever of them a quad names first (`movement`). Pure logic: the camera feeds it one
 * `CaptureObservation` per analysed frame, in time order.
 */
class CaptureStability(private val options: CaptureStabilityOptions = CaptureStabilityOptions()) {
    private var previous: Quad? = null
    private var anchor: Quad? = null
    private var captured: Quad? = null
    private var steadySince = 0.0
    private var lastSeen = Double.NEGATIVE_INFINITY
    private var lastFrame = Double.NEGATIVE_INFINITY
    private var missing = false
    private var softSince: Double? = null

    /** The state after the last frame. */
    var state: CaptureState = CaptureState.NoPage
        private set

    /** Forget everything (a new document, the user took a photo by hand): the next steady page is taken. */
    fun reset() {
        state = CaptureState.NoPage
        previous = null
        anchor = null
        captured = null
        lastSeen = Double.NEGATIVE_INFINITY
        lastFrame = Double.NEGATIVE_INFINITY
        missing = false
        softSince = null
    }

    /**
     * Frames come again after a pause, the first of them taken at `timestampMs`: the time since the last
     * frame counts neither as time the page was missing nor as time it held still. Nothing changes before
     * any frame, or for a time before the last frame's.
     */
    fun resume(timestampMs: Double) {
        if (lastFrame == Double.NEGATIVE_INFINITY || !(timestampMs > lastFrame)) return
        val paused = timestampMs - lastFrame
        lastFrame = timestampMs
        lastSeen += paused
        steadySince += paused
        softSince = softSince?.plus(paused)
    }

    /** The page in view was taken another way (the shutter pressed by hand). Nothing changes while no page is seen. */
    fun markCaptured() {
        val quad = previous ?: return
        state = CaptureState.Captured
        captured = quad
        anchor = null
    }

    /** The decision after one more frame. */
    fun update(frame: CaptureObservation): CaptureDecision {
        val quality = judge(frame.sharpness, frame.brightness, options)
        lastFrame = frame.timestampMs
        return decide(frame, quality).copy(quality = quality)
    }

    private fun decide(frame: CaptureObservation, quality: CaptureQuality): CaptureDecision {
        val o = options
        val fw = frame.frameWidth.toDouble()
        val fh = frame.frameHeight.toDouble()
        val diagonal = sqrt(fw * fw + fh * fh)
        val t = frame.timestampMs
        // Only a held, blurred page keeps the time; a short gap in the frames does not break it.
        val blurredSince = softSince
        softSince = null

        val quad = frame.quad
        if (quad == null) {
            if (t - lastSeen <= o.maxGapMs) {
                softSince = blurredSince
                // Waiting for the page to come back; the steady time stands still meanwhile.
                missing = true
                return CaptureDecision(state, false, if (state == CaptureState.Steadying) progress(lastSeen) else 0.0)
            }
            previous = null
            anchor = null
            captured = null
            missing = false
            state = CaptureState.NoPage
            return CaptureDecision(state, false, 0.0)
        }

        val returning = t - lastSeen > o.maxGapMs
        // Back after frames without it: the time it was missing is not time held still.
        if (missing && !returning) steadySince += t - lastSeen
        missing = false
        lastSeen = t
        val last = previous
        previous = quad

        if (state == CaptureState.Captured) {
            // The page taken stays taken, however long since the last frame, until it moves away.
            val taken = captured
            if (taken != null && movement(quad, taken) < o.newPageMovement * diagonal) {
                return CaptureDecision(state, false, 1.0)
            }
            captured = null
            state = CaptureState.Moving
        }
        if (returning) {
            anchor = null
            state = if (frame.confidence >= o.stayConfidence) CaptureState.Moving else CaptureState.NoPage
            return CaptureDecision(state, false, 0.0)
        }

        val held = anchor
        if (state == CaptureState.Steadying && held != null) {
            val stays = frame.confidence >= o.stayConfidence && movement(quad, held) <= o.stayMovement * diagonal
            if (stays) {
                if (t - steadySince >= o.steadyMs) {
                    // Held still long enough: taken from the first frame that is sharp and lit.
                    if (quality != CaptureQuality.Good) {
                        var suggests = false
                        if (quality == CaptureQuality.Blurry) {
                            val since = blurredSince ?: t
                            softSince = since
                            suggests = t - since >= SOFT_HINT_MS
                        }
                        return CaptureDecision(state, false, 1.0, suggestsShutter = suggests)
                    }
                    state = CaptureState.Captured
                    captured = quad
                    anchor = null
                    return CaptureDecision(state, true, 1.0)
                }
                return CaptureDecision(state, false, progress(t))
            }
            anchor = null
            state = if (frame.confidence >= o.stayConfidence) CaptureState.Moving else CaptureState.NoPage
            return CaptureDecision(state, false, 0.0)
        }

        if (frame.confidence < o.enterConfidence) {
            state = if (frame.confidence >= o.stayConfidence) CaptureState.Moving else CaptureState.NoPage
            return CaptureDecision(state, false, 0.0)
        }
        if (last != null && movement(quad, last) <= o.enterMovement * diagonal) {
            state = CaptureState.Steadying
            anchor = last
            steadySince = t
            return CaptureDecision(state, false, 0.0)
        }
        state = CaptureState.Moving
        return CaptureDecision(state, false, 0.0)
    }

    private fun progress(t: Double): Double = min(max((t - steadySince) / options.steadyMs, 0.0), 1.0)

    companion object {
        const val STEADY_MS = 600.0
        const val ENTER_MOVEMENT = 0.01
        const val STAY_MOVEMENT = 0.025
        const val ENTER_CONFIDENCE = 0.6
        const val STAY_CONFIDENCE = 0.45
        const val MAX_GAP_MS = 250.0
        const val NEW_PAGE_MOVEMENT = 0.15

        /** The least sharpness a frame is taken at: the variance of its luma's 4-neighbour Laplacian (`FrameQuality`). */
        const val MIN_SHARPNESS = 40.0

        /** The least brightness a frame is taken at: its mean luma, 0..255 (`FrameQuality`). */
        const val MIN_BRIGHTNESS = 50.0

        /** A page covering less than this share of the frame's area is too far away. */
        const val MIN_AREA_SHARE = 0.2

        /** A corner closer than this share of the frame's diagonal to the frame's edge counts as on it. */
        const val EDGE_MARGIN = 0.01

        /** A page held still and blurred for this long suggests tapping the shutter. */
        const val SOFT_HINT_MS = 2000.0

        /** The automatic shutter takes no photo for this long after the camera goes live. */
        const val AUTO_GRACE_MS = 1500.0

        /** `Dark` below `minBrightness`, else `Blurry` below `minSharpness`, else (and when not measured) `Good`. */
        fun judge(sharpness: Double?, brightness: Double?,
                  options: CaptureStabilityOptions = CaptureStabilityOptions()): CaptureQuality {
            if (brightness != null && brightness < options.minBrightness) return CaptureQuality.Dark
            if (sharpness != null && sharpness < options.minSharpness) return CaptureQuality.Blurry
            return CaptureQuality.Good
        }

        /**
         * How `quad` sits in a frame of this size: `CutOff` when a corner is within `EDGE_MARGIN` of the
         * diagonal from the frame's edge, else `Far` below `MIN_AREA_SHARE` of the frame's area, else `Fine`.
         */
        fun placement(quad: Quad, frameWidth: Int, frameHeight: Int): CapturePlacement {
            val w = frameWidth.toDouble()
            val h = frameHeight.toDouble()
            val margin = EDGE_MARGIN * sqrt(w * w + h * h)
            if (!quad.isInside(w, h, margin)) return CapturePlacement.CutOff
            if (quad.area < MIN_AREA_SHARE * w * h) return CapturePlacement.Far
            return CapturePlacement.Fine
        }

        /**
         * How far the page moved from `b` to `a`: the largest distance between their corners, paired from
         * whichever corner of `b` fits best (the least over the four ways round).
         */
        fun movement(a: Quad, b: Quad): Double {
            var best = Double.MAX_VALUE
            for (shift in 0 until 4) {
                var worst = 0.0
                for (i in 0 until 4) worst = max(worst, Quad.distance(a[i], b[i + shift]))
                best = min(best, worst)
            }
            return best
        }
    }
}
