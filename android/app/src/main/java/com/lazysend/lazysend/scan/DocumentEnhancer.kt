package com.lazysend.lazysend.scan

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/** How a page taken by a camera is cleaned up (`DocumentEnhancer`). */
@Serializable
enum class DocumentEnhanceMode {
    /** As `Color`, then gray when the page has no color left. */
    @SerialName("auto") Auto,

    /** The lighting evened out, the paper made white, a slight tint taken out, the print stretched to black, in color. */
    @SerialName("color") Color,

    /** As `Color`, in gray. */
    @SerialName("gray") Gray,

    /** The gray page thresholded: black print on white paper, every pixel 0 or 255. */
    @SerialName("blackAndWhite") BlackAndWhite,

    /** A photo: its levels stretched as a whole, nothing evened out. */
    @SerialName("photo") Photo,

    /** As `Color`, with the print left as dark as it is and its colors made stronger: a board of marker. */
    @SerialName("whiteboard") Whiteboard,
}

/** The look of a page, chosen page by page; stored by its serial name, the first case is the default. */
@Serializable
enum class CaptureFilter {
    @SerialName("enhanced") Enhanced,
    @SerialName("original") Original,
    @SerialName("grayscale") Grayscale,
    @SerialName("blackAndWhite") BlackAndWhite,
    @SerialName("whiteboard") Whiteboard;

    /** The clean-up this filter runs; null for `Original`. */
    val mode: DocumentEnhanceMode?
        get() = when (this) {
            Enhanced -> DocumentEnhanceMode.Auto
            Original -> null
            Grayscale -> DocumentEnhanceMode.Gray
            BlackAndWhite -> DocumentEnhanceMode.BlackAndWhite
            Whiteboard -> DocumentEnhanceMode.Whiteboard
        }

    companion object {
        /** The order the filters are offered in. */
        val displayOrder: List<CaptureFilter> = listOf(Original, Enhanced, Whiteboard, Grayscale, BlackAndWhite)

        /** The filter of a page cleaned up in `mode` as asked for; null for a photo, which has none. */
        fun fromMode(mode: DocumentEnhanceMode): CaptureFilter? = when (mode) {
            DocumentEnhanceMode.Auto, DocumentEnhanceMode.Color -> Enhanced
            DocumentEnhanceMode.Gray -> Grayscale
            DocumentEnhanceMode.BlackAndWhite -> BlackAndWhite
            DocumentEnhanceMode.Whiteboard -> Whiteboard
            DocumentEnhanceMode.Photo -> null
        }
    }
}

/** A page cleaned up: its pixels and the mode applied (`Auto` resolved to color or gray). */
data class DocumentEnhancement(val image: RgbaImage, val mode: DocumentEnhanceMode)

/** The paper's color as gains per channel: a channel times its gain is the paper's luma. */
data class PaperWhiteBalance(val r: Double, val g: Double, val b: Double) {
    companion object {
        val NEUTRAL = PaperWhiteBalance(1.0, 1.0, 1.0)
    }
}

/**
 * Cleans up a page taken by a camera, after it was cut out of its photo: the lighting evened out, so a
 * shadow across the sheet or a lamp's falloff leaves the paper one white, a slight tint of the paper taken
 * out, and the print stretched to black. The paper's brightness is estimated in tiles (`BackgroundMap`)
 * and every pixel is divided by the paper there, as a level of `LEVELS`; the levels are then stretched
 * linearly from the black point to `WHITE_POINT`. Black and white makes a pixel black when its level is
 * below the share of the paper that `blackShare` gives, so the threshold follows the lighting. A photo is
 * only stretched as a whole. A page with a dark ground and light print on it (`isLightOnDark`) has no paper
 * to even out against, so it is stretched as a whole like a photo and then made gray or black and white as
 * the mode says. A whiteboard is evened out in color but not stretched to a black point, so a marker keeps
 * its own darkness, and each channel is pushed away from the pixel's luma by `WHITEBOARD_SATURATION`. The
 * samples (white balance, black point, light on dark) are every `SAMPLE_STEP`-th pixel of every
 * `SAMPLE_STEP`-th row.
 */
object DocumentEnhancer {
    /** The paper is estimated in tiles of about the long side over this. */
    const val TILES_ALONG_LONG_SIDE = 16

    /** The smallest tile, in pixels. */
    const val MIN_TILE_SIZE = 8

