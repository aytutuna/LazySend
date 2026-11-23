package com.lazysend.lazysend.scan

import java.io.File
import javax.imageio.ImageIO
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import kotlin.math.hypot

// DocAligner's FastViT-T8 on the SmartDoc frames in Tests/LazySendScanModelTests/Fixtures/Pages: every corner within
// 1.5 % of the photo's diagonal of the ground truth, and the page finder within 4 %. Skipped when
// scripts/fetch_docaligner.sh has not fetched the model, unless LAZYSEND_REQUIRE_CORNER_MODEL=1 (CI fetches it), where
// a missing model fails. Runs on the desktop build of ONNX Runtime (testImplementation).
class OnnxCornerModelTest {
    private val repo = File(System.getProperty("lazysend.repo") ?: "../..")
    private val modelFile = File(repo, "Sources/LazySendScanModel/Models/fastvit_t8_h_e_bifpn_256_fp32.onnx")
    private val pages = File(repo, "Tests/LazySendScanModelTests/Fixtures/Pages")

    private class Photo(val file: String, val image: RgbaImage, val truth: Quad)

    private fun photos(): List<Photo> {
        val entries = Json.parseToJsonElement(File(pages, "corners.json").readText()).jsonArray
        return entries.map { entry ->
            val o = entry.jsonObject
            val file = o["file"]!!.jsonPrimitive.content
            val jpeg = ImageIO.read(File(pages, file))
            val w = jpeg.width
            val h = jpeg.height
            assertEquals(file, o["width"]!!.jsonPrimitive.int, w)
            assertEquals(file, o["height"]!!.jsonPrimitive.int, h)
            val pixels = ByteArray(w * h * 4)
            for (y in 0 until h) {
                for (x in 0 until w) {
                    val c = jpeg.getRGB(x, y)
                    val at = (y * w + x) * 4
                    pixels[at] = (c shr 16).toByte()
                    pixels[at + 1] = (c shr 8).toByte()
                    pixels[at + 2] = c.toByte()
                    pixels[at + 3] = -1
                }
            }
            val corners = listOf("topLeft", "topRight", "bottomRight", "bottomLeft").map {
                val pair = o[it]!!.jsonArray
                Pt(pair[0].jsonPrimitive.double, pair[1].jsonPrimitive.double)
            }
            Photo(file, RgbaImage(w, h, pixels), Quad.fromCorners(corners))
        }
    }

    private fun model(): OnnxCornerModel? {
        // Smart App Control on the dev PC refuses the desktop runtime's DLL; CI and the device test cover it.
        assumeTrue(!System.getProperty("os.name").startsWith("Windows"))
        if (!modelFile.exists()) {
            assertTrue("The corner model is not fetched (scripts/fetch_docaligner.sh)",
                System.getenv("LAZYSEND_REQUIRE_CORNER_MODEL") != "1")
            assumeTrue("The corner model is not fetched (scripts/fetch_docaligner.sh)", false)
        }
        return OnnxCornerModel { modelFile.readBytes() }
    }

    private fun farthest(found: Quad, truth: Quad, diagonal: Double) =
        (0 until 4).maxOf { hypot(found[it].x - truth[it].x, found[it].y - truth[it].y) / diagonal }

    @Test
    fun theModelFindsEveryPageWithinOnePointFivePercentOfTheDiagonal() {
        val model = model()!!
        val all = photos()
        assertEquals(6, all.size)
        for (photo in all) {
            val image = photo.image
            val heat = model.heatmaps(CornerModelInput.make(image))
            assertNotNull("no heatmaps for ${photo.file}", heat)
            val found = CornerHeatmap.decode(heat!!.values, heat.width, heat.height)
            assertNotNull("no page in ${photo.file}", found)
            val w = image.width.toDouble()
            val h = image.height.toDouble()
            val diagonal = hypot(w, h)
            val quad = Quad.fromCorners(found!!.quad.scaled(w, h).corners)
            val errors = (0 until 4).map { hypot(quad[it].x - photo.truth[it].x, quad[it].y - photo.truth[it].y) / diagonal }
            errors.forEachIndexed { corner, error -> assertTrue("${photo.file} corner $corner", error < 0.015) }

            val page = PageFinder.find(image, model)
            val moved = farthest(Quad.fromCorners(page.corners.corners), photo.truth, diagonal)
            assertTrue("the page finder missed the page in ${photo.file}", moved < 0.04)
            println("%s: confidence %.3f, corner errors %s %% of the diagonal; finder %.2f %% %s".format(
                photo.file, found.confidence, errors.joinToString(" ") { "%.2f".format(it * 100) }, moved * 100,
                if (page.clear) "cuts it out" else "asks"))
        }
    }

    @Test
    fun anInputOfTheWrongSizeIsRefused() {
        assertNull(OnnxCornerModel { error("not read") }.heatmaps(floatArrayOf(0f, 0f, 0f)))
    }
}
