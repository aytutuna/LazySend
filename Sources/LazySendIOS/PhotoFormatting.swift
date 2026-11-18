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

    /// The most pixels a picture may have to be made a PNG, which has to be decoded whole (4 bytes a pixel in memory).
    static let maxPngPixels = 50_000_000

    /// A still picture that can be converted: not a RAW or DNG, AVIF, GIF or other picture that moves, a video, or anything that is not an
    /// image. A picture of more than one frame (an animated HEICS, WebP or APNG) is not still.
    static func isConvertible(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image), !type.conforms(to: .gif),
              !type.conforms(to: .rawImage), type.identifier != "public.avif", type.identifier != "public.avis",
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) == 1
    }

    /// The picked photo in `format`, written next to the original, which goes. The photo itself when it is to stay as it is: Original,
    /// something that is not a still picture, a picture that already is in that format, or one that cannot be converted.
    static func prepare(_ url: URL, as format: PhotoFormat) -> URL {
        guard format != .original, isConvertible(url) else { return url }
        let target: UTType = format == .png ? .png : .jpeg
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: target) { return url }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let data = convert(source, to: target) else { return url }
        let renamed = url.deletingPathExtension().appendingPathExtension(format == .png ? "png" : "jpg")
        do {
            try data.write(to: renamed)
            try? FileManager.default.removeItem(at: url)
            return renamed
        } catch {
            return url
        }
    }

    /// A camera shot as PNG, which carries no orientation, so the turn is put into the pixels.
    static func png(fromPhoto data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return convert(source, to: .png)
    }

    /// JPEG is streamed from the source with the picture's metadata (EXIF, GPS, orientation tag) and never decoded whole; PNG gets the
    /// picture turned upright, which decodes it, so a picture of more than `maxPngPixels` stays as it is (nil).
    private static func convert(_ source: CGImageSource, to type: UTType) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        if type == .png {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
            guard width * height <= maxPngPixels else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1)]
            guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            CGImageDestinationAddImage(destination, upright, nil)
        } else {
            let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: jpegQuality]
            CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        }
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
#endif