    /** A tile's paper is this percentile of its luma (the paper between the print). */
    const val BACKGROUND_PERCENTILE = 0.9

    /** A tile darker than this share of its brightest neighbor is no paper and is filled from it. */
    const val DARK_TILE_SHARE = 0.7

    /** Every tile is at least this share of the median tile... */
    const val MIN_BACKGROUND_SHARE = 0.4

    /** ...and at least this luma, so a dark area is not blown up. */
    const val MIN_BACKGROUND = 32

    /** A pixel at least this share of the paper there counts as paper for the white balance. */
    const val PAPER_SHARE = 0.9

    /** The white balance's gains are kept within MIN_GAIN..MAX_GAIN. */
    const val MIN_GAIN = 0.87
    const val MAX_GAIN = 1.15

    /** Levels at or above this share of the paper become white. */
    const val WHITE_POINT = 0.9

    /** The share of the sampled levels taken as the darkest print. */
    const val BLACK_PERCENTILE = 0.005

    /** Black and white makes a pixel black when it is darker than this share of the paper there. */
    const val BILEVEL_SHARE = 0.78

    /** The black and white threshold setting that gives exactly `BILEVEL_SHARE`. */
    const val DEFAULT_THRESHOLD = 0.5

    /** The black point is at most this level, so a page with little print is not stretched into noise. */
    const val MAX_BLACK_POINT = 0.5

    /** The steps a level is counted in. */
    const val LEVELS = 1024

    /** The samples are every SAMPLE_STEP-th pixel of every SAMPLE_STEP-th row. */
    const val SAMPLE_STEP = 2

    /** A photo's levels are stretched from this share of its pixels at the dark end to as many at the bright end... */
    const val PHOTO_CLIP = 0.005

    /** ...when those two lumas are at least this far apart; a flatter photo is left as it is. */
    const val MIN_PHOTO_RANGE = 64

    /** A photo's stretch gains at most this much: a narrower range is widened to it (see `photoRange`). */
    const val MAX_PHOTO_GAIN = 1.3

    /** The ground of a page, to tell light print on a dark ground, is this percentile of each tile's luma. */
    const val GROUND_PERCENTILE = 0.5

    /** A pixel this many times as bright as the ground there is light print; this many times darker, dark print. */
    const val LIGHT_CONTRAST = 1.5

    /** A page is light on dark only with at least this share of the samples light print. */
    const val MIN_LIGHT_SHARE = 0.005

    /** A whiteboard's channels are moved this many times as far from the pixel's luma. */
    const val WHITEBOARD_SATURATION = 1.5

    /** The tile the paper is estimated in, for a page of `width` x `height`. */
    fun tileSize(width: Int, height: Int): Int = max(MIN_TILE_SIZE, max(width, height) / TILES_ALONG_LONG_SIDE)

    /** How bright the paper is across `gray`; null only for an image without pixels. */
    fun paperMap(gray: GrayImage): BackgroundMap? {
        val size = tileSize(gray.width, gray.height)
        val raw = BackgroundMap.estimate(gray, 0, 0, gray.width, gray.height, size, BACKGROUND_PERCENTILE) ?: return null
        val filled = raw.raisedDarkTiles(DARK_TILE_SHARE)
        val median = filled.medianTile().toDouble()
        val floorValue = max(MIN_BACKGROUND, floor(median * MIN_BACKGROUND_SHARE).toInt())
        return filled.clampedBelow(min(255, floorValue))
    }

    /**
     * Whether `gray` is light print on a dark ground (a chalkboard, a dark flyer with white text, a slide),
     * whose ground no division by the paper can make white. The ground is the `GROUND_PERCENTILE` of each
     * tile. A sampled pixel at least `LIGHT_CONTRAST` times the brightest ground of its tile and the eight
     * around it is light print; one at most the darkest of them over `LIGHT_CONTRAST` is dark print, so the
     * paper beside a hard step (the edge of a shadow, a dark picture) counts as neither. Light on dark when
     * there is more light print than dark, and at least `MIN_LIGHT_SHARE` of the samples.
     */
    fun isLightOnDark(gray: GrayImage): Boolean {
        val w = gray.width
        val h = gray.height
        val size = tileSize(w, h)
        val ground = BackgroundMap.estimate(gray, 0, 0, w, h, size, GROUND_PERCENTILE) ?: return false
        val highest = ground.maxSmoothed()
        val lowest = ground.minSmoothed()
        val lumas = gray.pixels
        var light = 0
        var dark = 0
        var samples = 0
        var y = 0
        while (y < h) {
            var x = 0
            while (x < w) {
                val luma = (lumas[y * w + x].toInt() and 0xFF).toDouble()
                val above = max(highest.valueAt(x, y), MIN_BACKGROUND.toDouble())
                val below = max(lowest.valueAt(x, y), MIN_BACKGROUND.toDouble())
                if (luma >= above * LIGHT_CONTRAST) {
                    light++
                } else if (luma * LIGHT_CONTRAST <= below) {
                    dark++
                }
                samples++
                x += SAMPLE_STEP
            }
            y += SAMPLE_STEP
        }
        return light > dark && light.toDouble() >= MIN_LIGHT_SHARE * samples.toDouble()
    }

