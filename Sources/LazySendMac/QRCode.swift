#if os(macOS)
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum QRCode {
    /// The code for `text` as black modules on white with a four-module quiet zone, `scale` pixels to a module.
    static func image(for text: String, scale: CGFloat = 6) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let modules = filter.outputImage else { return nil }
        let quiet = 4 * scale
        let scaled = modules.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let page = scaled.extent.insetBy(dx: -quiet, dy: -quiet)
        let white = CIImage(color: .white).cropped(to: page)
        let drawn = scaled.composited(over: white)
        guard let cg = CIContext().createCGImage(drawn, from: page) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: page.width, height: page.height))
    }
}
#endif
