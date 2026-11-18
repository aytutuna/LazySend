#if os(iOS)
import LazySendKit
import LazySendServer
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SendView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let target = model.selectedTarget {
                form(target)
            } else {
                Text("Nothing paired yet").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(model.selectedTarget.map { String(localized: "Send to \($0.name)") } ?? String(localized: "Send"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func form(_ target: AppModel.Target) -> some View {
        Form {
            Section {
                if let pc = model.pcs.first(where: { $0.id == target.id }) {
                    Button("All photos and videos") { model.startGallerySync(for: pc) }
                        .disabled(model.galleryRunning)
                        .accessibilityIdentifier("send.gallery")
                } else if target.phone, let id = HostedPhones.id(ofTarget: target.id) {
                    feedRows(model.feeds[id], target)
                }
                if let notice = model.notice {
                    Text(notice).foregroundStyle(.red)
                }
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
    }

    @ViewBuilder
    private func feedRows(_ progress: GalleryFeedProgress?, _ target: AppModel.Target) -> some View {
        let running = progress?.done == false
        Button("All photos and videos") { model.startGalleryFeed(for: target) }
            .disabled(running)
            .accessibilityIdentifier("send.gallery")
        if let progress {
            if running {
                Text("\(progress.sent) of \(progress.total) sent to \(target.name)")
                    .accessibilityIdentifier("send.galleryProgress")
                if progress.wait == .storage {
                    Text("Waiting for free storage").foregroundStyle(.secondary)
                } else if progress.wait == .photos {
                    Text("Paused. Lazy Send needs access to your photos.").foregroundStyle(.secondary)
                } else if progress.wait == .outbox {
                    Text("Waiting for \(target.name) to take what is queued").foregroundStyle(.secondary)
                }
                Text("Keep Lazy Send open until it is done.").foregroundStyle(.secondary)
                Button("Stop", role: .destructive) { model.stopGalleryFeed(for: target) }
                    .accessibilityIdentifier("send.galleryStop")
            } else if progress.total == 0 {
                Text("Nothing new to send to \(target.name)").foregroundStyle(.secondary)
            } else if progress.failed > 0 {
                Text("\(progress.sent) sent to \(target.name), \(progress.failed) could not be read").foregroundStyle(.secondary)
            } else {
                Text("All \(progress.sent) photos and videos sent to \(target.name)").foregroundStyle(.secondary)
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
#endif
