package com.lazysend.lazysend.scan

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.hypot

// The same check as OnnxCornerModelTest, on a device with the Android build of ONNX Runtime and the model as the app
// carries it in its assets; the page photos are the test assets.
@RunWith(AndroidJUnit4::class)
class CornerModelDeviceTest {
    @Test
    fun theModelInTheAppFindsEveryPageWithinOnePointFivePercentOfTheDiagonal() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val model = CornerModels.fromAssets(instrumentation.targetContext)
        assertNotNull("The corner model is not in the app", model)
        val assets = instrumentation.context.assets
        val entries = Json.parseToJsonElement(assets.open("corners.json").use { it.readBytes().decodeToString() }).jsonArray
        for (entry in entries) {
            val o = entry.jsonObject
            val file = o["file"]!!.jsonPrimitive.content
            val image = PhotoReader.decode(assets.open(file).use { it.readBytes() })!!
            val truth = Quad.fromCorners(listOf("topLeft", "topRight", "bottomRight", "bottomLeft").map {
                val pair = o[it]!!.jsonArray
                Pt(pair[0].jsonPrimitive.double, pair[1].jsonPrimitive.double)
            })
            val heat = model!!.heatmaps(CornerModelInput.make(image))
            assertNotNull("no heatmaps for $file", heat)
            val found = CornerHeatmap.decode(heat!!.values, heat.width, heat.height)
            assertNotNull("no page in $file", found)
            val w = image.width.toDouble()
            val h = image.height.toDouble()
            val diagonal = hypot(w, h)
            val quad = Quad.fromCorners(found!!.quad.scaled(w, h).corners)
            val errors = (0 until 4).map { hypot(quad[it].x - truth[it].x, quad[it].y - truth[it].y) / diagonal }
            errors.forEachIndexed { corner, error -> assertTrue("$file corner $corner", error < 0.015) }

            val page = Quad.fromCorners(PageFinder.find(image, model).corners.corners)
            val moved = (0 until 4).maxOf { hypot(page[it].x - truth[it].x, page[it].y - truth[it].y) / diagonal }
            assertTrue("the page finder missed the page in $file", moved < 0.04)
            println("CORNERS %s: confidence %.3f, errors %s %%; finder %.2f %%".format(
                file, found.confidence, errors.joinToString(" ") { "%.2f".format(it * 100) }, moved * 100))
        }
    }
}
