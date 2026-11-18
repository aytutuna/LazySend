#if os(iOS)
import LazySendKit

/// Which timeline rows each tab lists: files and photos in Files, texts and links in Clipboard.
enum EntryFilter {
    static func files(_ entries: [TimelineEntry]) -> [TimelineEntry] {
        entries.filter { $0.kind == .file || $0.kind == .gallery }
    }

    static func texts(_ entries: [TimelineEntry]) -> [TimelineEntry] {
        entries.filter { $0.kind == .text || $0.kind == .link }
    }
}
#endif
