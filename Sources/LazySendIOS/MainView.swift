#if os(iOS)
import LazySendKit
import PhotosUI
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum Route: Hashable {
    case send
    case pair
    case pcs
    case receive
}

/// A file dropped on the Files tab, copied into a folder of its own so it can be moved into the send queue.
struct DroppedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lazysend-drop-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return DroppedFile(url: copy)
        }
    }
}

private enum Source {
    case photos
    case files
}

/// The Files tab: photos and files, sent and received. What is picked here, or dropped, goes straight to the chosen device.
struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var timeline: Timeline
    let go: (Route) -> Void
    @State private var preview: URL?
    @State private var source: Source?
    @State private var picks: [PhotosPickerItem] = []

    var body: some View {
        Group {
            if model.targets.isEmpty {
                empty
            } else {
                VStack(spacing: 0) {
                    header
                    if files.isEmpty {
                        emptyStage
                    } else {
                        list
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if !files.isEmpty {
                        addMenu(size: 44)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(.bar)
                    }
                }
            }
        }
        .navigationTitle("Lazy Send")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !model.targets.isEmpty {
                    Button("Receive") { go(.receive) }
                        .accessibilityIdentifier("main.receive")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !model.targets.isEmpty {
                    Button("Devices") { go(.pcs) }
                        .accessibilityIdentifier("main.pcs")
                }
            }
        }
        .quickLookPreview($preview)
        .photosPicker(isPresented: shown(.photos), selection: $picks, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
        .fileImporter(isPresented: shown(.files), allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, let target = model.selectedTarget {
                model.sendFiles(urls, to: target, scoped: true)
            }
        }
        .onChange(of: picks) { _, items in
            guard !items.isEmpty else { return }
            picks = []
            guard let target = model.selectedTarget else { return }
            Task { @MainActor in
                for item in items {
                    if let media = try? await item.loadTransferable(type: PickedMedia.self) { await model.sendPhoto(media.url, to: target) }
                }
            }
        }
        .dropDestination(for: DroppedFile.self) { dropped, _ in
            guard let target = model.selectedTarget, !dropped.isEmpty else { return false }
            model.sendFiles(dropped.map(\.url), to: target)
            return true
        }
    }

    private var files: [TimelineEntry] {
        EntryFilter.files(timeline.entries)
    }

    private func shown(_ wanted: Source) -> Binding<Bool> {
        Binding(get: { source == wanted }, set: { if !$0 && source == wanted { source = nil } })
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Text("Nothing paired yet")
                .font(.title2.bold())
                .accessibilityIdentifier("empty.title")
            Text("Open Lazy Send on your PC, choose Pair a phone and scan the code it shows.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Pair a PC") { go(.pair) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("empty.pair")
            Button("Receive from a phone") { go(.receive) }
                .accessibilityIdentifier("empty.receive")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStage: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.doc")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Nothing shared yet")
                .font(.title3.weight(.semibold))
            Text("Photos and files you send or receive show up here.")
                .foregroundStyle(.secondary)
            addMenu(size: 56)
                .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files.empty")
    }

    /// The + that picks photos or files, and the format photos go in. It sets the source straight away, since a dialog in between
    /// would still be closing when the picker opened.
    private func addMenu(size: CGFloat) -> some View {
        Menu {
            Button {
                source = .photos
            } label: {
                Label("Photos", systemImage: "photo.on.rectangle")
            }
            .accessibilityIdentifier("source.photos")
            Button {
                source = .files
            } label: {
                Label("Files", systemImage: "folder")
            }
            .accessibilityIdentifier("source.files")
            Button {
                go(.send)
            } label: {
                Label("All photos and videos", systemImage: "photo.stack")
            }
            .accessibilityIdentifier("source.gallery")
            Menu {
                Picker("Format", selection: Binding(get: { model.photoFormat }, set: { model.setPhotoFormat($0) })) {
                    ForEach(PhotoFormat.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Label("Photo format: \(model.photoFormat.title)", systemImage: "slider.horizontal.3")
            }
            .accessibilityIdentifier("source.format")
        } label: {
            Label("Add files", systemImage: "plus")
                .labelStyle(.iconOnly)
                .imageScale(.large)
                .frame(minWidth: size, minHeight: size)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("files.add")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TargetMenu { target in
                Label(target.name, systemImage: target.phone ? "iphone" : "laptopcomputer")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
            .accessibilityIdentifier("files.target")
            if let target = model.selectedTarget {
                Group {
                    if target.phone {
                        Text("\(target.name) picks up what you send the next time it connects to this phone.")
                    } else if let link = model.links[target.id] {
                        Text("Connected over \(link.label)")
                    } else {
                        Text("\(target.name) is not reachable")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var list: some View {
        List {
            ForEach(files) { entry in
                EntryRow(entry: entry) { name in
                    let url = model.documentURL(name)
                    if FileManager.default.fileExists(atPath: url.path) { preview = url }
                }
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("main.timeline")
    }
}

struct EntryRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    let entry: TimelineEntry
    let openFile: (String) -> Void

    private var sent: Bool { entry.direction == .sent }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: sent ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.title)
                    .lineLimit(entry.kind == .text ? 4 : 1)
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                status
                actions
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        let who = sent ? String(localized: "To \(entry.pcName)") : String(localized: "From \(entry.pcName)")
        return who + " · " + entry.time.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder
    private var status: some View {
        switch entry.state {
        case .active:
            if entry.kind == .gallery {
                ProgressView(value: Double(entry.count), total: Double(max(entry.totalCount, 1)))
                Text(verbatim: entry.progressLine).font(.caption)
                    .accessibilityIdentifier("entry.gallery")
                if !entry.detail.isEmpty {
                    Text(verbatim: entry.detail).font(.caption).foregroundStyle(.secondary)
                }
            } else if entry.kind == .file, !entry.id.hasPrefix(HostModel.sentPrefix) {
                ProgressView(value: Double(entry.bytes), total: Double(max(entry.totalBytes, 1)))
                Text(verbatim: String(localized: "\(formatBytes(entry.bytes)) of \(formatBytes(entry.totalBytes))")).font(.caption)
            } else if entry.detail.isEmpty {
                ProgressView()
            } else {
                Text(verbatim: entry.detail).font(.caption).foregroundStyle(.secondary)
            }
        case .paused:
            Text("Paused").font(.caption)
        case .failed:
            Text(verbatim: failedLine).font(.caption).foregroundStyle(.red)
        case .done:
            if entry.kind == .gallery {
                Text(verbatim: sent ? String(localized: "\(entry.count) sent") : String(localized: "\(entry.count) received")).font(.caption)
                if !entry.detail.isEmpty {
                    Text(verbatim: entry.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var failedLine: String {
        let head = sent ? String(localized: "Not sent") : String(localized: "Not received")
        return entry.detail.isEmpty ? head : head + ": " + entry.detail
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if entry.kind == .text || entry.kind == .link {
                Button("Copy") { UIPasteboard.general.string = entry.title }
            }
            if entry.kind == .link, let url = webAddress {
                Button("Open") { openURL(url) }
            }
            if entry.kind == .file, !sent, entry.state == .done, let name = entry.fileName {
                Button("Open") { openFile(name) }
            }
            if entry.kind == .file, sent, entry.state == .active {
                Button("Stop") { model.stopSending() }
            }
            if entry.kind == .file, sent, entry.localFile != nil, entry.state == .paused || entry.state == .failed {
                Button("Resume") { model.resumeSend(entry.id) }
                    .accessibilityIdentifier("entry.file.resume")
            }
            if entry.kind == .gallery, entry.state == .paused {
                Button("Resume") { model.resumeGallerySync(entry) }
                    .accessibilityIdentifier("entry.gallery.resume")
            }
            if entry.kind == .gallery, entry.state == .active {
                Button("Stop") { model.stopGallery() }
                    .accessibilityIdentifier("entry.gallery.stop")
            }
        }
        .buttonStyle(.borderless)
        .font(.subheadline)
    }

    private var webAddress: URL? {
        guard let url = URL(string: entry.title), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}
#endif
