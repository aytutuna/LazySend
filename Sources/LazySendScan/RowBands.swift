import Foundation

/// Splits the rows of an image across the cores for loops whose rows do not depend on each other.
enum RowBands {
    /// Calls `body` with row ranges that are disjoint and together cover 0..<rows, on all cores. `body`
    /// may only write the rows it is given.
    static func perform(rows: Int, _ body: (Range<Int>) -> Void) {
        let bands = min(rows, ProcessInfo.processInfo.activeProcessorCount * 4)
        if bands <= 1 {
            body(0..<rows)
            return
        }
        let size = (rows + bands - 1) / bands
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            let start = band * size
            let end = min(rows, start + size)
            if start < end { body(start..<end) }
        }
    }
}
