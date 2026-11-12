#if os(iOS)
import Foundation
import LazySendKit

extension TimelineEntry {
    static let galleryPrefix = "gallery-"

    static func galleryId(_ pcId: String) -> String {
        galleryPrefix + pcId
    }

    var progressLine: String {
        String(localized: "\(count) of \(totalCount) · \(formatBytes(bytes)) of \(formatBytes(totalBytes))")
    }

    /// While the computer is out of reach the entry stays active, so its progress and Stop button stay on screen.
    mutating func apply(_ progress: GalleryProgress, pcName: String, link: LinkKind?) {
        state = .active
        totalCount = progress.totalCount
        if progress.phase != .looking {
            count = progress.count
            bytes = progress.bytes
            totalBytes = progress.totalBytes
        }
        switch progress.phase {
        case .looking: detail = String(localized: "Looking for what is new")
        case .sending: detail = link?.label ?? ""
        case .waiting: detail = String(localized: "Waiting for \(pcName)")
        }
    }

    mutating func finish(_ result: GalleryResult, pcName: String) {
        switch result {
        case .finished(_, let failed):
            state = .done
            time = Date()
            // Every item the computer lacked was either sent or counted as failed.
            count = totalCount - failed
            bytes = totalBytes
            detail = failed > 0 ? String(localized: "\(failed) could not be sent") : ""
        case .forgotten:
            state = .failed
            detail = String(localized: "\(pcName) no longer knows this phone.")
        case .diskFull(let message):
            state = .failed
            detail = message
        }
    }
}

/// The computer whose gallery sync was cut off, when the user has not stopped it. A paused entry is what the
/// timeline makes of one that was active when the app went away.
func galleryToResume(_ entries: [TimelineEntry], pending: Bool) -> String? {
    guard pending else { return nil }
    guard let entry = entries.first(where: { $0.kind == .gallery && $0.state == .paused && $0.id.hasPrefix(TimelineEntry.galleryPrefix) }) else {
        return nil
    }
    return String(entry.id.dropFirst(TimelineEntry.galleryPrefix.count))
}
#endif
