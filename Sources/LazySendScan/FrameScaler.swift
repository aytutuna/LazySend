import Foundation

/// Makes a camera frame (BGRA, as the video output hands it over) small for the page search: the frame is
/// split into blocks of `step` × `step` pixels (`step` the smallest whole number that brings the long
/// side to at most `maxLongSide`), and each block gives one pixel, the mean of four of its pixels (at a
/// quarter and three quarters of the block each way), so the work is bounded by the small frame's size,
/// not the camera's.
public enum FrameScaler {
    public static func downscaled(bgra: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int,
                                  maxLongSide: Int) -> RgbaImage? {
        guard width > 0, height > 0, maxLongSide > 0, bytesPerRow >= width * 4 else { return nil }
        guard bgra.count >= bytesPerRow * (height - 1) + width * 4 else { return nil }
        let longSide: Int = max(width, height)
        let step: Int = max((longSide + maxLongSide - 1) / maxLongSide, 1)
        let outWidth: Int = max(width / step, 1)
        let outHeight: Int = max(height / step, 1)
        let near: Int = step / 4
        let far: Int = (3 * step) / 4
        var pixels: [UInt8] = [UInt8](repeating: 255, count: outWidth * outHeight * 4)
        var oy: Int = 0
        while oy < outHeight {
            let y0: Int = min(oy * step + near, height - 1)
            let y1: Int = min(oy * step + far, height - 1)
            var ox: Int = 0
            while ox < outWidth {
                let x0: Int = min(ox * step + near, width - 1)
                let x1: Int = min(ox * step + far, width - 1)
                let a: Int = y0 * bytesPerRow + x0 * 4
                let b: Int = y0 * bytesPerRow + x1 * 4
                let c: Int = y1 * bytesPerRow + x0 * 4
                let d: Int = y1 * bytesPerRow + x1 * 4
                let o: Int = (oy * outWidth + ox) * 4
                var channel: Int = 0
                while channel < 3 {
                    // BGRA in, RGBA out: red is the frame's third byte, blue its first.
                    let from: Int = 2 - channel
                    let sum: Int = Int(bgra[a + from]) + Int(bgra[b + from]) + Int(bgra[c + from]) + Int(bgra[d + from])
                    pixels[o + channel] = UInt8((sum + 2) / 4)
                    channel += 1
                }
                ox += 1
            }
            oy += 1
        }
        return RgbaImage(width: outWidth, height: outHeight, pixels: pixels)
    }
}