    /**
     * The paper's white balance: over the sampled pixels at least `PAPER_SHARE` of the paper there, each
     * channel's gain is the luma's sum over that channel's sum, within MIN_GAIN..MAX_GAIN; neutral when no
     * paper is seen.
     */
    fun whiteBalance(image: RgbaImage, gray: GrayImage, paper: BackgroundMap): PaperWhiteBalance {
        val w = image.width
        val h = image.height
        val src = image.pixels
        val lumas = gray.pixels
        var sumR = 0L
        var sumG = 0L
        var sumB = 0L
        var sumL = 0L
        var y = 0
        while (y < h) {
            var x = 0
            while (x < w) {
                val p = y * w + x
                val luma = lumas[p].toInt() and 0xFF
                val background = paper.valueAt(x, y)
                if (luma.toDouble() >= background * PAPER_SHARE) {
                    sumR += src[p * 4].toInt() and 0xFF
                    sumG += src[p * 4 + 1].toInt() and 0xFF
                    sumB += src[p * 4 + 2].toInt() and 0xFF
                    sumL += luma
                }
                x += SAMPLE_STEP
            }
            y += SAMPLE_STEP
        }
        if (sumL == 0L || sumR == 0L || sumG == 0L || sumB == 0L) return PaperWhiteBalance.NEUTRAL
        return PaperWhiteBalance(gain(sumL, sumR), gain(sumL, sumG), gain(sumL, sumB))
    }

    /** The black point: the `BLACK_PERCENTILE` of the sampled pixels' luma levels against the paper there, at most `MAX_BLACK_POINT`. */
    fun blackPoint(gray: GrayImage, paper: BackgroundMap): Double {
        val w = gray.width
        val h = gray.height
        val lumas = gray.pixels
        val histogram = IntArray(LEVELS + 1)
        var samples = 0
        var y = 0
        while (y < h) {
            var x = 0
            while (x < w) {
                histogram[level((lumas[y * w + x].toInt() and 0xFF).toDouble(), paper.valueAt(x, y))]++
                samples++
                x += SAMPLE_STEP
            }
            y += SAMPLE_STEP
        }
        val darkest = percentile(histogram, samples, BLACK_PERCENTILE)
        return min(darkest.toDouble() / LEVELS, MAX_BLACK_POINT)
    }

    /**
     * The share of the paper black and white makes black at the setting `threshold` (0..1): `BILEVEL_SHARE`
     * at `DEFAULT_THRESHOLD`, none at 0 and all of it at 1, linear between.
     */
    fun blackShare(threshold: Double): Double {
        val t = min(max(threshold, 0.0), 1.0)
        if (t <= DEFAULT_THRESHOLD) return BILEVEL_SHARE * t / DEFAULT_THRESHOLD
        return BILEVEL_SHARE + (1 - BILEVEL_SHARE) * (t - DEFAULT_THRESHOLD) / (1 - DEFAULT_THRESHOLD)
    }

