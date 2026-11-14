#if os(macOS)
import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import LazySendKit
@testable import LazySendMac
@testable import LazySendServer

// The Mac app's screens, written as PNGs when LAZYSEND_SHOTS names a folder, so they can be looked at without a Mac.
// They are not assertions of pixels. Each screen is a view hosted in an NSHostingView inside a borderless window out of
// sight; the pairing sheet is a window of its own in the app, so it is hosted on its own here.

@MainActor
final class ScreenshotTests: XCTestCase {
    private func shots() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["LAZYSEND_SHOTS"], !path.isEmpty else {
            throw XCTSkip("LAZYSEND_SHOTS names no folder")
        }
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func photo(_ name: String, sky: CGColor, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let width = 1200, height = 800
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let gradient = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.95, green: 0.7, blue: 0.4, alpha: 1), sky] as CFArray,
                                        locations: [0, 1])
        else { throw CocoaError(.fileWriteUnknown) }
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 300), end: CGPoint(x: 0, y: 800), options: [])
        context.setFillColor(CGColor(red: 0.25, green: 0.55, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 300))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    private func capture<Content: View>(_ view: Content, name: String, in folder: URL, size: CGSize?) async throws {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (NSAppearance.Name.darkAqua, "dark")] {
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            let measured = size ?? CGSize(width: 640, height: max(host.fittingSize.height, 200))
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: measured.width, height: measured.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderFront(nil)
            host.frame = NSRect(origin: .zero, size: measured)
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            host.layoutSubtreeIfNeeded()
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(measured.width) * 2, pixelsHigh: Int(measured.height) * 2,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                XCTFail("No bitmap for \(name)")
                continue
            }
            rep.size = measured
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: folder.appendingPathComponent("mac-\(name)-\(suffix).png"))
            window.orderOut(nil)
            window.contentView = nil
        }
    }

    func testMainWindowAndPairingSheet() async throws {
        let folder = try shots()
        let fixture = try ModelFixture()
        let model = fixture.model
        let iphone = try await fixture.pair("Aytu's iPhone")
        try await fixture.pair("Pixel 9")
        model.selectedPhoneId = iphone.id

        let work = fixture.root.appendingPathComponent("shots-work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        for index in 0..<24 {
            let url = fixture.root.appendingPathComponent("received/Aytu's iPhone/Gallery/2026-11/IMG_\(index).jpg")
            model.addFile(ReceivedFile(deviceId: iphone.id, deviceName: iphone.name, url: url, size: 2_000_000, sourceId: "asset-\(index)"))
        }
        model.finishGalleries(now: Date().addingTimeInterval(60))
        let photoURL = try photo("Beach.png", sky: CGColor(red: 0.35, green: 0.6, blue: 0.9, alpha: 1), in: work)
        model.addFile(ReceivedFile(deviceId: iphone.id, deviceName: iphone.name, url: photoURL, size: 1_450_000, sourceId: nil))
        let link = fixture.service.history.add(iphone, kind: "link", text: nil, url: "https://alazy.app/send/", now: Date())
        model.addText(link, arrived: false)
        let note = fixture.service.history.add(iphone, kind: "text", text: "Meet at the east entrance at 6. Bring the tickets.",
                                               url: nil, now: Date())
        model.addText(note, arrived: false)
        model.sendText("Notes from the call are in the shared folder.")
        let report = work.appendingPathComponent("Quarterly report.pdf")
        try Data(count: 3_200_000).write(to: report)
        model.sendFiles([report])

        try await capture(MainView(model: model), name: "main", in: folder, size: CGSize(width: 1020, height: 700))

        await model.beginPairing()
        let request = PairRequest(token: "x", phoneId: newId(), phoneName: "Aytu's iPhone", platform: "ios", appVersion: "1.0")
        let asking = Task { await model.ask(request) }
        await assertEventually { model.approval != nil }
        try await capture(PairSheet(model: model), name: "pair", in: folder, size: nil)
        model.answerApproval(false)
        _ = await asking.value
        model.closePairing()
        await fixture.tearDown()
    }

    func testConnectSheet() async throws {
        let folder = try shots()
        let fixture = try await GuestModelFixture()
        let connecting = fixture.connecting()
        await connecting.look()
        connecting.input = "7KQ2-M9XD"
        try await capture(ConnectSheet(model: connecting, close: {}), name: "connect", in: folder, size: nil)
        await fixture.tearDown()
    }
}
#endif
