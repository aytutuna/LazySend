#if os(iOS)
import LazySendKit
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What a paste holds, picked in the order picture, link, text.
enum Pasted: Equatable {
    case image(Data, ext: String)
    case link(URL)
    case text(String)

    static func load(_ providers: [NSItemProvider]) async -> Pasted? {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            if let image = await image(provider) { return image }
        }
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            if let url = await url(provider), !url.isFileURL { return .link(url) }
        }
        for provider in providers where provider.canLoadObject(ofClass: String.self) {
            if let text = await text(provider), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .text(text) }
        }
        return nil
    }

    // PNG and JPEG are kept as they are; any other picture is sent as PNG.
    private static func image(_ provider: NSItemProvider) async -> Pasted? {
        let kept: [(UTType, String)] = [(.png, "png"), (.jpeg, "jpg")]
        for (type, ext) in kept where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let data = await data(provider, type) { return .image(data, ext: ext) }
        }
        guard let data = await data(provider, .image), let png = UIImage(data: data)?.pngData() else { return nil }
        return .image(png, ext: "png")
    }

    private static func data(_ provider: NSItemProvider, _ type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in continuation.resume(returning: data) }
        }
    }

    private static func url(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private static func text(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in continuation.resume(returning: text) }
        }
    }
}

/// The clipboard tab: paste to put it on the chosen device's clipboard, and what went both ways lately.
struct ClipboardView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var timeline: Timeline
    let pair: () -> Void
    @State private var problem: String?
    @State private var preview: URL?

    private static let kinds: [UTType] = [.image, .url, .plainText]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let target = model.selectedTarget {
                        VStack(alignment: .leading, spacing: 10) {
                            PasteButton(supportedContentTypes: ClipboardView.kinds) { paste($0, to: target) }
                                .buttonBorderShape(.capsule)
                                .accessibilityIdentifier("clip.paste")
                            Text("Paste here to put it on \(target.name)'s clipboard.")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("clip.hint")
                            if let problem {
                                Text(problem).foregroundStyle(.red)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        Text("Pair a computer to send what you copy.").foregroundStyle(.secondary)
                        Button("Pair a computer", action: pair)
                            .accessibilityIdentifier("clip.pair")
                    }
                }
                Section {
                    if recent.isEmpty {
                        Text("What you put on a clipboard, and what is put on this one, shows up here.").foregroundStyle(.secondary)
                    }
                    ForEach(recent) { entry in
                        EntryRow(entry: entry) { name in
                            let url = model.documentURL(name)
                            if FileManager.default.fileExists(atPath: url.path) { preview = url }
                        }
                    }
                }
            }
            .navigationTitle("Clipboard")
            .quickLookPreview($preview)
        }
    }

    private var recent: [TimelineEntry] {
        Array(timeline.entries.filter { $0.clip == true }.prefix(10))
    }

    private func paste(_ providers: [NSItemProvider], to target: AppModel.Target) {
        Task { @MainActor in
            guard let pasted = await Pasted.load(providers) else {
                problem = String(localized: "There was nothing to send.")
                return
            }
            do {
                try send(pasted, to: target)
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func send(_ pasted: Pasted, to target: AppModel.Target) throws {
        switch pasted {
        case .text(let text):
            try model.sendNote(text, to: target, clip: true)
        case .link(let url):
            try model.sendNote(url.absoluteString, to: target, clip: true)
        case .image(let data, let ext):
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lazysend-clip-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(ClipName.clipboard(ext: ext))
            try data.write(to: file)
            model.sendFiles([file], to: target, clip: true)
        }
    }
}
#endif
