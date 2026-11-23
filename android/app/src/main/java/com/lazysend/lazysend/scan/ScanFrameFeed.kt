package com.lazysend.lazysend.scan

import android.graphics.PixelFormat
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The camera's live frames for the page outline: each RGBA frame of CameraX's ImageAnalysis is made small
 * (`FrameScaler`), searched whole by the corner model (`PageFinder.frameCandidate`) and handed on, all on [executor], so
 * the main thread never waits for a model run. Bind it with `ImageAnalysis.Builder().setOutputImageFormat(OUTPUT_IMAGE_FORMAT_RGBA_8888)`
 * and `setBackpressureStrategy(STRATEGY_KEEP_ONLY_LATEST)`, then `setAnalyzer(feed.executor, feed)`. The analyzer takes one frame at
 * a time, so frames that come while one is being worked on are dropped by CameraX (the latest is kept), and frames that come
 * sooner than the tracker wants one after the last handed over are passed over before any work; the small copy is all that is
 * kept, never the camera's buffer.
 *
 * Coordinates: the frame, and so every outline the tracker gives (`LiveQuadUpdate.outline`, shares 0..1 of the frame), is as
 * the sensor gives it, not turned for the screen; `ImageInfo.rotationDegrees` is the clockwise turn that makes it upright. The model
 * sees the frame turned upright (`PageFinder.frameCandidate`); `OutlineMapping` maps an outline to the view.
 */
class ScanFrameFeed(
    private val model: CornerModel?,
    /** True while the phone is warm, which slows the frames down. */
    private val warm: () -> Boolean = { false },
) : ImageAnalysis.Analyzer {
    val executor: ExecutorService = Executors.newSingleThreadExecutor { task ->
        Thread(task, "scan-frames").apply { isDaemon = true }
    }
    private val lock = Any()
    private var deliver: ((ScanFrame) -> Unit)? = null
    private var lastMs: Double? = null

    /** Counts starts and stops, so a frame that was being worked on before a stop is not handed over after it. */
    private var generation = 0

    fun start(deliver: (ScanFrame) -> Unit) {
        synchronized(lock) {
            this.deliver = deliver
            lastMs = null
            generation++
        }
    }

    fun stop() {
        synchronized(lock) {
            deliver = null
            generation++
        }
    }

    fun close() {
        stop()
        executor.shutdown()
    }

    override fun analyze(image: ImageProxy) {
        try {
            val ms = image.imageInfo.timestamp / 1_000_000.0
            val plane = image.planes.firstOrNull()
            if (image.format != PixelFormat.RGBA_8888 || plane == null || plane.pixelStride != 4 || !due(ms)) return
            val buffer = plane.buffer
            val bytes = ByteArray(buffer.remaining()).also { buffer.get(it) }
            handle(bytes, image.width, image.height, plane.rowStride, image.imageInfo.rotationDegrees, ms)
        } finally {
            image.close()
        }
    }

    /** Whether a frame at [ms] is wanted: a feed that is started, and the tracker's gap since the last one handed over passed. */
    private fun due(ms: Double): Boolean = synchronized(lock) {
        if (deliver == null) return false
        val gap = if (warm()) LiveQuadTracker.WARM_FRAME_GAP_MS else LiveQuadTracker.MIN_FRAME_GAP_MS
        val last = lastMs
        if (last != null && ms >= last && ms - last < gap) return false
        lastMs = ms
        true
    }

    /** A frame's RGBA [bytes] (rows [rowStride] bytes apart, which may be more than the row needs) turned into what the tracker takes. */
    internal fun handle(bytes: ByteArray, width: Int, height: Int, rowStride: Int, rotationDegrees: Int, ms: Double) {
        val started = synchronized(lock) { generation }
        val image = FrameScaler.downscaled(bytes, width, height, rowStride, LiveQuadTracker.ANALYSIS_LONG_SIDE, rgba = true) ?: return
        val page = model?.let { PageFinder.frameCandidate(image, Math.floorMod(rotationDegrees, 360), it) }
        val handler = synchronized(lock) { if (generation == started) deliver else null }
        handler?.invoke(ScanFrame(image, ms, page))
    }
}
