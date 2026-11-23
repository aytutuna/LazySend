package com.lazysend.lazysend.scan

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.util.Log
import java.nio.FloatBuffer

private const val TAG = "CornerModel"

/**
 * DocAligner's FastViT-T8 corner model (DocsaidLab/DocAligner 1.1.1, Apache-2.0) on ONNX Runtime. `model` gives
 * the file's bytes; it is called once, on the first run, so they are not kept after the session has them. The
 * session is made then and kept, all graph optimizations on, two threads; one run at a time.
 */
class OnnxCornerModel(private val model: () -> ByteArray) : CornerModel {
    private val lock = Any()
    private var session: OrtSession? = null

    override fun heatmaps(input: FloatArray): CornerHeatmaps? {
        val side = CornerModelInput.SIDE
        if (input.size != 3 * side * side) return null
        return try {
            synchronized(lock) { run(loaded(), input, side) }
        } catch (e: Exception) {
            Log.e(TAG, "Corner model did not run", e)
            null
        }
    }

    private fun run(session: OrtSession, input: FloatArray, side: Int): CornerHeatmaps? {
        val env = OrtEnvironment.getEnvironment()
        OnnxTensor.createTensor(env, FloatBuffer.wrap(input), longArrayOf(1, 3, side.toLong(), side.toLong())).use { tensor ->
            session.run(mapOf("img" to tensor), setOf("heatmap")).use { result ->
                val heat = result.get("heatmap").get() as OnnxTensor
                val dims = heat.info.shape
                if (dims.size != 4 || dims[1] != 4L) return unreadable(dims)
                val height = dims[2].toInt()
                val width = dims[3].toInt()
                val count = 4 * width * height
                val values = FloatArray(count)
                val buffer = heat.floatBuffer
                if (width <= 0 || height <= 0 || buffer.remaining() < count) return unreadable(dims)
                buffer.get(values)
                return CornerHeatmaps(values, width, height)
            }
        }
    }

    private fun unreadable(dims: LongArray): CornerHeatmaps? {
        Log.e(TAG, "Corner model answered with shape ${dims.joinToString("x")}")
        return null
    }

    private fun loaded(): OrtSession {
        session?.let { return it }
        val options = OrtSession.SessionOptions().apply {
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            setIntraOpNumThreads(2)
        }
        return options.use { OrtEnvironment.getEnvironment().createSession(model(), it) }.also { session = it }
    }
}

object CornerModels {
    private const val ASSET = "fastvit_t8_h_e_bifpn_256_fp32.onnx"

    /** The model in the app's assets (the build puts it there); null if it is not. */
    fun fromAssets(context: Context): OnnxCornerModel? {
        val assets = context.applicationContext.assets
        val present = try {
            assets.open(ASSET).use { true }
        } catch (e: java.io.IOException) {
            Log.e(TAG, "Corner model is not in the app", e)
            false
        }
        return if (present) OnnxCornerModel { assets.open(ASSET).use { it.readBytes() } } else null
    }
}
