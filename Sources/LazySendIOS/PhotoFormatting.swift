#if os(iOS)
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The format photos are sent in, for camera shots and for photos picked in Files.
enum PhotoFormat: String, CaseIterable, Identifiable {
    case jpeg
    case original
    case png

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jpeg: return "JPEG"
        case .original: return String(localized: "Original")
        case .png: return "PNG"
        }
    }
}

enum PhotoFormatting {
    static let jpegQuality = 0.92

    /// The most pixels a picture may have to be converted: a PNG has to be decoded whole (4 bytes a pixel in memory) and a JPEG made from
    /// a still decodes in tiles but still costs time and memory on a phone, so a bigger one is sent as it is.
    static let maxPixels = 50_000_000

    /// A still picture that can be converted: not a RAW or DNG, AVIF, GIF or other picture that moves, a video, or anything that is not an
    /// image. A picture of more than one frame (an animated HEICS, WebP or APNG) is not still.
    static func isConvertible(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image), !type.conforms(to: .gif),
              !type.conforms(to: .rawImage), type.identifier != "public.avif", type.identifier != "public.avis",
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) == 1
    }

    /// The picked photo in `format`, written next to the original, which goes. The photo itself when it is to stay as it is: Original,
    /// something that is not a still picture, or one that cannot be converted. JPEG converts only a HEIC, HEIF or WebP photo without
    /// transparency, so a PNG screenshot stays lossless and transparency stays; PNG converts any still picture that is not one already.
    static func prepare(_ url: URL, as format: PhotoFormat) -> URL {
        guard format != .original, isConvertible(url), let type = UTType(filenameExtension: url.pathExtension),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil), wants(format, of: type, source: source),
              pixels(of: source) <= maxPixels else { return url }
        let target: UTType = format == .png ? .png : .jpeg
        let renamed = url.deletingPathExtension().appendingPathExtension(format == .png ? "png" : "jpg")
        guard let destination = CGImageDestinationCreateWithURL(renamed as CFURL, target.identifier as CFString, 1, nil),
              fill(destination, from: source, as: target) else {
            try? FileManager.default.removeItem(at: renamed)
            return url
        }
        try? FileManager.default.removeItem(at: url)
        return renamed
    }

    /// A camera shot as PNG, which carries no orientation, so the turn is put into the pixels.
    static func png(fromPhoto data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), pixels(of: source) <= maxPixels else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil),
              fill(destination, from: source, as: .png) else { return nil }
        return out as Data
    }

    private static func wants(_ format: PhotoFormat, of type: UTType, source: CGImageSource) -> Bool {
        if format == .png { return !type.conforms(to: .png) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        if properties?[kCGImagePropertyHasAlpha] as? Bool == true { return false }
        return type.conforms(to: .heic) || type.conforms(to: .heif) || type.conforms(to: .webP)
    }

    private static func size(of source: CGImageSource) -> (width: Int, height: Int) {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return (properties?[kCGImagePropertyPixelWidth] as? Int ?? 0, properties?[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    private static func pixels(of source: CGImageSource) -> Int {
        let side = size(of: source)
        return side.width * side.height
    }

    /// JPEG is copied from the source with the picture's metadata (EXIF, GPS, the orientation tag); PNG gets the picture turned upright,
    /// which decodes it whole.
    private static func fill(_ destination: CGImageDestination, from source: CGImageSource, as type: UTType) -> Bool {
        if type == .png {
            let side = size(of: source)
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: max(side.width, side.height, 1)]
            guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return false }
            CGImageDestinationAddImage(destination, upright, nil)
        } else {
            let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: jpegQuality]
            CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        }
        return CGImageDestinationFinalize(destination)
    }
}
#endif