    /** `image` cleaned up as `mode` says; black and white cuts at `threshold` (see `blackShare`). */
    fun enhance(image: RgbaImage, mode: DocumentEnhanceMode, threshold: Double = DEFAULT_THRESHOLD): DocumentEnhancement {
        if (mode == DocumentEnhanceMode.Photo) return DocumentEnhancement(photo(image), DocumentEnhanceMode.Photo)
        val w = image.width
        val h = image.height
        val gray = GrayImage.luma(image)
        if (isLightOnDark(gray)) return lightOnDark(image, mode, threshold)
        val paper = paperMap(gray)
        if (paper == null) {
            val resolved = if (mode == DocumentEnhanceMode.Auto) DocumentEnhanceMode.Color else mode
            return DocumentEnhancement(image, resolved)
        }
        val black = if (mode == DocumentEnhanceMode.Whiteboard) 0.0 else blackPoint(gray, paper)
        val lut = stretch(black, WHITE_POINT)
        val color = mode == DocumentEnhanceMode.Auto || mode == DocumentEnhanceMode.Color ||
            mode == DocumentEnhanceMode.Whiteboard
        val balance = if (color) whiteBalance(image, gray, paper) else PaperWhiteBalance.NEUTRAL
        val src = image.pixels
        val lumas = gray.pixels
        val blackBelow = floor(blackShare(threshold) * LEVELS + 0.5).toInt()
        val output = ByteArray(w * h * 4)
        forRowBands(h) { start, end ->
            for (y in start until end) {
                for (x in 0 until w) {
                    val p = y * w + x
                    val i = p * 4
                    val background = paper.valueAt(x, y)
                    if (color) {
                        var r = lut[level((src[i].toInt() and 0xFF) * balance.r, background)]
                        var g = lut[level((src[i + 1].toInt() and 0xFF) * balance.g, background)]
                        var b = lut[level((src[i + 2].toInt() and 0xFF) * balance.b, background)]
                        if (mode == DocumentEnhanceMode.Whiteboard) {
                            val luma = (299 * r + 587 * g + 114 * b + 500) / 1000
                            r = saturated(r, luma)
                            g = saturated(g, luma)
                            b = saturated(b, luma)
                        }
                        output[i] = r.toByte()
                        output[i + 1] = g.toByte()
                        output[i + 2] = b.toByte()
                    } else {
                        val share = level((lumas[p].toInt() and 0xFF).toDouble(), background)
                        var v = lut[share]
                        if (mode == DocumentEnhanceMode.BlackAndWhite) v = if (share < blackBelow) 0 else 255
                        output[i] = v.toByte()
                        output[i + 1] = v.toByte()
                        output[i + 2] = v.toByte()
                    }
                    output[i + 3] = -1
                }
            }
        }
        if (mode == DocumentEnhanceMode.Auto) {
            if (!ColorAnalysis.isEffectivelyGray(output, w, h)) {
                return DocumentEnhancement(RgbaImage(w, h, output), DocumentEnhanceMode.Color)
            }
            // No color left: the gray page, as the gray mode makes it.
            forRowBands(h) { start, end ->
                for (y in start until end) {
                    for (x in 0 until w) {
                        val p = y * w + x
                        val i = p * 4
                        val v = lut[level((lumas[p].toInt() and 0xFF).toDouble(), paper.valueAt(x, y))].toByte()
                        output[i] = v
                        output[i + 1] = v
                        output[i + 2] = v
                    }
                }
            }
            return DocumentEnhancement(RgbaImage(w, h, output), DocumentEnhanceMode.Gray)
        }
        return DocumentEnhancement(RgbaImage(w, h, output), mode)
    }

    /**
     * A light on dark page in `mode`: stretched as a whole (`photo`), in color for `Color` and for `Auto`
     * where it has color; else its luma, thresholded at `setting` of 255 for `BlackAndWhite`.
     */
    private fun lightOnDark(image: RgbaImage, mode: DocumentEnhanceMode, setting: Double): DocumentEnhancement {
        val stretched = photo(image, capped = false)
        val w = stretched.width
        val h = stretched.height
        if (mode == DocumentEnhanceMode.Color || mode == DocumentEnhanceMode.Whiteboard) {
            return DocumentEnhancement(stretched, mode)
        }
        if (mode == DocumentEnhanceMode.Auto && !ColorAnalysis.isEffectivelyGray(stretched.pixels, w, h)) {
            return DocumentEnhancement(stretched, DocumentEnhanceMode.Color)
        }
        val lumas = GrayImage.luma(stretched).pixels
        val threshold = floor(min(max(setting, 0.0), 1.0) * 255 + 0.5).toInt()
        val output = ByteArray(w * h * 4)
        for (p in 0 until w * h) {
            var v = lumas[p].toInt() and 0xFF
            if (mode == DocumentEnhanceMode.BlackAndWhite) v = if (v < threshold) 0 else 255
            output[p * 4] = v.toByte()
            output[p * 4 + 1] = v.toByte()
            output[p * 4 + 2] = v.toByte()
            output[p * 4 + 3] = -1
        }
        val applied = if (mode == DocumentEnhanceMode.Auto) DocumentEnhanceMode.Gray else mode
        return DocumentEnhancement(RgbaImage(w, h, output), applied)
    }

