import CoreGraphics
import Foundation
import ImageIO

/// JPEG bytes for a page, through ImageIO.
public enum JpegEncoder {
    public static let quality = 0.85

    /// `image` as a JPEG, one gray component when `gray` (a gray or black and white page), else RGB. Nil when ImageIO
    /// cannot make it.
    public static func encode(_ image: RgbaImage, gray: Bool) -> Data? {
        guard let picture = gray ? grayImage(image) : image.makeCGImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, picture, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func grayImage(_ image: RgbaImage) -> CGImage? {
        let luma = GrayImage.luma(image)
        guard let provider = CGDataProvider(data: Data(luma.pixels) as CFData) else { return nil }
        return CGImage(width: luma.width, height: luma.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: luma.width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// A photo read for scanning, with its orientation tag applied.
public enum PhotoReader {
    /// The long side a photo is read at, at most: a camera shot is 12 megapixels, so this is about whole.
    public static let maxLongSide = 4096

    public static func decode(_ data: Data) -> RgbaImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        // A thumbnail is the way to get the orientation applied; asked for the photo's own long side it is the photo.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxLongSide)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return RgbaImage(cgImage: image)
    }
}
