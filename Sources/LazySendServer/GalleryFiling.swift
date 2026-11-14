import Foundation
import LazySendKit

extension OutboxEntry {
    /// The asset id of a file that comes from the host's photo library, when it is one this app can keep.
    public var gallerySource: String? {
        GalleryIndex.isValidSourceId(sourceId) ? sourceId : nil
    }

    /// When the asset was taken, if the host said and the date is a plausible one.
    public var takenDate: Date? {
        guard let text = taken, let date = Inbox.parseDate(text),
              (1980...2100).contains(Calendar(identifier: .gregorian).component(.year, from: date)) else { return nil }
        return date
    }

    /// `<host folder>/Gallery/YYYY-MM` for a gallery file, by the day it was taken or else `now`; nil for any other file.
    public func galleryFolder(in hostFolder: URL, now: Date = Date()) -> URL? {
        guard gallerySource != nil else { return nil }
        return hostFolder.appendingPathComponent("Gallery", isDirectory: true)
            .appendingPathComponent(Inbox.month(takenDate ?? now), isDirectory: true)
    }
}
