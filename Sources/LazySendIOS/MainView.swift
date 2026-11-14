#if os(iOS)
import LazySendKit
import QuickLook
import SwiftUI
import UIKit

enum Route: Hashable {
    case send
    case pair
    case pcs
    case receive
}

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var timeline: Timeline
    let go: (Route) -> Void
    @State private var preview: URL?

    var body: some View {
        Group {
            if model.targets.isEmpty {
                empty
            } else {
                VStack(spacing: 0) {
                    header
                    list
                }
            }
        }
        .navigationTitle("Lazy Send")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !model.targets.isEmpty {
                    Button("Devices") { go(.pcs) }
                        .accessibilityIdentifier("main.pcs")
                }
            }
        }
        .quickLookPreview($preview)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.targets.count > 1 {
                Picker("Send to", selection: Binding(get: { model.selectedTarget?.id ?? "" }, set: { model.select($0) })) {
                    ForEach(model.targets) { target in
                        Text(target.name).tag(target.id)
                    }
                }
                .pickerStyle(.menu)
            }
            if let target = model.selectedTarget {
                Text(target.name).font(.headline)
                if target.phone {
                    Text("\(target.name) picks up what you send the next time it connects to this phone.")
                } else if let link = model.links[target.id] {
                    Text("Connected over \(link.label)")
                } else {
                    Text("\(target.name) is not reachable")
                }
                HStack {
                    Button("Send") { go(.send) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("main.send")
                    Button("Receive") { go(.receive) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("main.receive")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.accentColor.opacity(0.12))
    }

    private var list: some View {
        List {
            if timeline.entries.isEmpty {
                Text("What you send and receive shows up here.").foregroundStyle(.secondary)
            }
            ForEach(timeline.entries) { entry in
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

private struct EntryRow: View {
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
