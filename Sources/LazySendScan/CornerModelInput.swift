import Foundation

/// A photo as DocAligner's corner models take it: stretched to `side` × `side` (its shape not kept, as the
/// models were trained) and given as blue, green and red planes of values from 0 to 1, one row after
/// another. Sampled bilinearly with the pixel centres matched, as OpenCV's linear resize does: input pixel
/// (x, y) reads the photo at ((x + 0.5) × width / side − 0.5, (y + 0.5) × height / side − 0.5), clamped to
/// the photo, from the four pixels around it. Written out here rather than left to CoreGraphics or WPF,
/// whose scaling differs.
public enum CornerModelInput {
    /// The input's side, in pixels.
    public static let side: Int = 256

    /// `photo` (alpha left out) as the model's input: 3 × `side` × `side` values.
    public static func make(_ photo: RgbaImage) -> [Float] {
        let side: Int = CornerModelInput.side
        let plane: Int = side * side
        var input: [Float] = [Float](repeating: 0, count: 3 * plane)
        let scaleX: Double = Double(photo.width) / Double(side)
        let scaleY: Double = Double(photo.height) / Double(side)
        var y: Int = 0
        while y < side {
            let row: (low: Int, high: Int, weight: Double) = tap(y, scale: scaleY, size: photo.height)
            let top: Int = row.low * photo.width
            let bottom: Int = row.high * photo.width
            var x: Int = 0
            while x < side {
                let column: (low: Int, high: Int, weight: Double) = tap(x, scale: scaleX, size: photo.width)
                var channel: Int = 0
                while channel < 3 {
                    // Blue first: the models read OpenCV's BGR.
                    let offset: Int = 2 - channel
                    let a: Double = Double(photo.pixels[(top + column.low) * 4 + offset])
                    let b: Double = Double(photo.pixels[(top + column.high) * 4 + offset])
                    let c: Double = Double(photo.pixels[(bottom + column.low) * 4 + offset])
                    let d: Double = Double(photo.pixels[(bottom + column.high) * 4 + offset])
                    let upper: Double = a + (b - a) * column.weight
                    let lower: Double = c + (d - c) * column.weight
                    input[channel * plane + y * side + x] = Float((upper + (lower - upper) * row.weight) / 255)
                    channel += 1
                }
                x += 1
            }
            y += 1
        }
        return input
    }

    /// The two photo pixels input pixel `index` reads along a side of `size` pixels, and the second's weight.
    static func tap(_ index: Int, scale: Double, size: Int) -> (low: Int, high: Int, weight: Double) {
        let at: Double = max((Double(index) + 0.5) * scale - 0.5, 0)
        let low: Int = min(Int(at), size - 1)
        let high: Int = min(low + 1, size - 1)
        return (low, high, at - Double(low))
    }
}
