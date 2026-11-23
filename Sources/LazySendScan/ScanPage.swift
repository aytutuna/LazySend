import CoreGraphics
import Foundation

/// A page of a scan: the corners it was cut out along in the photo (so the page can be cut again from the photo, which
/// `ScanPageStore` keeps), the filter it was cleaned up with, and the page as a JPEG.
public struct ScanPage: Identifiable, Sendable {
    public let id: UUID
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

    public init(id: UUID = UUID(), corners: Quad, filter: CaptureFilter, jpeg: Data, width: Int, height: Int,
                dpi: Int, gray: Bool) {
        self.id = id
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
    public static let nominalDPI = 200
    public static let minDPI = 50
    public static let maxDPI = 1200
    /// Where Letter is the usual paper; A4 everywhere else.
    static let letterRegions = ["US", "CA", "MX", "PH", "CL", "CO", "CR", "DO", "GT", "NI", "PA", "PR", "SV", "VE"]
    /// A cut page is at most this many pixels long (A4 at 300 dpi), however close the camera was.
    public static let maxLongSide = 3508

    /// The page of `photo` (upright) cut along `corners`. Nil when the corners outline no page or the page cannot be
    /// encoded.
    public static func page(photo: RgbaImage, corners: Quad, filter: CaptureFilter, id: UUID = UUID()) -> ScanPage? {
        let named = Quad.fromCorners(corners.corners)
        var options = PerspectiveOptions()
        options.maxLongSide = maxLongSide
        guard let cut = PerspectiveCorrector.correct(photo, quad: named, options: options) else { return nil }
        guard let made = cleaned(cut.image, filter: filter) else { return nil }
        return ScanPage(id: id, corners: corners, filter: filter, jpeg: made.jpeg, width: made.width,
                        height: made.height, dpi: pageDPI(cut.plan.dpi, longSide: max(made.width, made.height)), gray: made.gray)
    }

    /// The whole photo as the page, as with Use whole photo in the corner editor: only the filter is applied.
    public static func wholePage(photo: RgbaImage, filter: CaptureFilter, id: UUID = UUID()) -> ScanPage? {
        guard let made = cleaned(photo, filter: filter) else { return nil }
        let dpi = pageDPI(nil, longSide: max(made.width, made.height))
        return ScanPage(id: id, corners: PageFinder.wholePhoto(width: photo.width, height: photo.height),
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

    /// `dpi` rounded and kept within `minDPI` to `maxDPI`. A page that matched no paper size gets the resolution that makes its
    /// long side the long side of the usual paper where the user lives (Letter or A4), so it is not printed at a made-up size.
    static func pageDPI(_ dpi: Double?, longSide: Int, region: String? = Locale.current.region?.identifier) -> Int {
        var d = dpi ?? 0
        if !(d.isFinite && d > 0) {
            let inches = letterRegions.contains((region ?? "").uppercased()) ? 11.0 : 11.69
            d = longSide > 0 ? Double(longSide) / inches : Double(nominalDPI)
        }
        return min(max(Int((d + 0.5).rounded(.down)), minDPI), maxDPI)
    }
}
