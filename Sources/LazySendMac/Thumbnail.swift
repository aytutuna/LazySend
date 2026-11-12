#if os(macOS)
import AppKit
import QuickLookThumbnailing
import SwiftUI

/// A file's preview, made by Quick Look off the main thread; its icon until the preview is ready.
struct Thumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit().padding(6)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 56, height: 56),
                                                      scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = representation.nsImage
            }
        }
    }
}
#endif