    /**
     * A photo's levels stretched as a whole, the same for each channel: the `PHOTO_CLIP` and 1 - `PHOTO_CLIP`
     * percentiles of its luma become 0 and 255, as far as `photoRange` allows (`capped` false: all the way);
     * a photo whose two are less than `MIN_PHOTO_RANGE` apart is returned as it is.
     */
    fun photo(image: RgbaImage, capped: Boolean = true): RgbaImage {
        val gray = GrayImage.luma(image)
        val histogram = IntArray(256)
        for (value in gray.pixels) histogram[value.toInt() and 0xFF]++
        val count = image.width * image.height
        val lo = BackgroundMap.percentile(histogram, count, PHOTO_CLIP)
        val hi = BackgroundMap.percentile(histogram, count, 1 - PHOTO_CLIP)
        if (hi - lo < MIN_PHOTO_RANGE) return image
        val range = photoRange(lo, hi, capped)
        val span = range.endInclusive - range.start
        val lut = ByteArray(256)
        for (index in 0 until 256) {
            val stretched = floor((index - range.start) * 255.0 / span + 0.5)
            lut[index] = min(max(stretched, 0.0), 255.0).toInt().toByte()
        }
        val src = image.pixels
        val output = ByteArray(src.size)
        var i = 0
        while (i < src.size) {
            output[i] = lut[src[i].toInt() and 0xFF]
            output[i + 1] = lut[src[i + 1].toInt() and 0xFF]
            output[i + 2] = lut[src[i + 2].toInt() and 0xFF]
            output[i + 3] = src[i + 3]
            i += 4
        }
        return RgbaImage(image.width, image.height, output)
    }

    /**
     * The levels that become 0 and 255 for a photo whose percentiles are `lo` and `hi`: those two, unless
     * the gain would pass `MAX_PHOTO_GAIN`, then the range is widened to 255 / `MAX_PHOTO_GAIN` levels, each
     * end moving out in proportion to the room it has before 0 or 255, so the photo's own tones stay put.
     */
    fun photoRange(lo: Int, hi: Int, capped: Boolean = true): ClosedFloatingPointRange<Double> {
        val range = (hi - lo).toDouble()
        val span = if (capped) max(range, 255.0 / MAX_PHOTO_GAIN) else range
        val extra = span - range
        if (extra <= 0) return lo.toDouble()..hi.toDouble()
        val low = lo.toDouble() - extra * lo.toDouble() / (255.0 - range)
        return low..(low + span)
    }

    /** `value` against the paper's `background`, as a level 0..`LEVELS` (at most the paper's own). */
    fun level(value: Double, background: Double): Int {
        val share = min(1.0, value / background)
        return floor(share * LEVELS + 0.5).toInt()
    }

    /** The levels 0..`LEVELS` stretched linearly from `lo` (black) to `hi` (white), as byte values 0..255. */
    fun stretch(lo: Double, hi: Double): IntArray {
        val lut = IntArray(LEVELS + 1)
        for (k in 0..LEVELS) {
            val raw = (k.toDouble() / LEVELS - lo) / (hi - lo)
            val v = min(max(raw, 0.0), 1.0)
            lut[k] = floor(v * 255 + 0.5).toInt()
        }
        return lut
    }

    private fun saturated(value: Int, luma: Int): Int {
        val moved = luma.toDouble() + floor((value - luma).toDouble() * WHITEBOARD_SATURATION + 0.5)
        return min(max(moved, 0.0), 255.0).toInt()
    }

    private fun gain(luma: Long, channel: Long): Double =
        min(max(luma.toDouble() / channel.toDouble(), MIN_GAIN), MAX_GAIN)

    private fun percentile(histogram: IntArray, count: Int, fraction: Double): Int {
        val rank = min(max(ceil(fraction * count.toDouble()).toInt(), 1), max(1, count))
        var seen = 0
        for (k in histogram.indices) {
            seen += histogram[k]
            if (seen >= rank) return k
        }
        return histogram.size - 1
    }
}
