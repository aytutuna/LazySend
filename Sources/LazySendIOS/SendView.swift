#if os(iOS)
import LazySendKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SendView: View {
    @EnvironmentObject private var model: AppModel
    @State private var text = ""
    @State private var failure: String?
    @State private var importing = false
    @State private var picks: [PhotosPickerItem] = []

    var body: some View {
        Group {
            if let pc = model.selected {
                form(pc)
            } else {
                Text("Nothing paired yet").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(model.selected.map { String(localized: "Send to \($0.name)") } ?? String(localized: "Send"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func form(_ pc: PairedPc) -> some View {
        Form {
            Section {
                TextField("Type or paste text or a link", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .accessibilityIdentifier("send.text")
                Button("Send text") { sendText(to: pc) }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("send.textButton")
                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
            }
            Section {
                Button("Pick files") { importing = true }
                    .accessibilityIdentifier("send.files")
                PhotosPicker(selection: $picks, matching: .any(of: [.images, .videos])) {
                    Text("Pick photos")
                }
                .accessibilityIdentifier("send.photos")
                Button("All photos and videos") { model.startGallerySync(for: pc) }
                    .disabled(model.galleryRunning)
                    .accessibilityIdentifier("send.gallery")
                if model.photoNotice == .limited {
                    Text("Only the photos you allowed are sent.").foregroundStyle(.secondary)
                    Button("Allow all") { openSettings() }
                        .accessibilityIdentifier("send.photoSettings")
                }
                if model.photoNotice == .denied {
                    Text("Lazy Send needs access to your photos to send them.").foregroundStyle(.secondary)
                    Button("Open Settings") { openSettings() }
                        .accessibilityIdentifier("send.photoSettings")
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                model.sendFiles(urls, to: pc, scoped: true)
            }
        }
        .onChange(of: picks) { _, items in
            guard !items.isEmpty else { return }
            picks = []
            Task { @MainActor in
                var urls: [URL] = []
                for item in items {
                    if let media = try? await item.loadTransferable(type: PickedMedia.self) { urls.append(media.url) }
                }
                model.sendFiles(urls, to: pc)
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    private func sendText(to pc: PairedPc) {
        do {
            try model.sendNote(text, to: pc)
            text = ""
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}
#endif
