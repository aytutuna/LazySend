import CoreGraphics
import Foundation

/// The page's corners from the heatmaps of DocAligner's corner models: four channels of `width` × `height`
/// values from 0 to 1, one per corner, top left, top right, bottom right and bottom left. In each channel the values
/// from `threshold` up are the corner's; of their 8-connected blobs the largest (most values) is taken, and
/// the corner is its centre weighted by the heat, as shares of the image (x right, y down; value (x, y)
/// stands for the point (x + 0.5) / width, (y + 0.5) / height). The confidence is the lowest of the four
/// channels' peaks. Nil when a channel has no value from `threshold` up, or the four corners are not a
/// convex outline in their order.
public enum CornerHeatmap {
    public static let threshold: Float = 0.3

    public static func decode(_ heat: [Float], width: Int, height: Int) -> QuadCandidate? {
        guard width > 0, height > 0 else { return nil }
        let plane: Int = width * height
        guard heat.count >= plane * 4 else { return nil }
        var visited: [Bool] = [Bool](repeating: false, count: plane)
        var stack: [Int] = []
        var corners: [CGPoint] = []
        var confidence: Double = 1
        var channel: Int = 0
        while channel < 4 {
            guard let found = corner(heat, base: channel * plane, width: width, height: height, visited: &visited,
                                     stack: &stack) else { return nil }
            corners.append(found.point)
            confidence = min(confidence, found.peak)
            channel += 1
        }
        let quad = Quad(topLeft: corners[0], topRight: corners[1], bottomRight: corners[2], bottomLeft: corners[3])
        guard quad.isConvex else { return nil }
        return QuadCandidate(quad: quad, confidence: confidence)
    }

    /// The heat-weighted centre of the largest blob in the channel starting at `base`, and the channel's peak.
    private static func corner(_ heat: [Float], base: Int, width: Int, height: Int, visited: inout [Bool],
                               stack: inout [Int]) -> (point: CGPoint, peak: Double)? {
        let plane: Int = width * height
        var index: Int = 0
        while index < plane {
            visited[index] = false
            index += 1
        }
        var peak: Float = 0
        var bestCount: Int = 0
        var bestX: Double = 0
        var bestY: Double = 0
        var start: Int = 0
        while start < plane {
            let value: Float = heat[base + start]
            peak = max(peak, value)
            if value >= threshold && !visited[start] {
                visited[start] = true
                stack.removeAll(keepingCapacity: true)
                stack.append(start)
                var count: Int = 0
                var sum: Double = 0
                var sumX: Double = 0
                var sumY: Double = 0
                while let at = stack.popLast() {
                    let x: Int = at % width
                    let y: Int = at / width
                    let weight: Double = Double(heat[base + at])
                    count += 1
                    sum += weight
                    sumX += weight * (Double(x) + 0.5)
                    sumY += weight * (Double(y) + 0.5)
                    var ny: Int = max(y - 1, 0)
                    while ny <= min(y + 1, height - 1) {
                        var nx: Int = max(x - 1, 0)
                        while nx <= min(x + 1, width - 1) {
                            let next: Int = ny * width + nx
                            if !visited[next] && heat[base + next] >= threshold {
                                visited[next] = true
                                stack.append(next)
                            }
                            nx += 1
                        }
                        ny += 1
                    }
                }
                if count > bestCount {
                    bestCount = count
                    bestX = sumX / sum
                    bestY = sumY / sum
                }
            }
            start += 1
        }
        guard bestCount > 0 else { return nil }
        return (CGPoint(x: bestX / Double(width), y: bestY / Double(height)), Double(peak))
    }
}
