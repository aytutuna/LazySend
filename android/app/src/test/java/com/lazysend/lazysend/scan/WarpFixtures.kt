package com.lazysend.lazysend.scan

import org.junit.Assert.assertEquals
import kotlin.math.cos
import kotlin.math.log10
import kotlin.math.sin

object WarpFixtures {
    /** The golden fixture: a w x h photo whose every byte comes from integer arithmetic on (x, y). */
    fun photo(w: Int, h: Int): RgbaImage {
        val p = ByteArray(w * h * 4)
        for (y in 0 until h) {
            for (x in 0 until w) {
                val i = (y * w + x) * 4
                p[i] = ((x * 37 + y * 11) % 256).toByte()
                val checker = (x / 4 + y / 4) % 2 == 0
                p[i + 1] = (if (checker) 40 + (x * 3) % 160 else 220 - (y * 5) % 120).toByte()
                p[i + 2] = ((x * y + 3 * x + 7 * y) % 256).toByte()
                p[i + 3] = -1
            }
        }
        return RgbaImage(w, h, p)
    }

    /** A quad from its corners clockwise from the top-left. */
    fun quad(x0: Double, y0: Double, x1: Double, y1: Double, x2: Double, y2: Double, x3: Double, y3: Double) =
        Quad(Pt(x0, y0), Pt(x1, y1), Pt(x2, y2), Pt(x3, y3))

    /** The peak signal-to-noise ratio of R, G and B in dB, leaving out `border` px all around. */
    fun psnr(a: RgbaImage, b: RgbaImage, border: Int): Double {
        assertEquals(a.width, b.width)
        assertEquals(a.height, b.height)
        var sum = 0.0
        var count = 0
        for (y in border until a.height - border) {
            for (x in border until a.width - border) {
                val i = (y * a.width + x) * 4
                for (c in 0 until 3) {
                    val d = (a.pixels[i + c].toInt() and 0xFF) - (b.pixels[i + c].toInt() and 0xFF)
                    sum += d.toDouble() * d
                }
                count += 3
            }
        }
        val mse = sum / count
        return if (mse == 0.0) 99.0 else 10 * log10(255.0 * 255.0 / mse)
    }

    /** The corners of a w x h rectangle seen by a pinhole camera (focal f, centered on a cw x ch photo). */
    fun cameraView(w: Double, h: Double, tiltX: Double, tiltY: Double, turn: Double, distance: Double,
                   f: Double, cw: Double, ch: Double): Quad {
        val ax = tiltX * Math.PI / 180
        val ay = tiltY * Math.PI / 180
        val az = turn * Math.PI / 180
        val corners = ArrayList<Pt>()
        for ((u, v) in listOf(-w / 2 to -h / 2, w / 2 to -h / 2, w / 2 to h / 2, -w / 2 to h / 2)) {
            // Turn in the plane, tilt about x, then about y, then push away from the camera.
            val x = u * cos(az) - v * sin(az)
            val y = u * sin(az) + v * cos(az)
            val z = 0.0
            val y1 = y * cos(ax) - z * sin(ax)
            val z1 = y * sin(ax) + z * cos(ax)
            val x2 = x * cos(ay) + z1 * sin(ay)
            var z2 = -x * sin(ay) + z1 * cos(ay)
            z2 += distance
            corners.add(Pt(cw / 2 + f * x2 / z2, ch / 2 + f * y1 / z2))
        }
        return Quad.fromCorners(corners)
    }
}
