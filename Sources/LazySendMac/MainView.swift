#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var compose = ""
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: 270)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                header
                timeline
                composeBar
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
        .frame(minWidth: 760, minHeight: 480)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 3).padding(6).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            AppModel.fileURLs(in: providers) { model.sendFiles($0) }
            return true
        }
        .onPasteCommand(of: [.fileURL, .image, .plainText]) { _ in model.sendPasteboard() }
        .sheet(isPresented: Binding(get: { model.pairing != nil }, set: { if !$0 { model.closePairing() } })) {
            PairSheet(model: model)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.targetTitle).font(.title2.weight(.semibold)).lineLimit(1)
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var timeline: some View {
        ZStack {
            if model.timeline.isEmpty {
                Text("Nothing yet. What your phone sends shows up here, and so does what you send to it.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.timeline) { row in
                            TimelineCard(row: row, model: model)
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var composeBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $compose)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(height: 64)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                if compose.isEmpty {
                    Text("Type or paste text or a link. Drop files anywhere in this window.")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            Button {
                chooseFiles()
            } label: {
                Label("Send files", systemImage: "doc.badge.plus")
            }
            Button("Send") { send() }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(compose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func send() {
        if model.sendText(compose) { compose = "" }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK { model.sendFiles(panel.urls) }
    }
}

private struct Sidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Lazy Send").font(.title3.weight(.semibold))
            Text("Phones").font(.subheadline.weight(.semibold)).padding(.top, 20).padding(.bottom, 8)
            if model.phones.isEmpty {
                Text("No phone is paired yet. Pair one to send things between it and this Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.phones) { phone in
                        PhoneButton(phone: phone, selected: phone.id == model.selectedPhoneId, select: { model.selectedPhoneId = phone.id },
                                    remove: { model.remove(phone: phone.id) })
                    }
                }
            }
            Spacer(minLength: 8)
            Button {
                Task { await model.beginPairing() }
            } label: {
                Label("Pair a phone", systemImage: "qrcode").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 12)
            if !model.status.isEmpty {
                Text(model.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct PhoneButton: View {
    let phone: PhoneRow
    let selected: Bool
    let select: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(phone.name).fontWeight(.semibold).lineLimit(1)
                if !phone.lastSeen.isEmpty {
                    Text(phone.lastSeen).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: remove) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Remove this phone")
                .accessibilityLabel("Remove this phone")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
}

private struct TimelineCard: View {
    let row: TimelineRow
    let model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 4) {
                Text(row.heading).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                if row.kind == .text || row.kind == .link, let text = row.text {
                    Text(text).lineLimit(6).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Text(row.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                if row.canCopy {
                    Button("Copy") { model.copy(row.text ?? "") }
                }
                if row.canOpen {
                    Button("Open") { open() }
                }
                if row.canShowInFinder, let url = row.fileURL {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                if row.canCancel {
                    Button("Cancel") { model.cancel(row) }
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
    }

    @ViewBuilder
    private var leading: some View {
        if row.kind == .file, let url = row.fileURL {
            Thumbnail(url: url)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
        }
    }

    private var symbol: String {
        switch row.kind {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .file: return "doc"
        case .gallery: return "photo.on.rectangle"
        }
    }

    private func open() {
        if row.kind == .link, let text = row.text, let url = URL(string: text) {
            NSWorkspace.shared.open(url)
        } else if let url = row.fileURL {
            NSWorkspace.shared.open(url)
        }
    }
}

extension AppModel {
    /// The file addresses a drop carries, handed over once all of them have been read.
    static func fileURLs(in providers: [NSItemProvider], then done: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let found = urls
            Task { @MainActor in done(found) }
        }
    }
}
#endif
