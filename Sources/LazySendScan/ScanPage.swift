import CoreGraphics
import Foundation

/// A page of a scan: the photo as the camera wrote it with the corners the page was cut out along (so the page can be
/// cut again), the filter it was cleaned up with, and the page as a JPEG.
public struct ScanPage: Identifiable, Sendable {
    public let id: UUID
    public var source: Data
    /// The corners in the upright photo's pixels.
    public var corners: Quad
    public var filter: CaptureFilter
    public var jpeg: Data
    public var width: Int
    public var height: Int
    /// The resolution the page is printed at in a PDF.
    public var dpi: Int
    /// The page has no colour (gray or black and white), so its JPEG has one component.
    public var gray: Bool

    public init(id: UUID = UUID(), source: Data, corners: Quad, filter: CaptureFilter, jpeg: Data, width: Int, height: Int,
                dpi: Int, gray: Bool) {
        self.id = id
        self.source = source
        self.corners = corners
        self.filter = filter
        self.jpeg = jpeg
        self.width = width
        self.height = height
        self.dpi = dpi
        self.gray = gray
    }
}

/// Makes the page of a photo: cut out along the corners with its perspective corrected, then cleaned up as the filter
/// says.
public enum PagePipeline {
    /// The resolution of a page whose paper size is not known.
    public static let nominalDPI = 200
    public static let minDPI = 50
    public static let maxDPI = 1200
    /// The long side of a sheet taken as a whole photo's page, in inches (A4).
    static let wholePhotoInches = 11.69

    /// The page of `photo` (upright) cut along `corners`. Nil when the corners outline no page or the page cannot be
    /// encoded.
    public static func page(photo: RgbaImage, source: Data, corners: Quad, filter: CaptureFilter, id: UUID = UUID()) -> ScanPage? {
        let named = Quad.fromCorners(corners.corners)
        guard let cut = PerspectiveCorrector.correct(photo, quad: named) else { return nil }
        guard let made = cleaned(cut.image, filter: filter) else { return nil }
        return ScanPage(id: id, source: source, corners: corners, filter: filter, jpeg: made.jpeg, width: made.width,
                        height: made.height, dpi: pageDPI(cut.plan.dpi), gray: made.gray)
    }

    /// The whole photo as the page, as with Use whole photo in the corner editor: only the filter is applied.
    public static func wholePage(photo: RgbaImage, source: Data, filter: CaptureFilter, id: UUID = UUID()) -> ScanPage? {
        guard let made = cleaned(photo, filter: filter) else { return nil }
        let dpi = pageDPI(Double(max(photo.width, photo.height)) / wholePhotoInches)
        return ScanPage(id: id, source: source, corners: PageFinder.wholePhoto(width: photo.width, height: photo.height),
                        filter: filter, jpeg: made.jpeg, width: made.width, height: made.height, dpi: dpi, gray: made.gray)
    }

    private static func cleaned(_ image: RgbaImage, filter: CaptureFilter) -> (jpeg: Data, width: Int, height: Int, gray: Bool)? {
        var result = image
        var gray = false
        if let mode = filter.mode {
            let enhanced = DocumentEnhancer.enhance(image, mode: mode)
            result = enhanced.image
            gray = enhanced.mode == .gray || enhanced.mode == .blackAndWhite
        }
        guard let jpeg = JpegEncoder.encode(result, gray: gray) else { return nil }
        return (jpeg, result.width, result.height, gray)
    }

    /// `dpi` rounded and kept within `minDPI` to `maxDPI`; `nominalDPI` when the size is not known.
    static func pageDPI(_ dpi: Double?) -> Int {
        guard let d = dpi, d.isFinite, d > 0 else { return nominalDPI }
        return min(max(Int((d + 0.5).rounded(.down)), minDPI), maxDPI)
    }
}
