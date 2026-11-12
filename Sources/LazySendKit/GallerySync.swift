import Foundation

public protocol GalleryLink: UploadAPI, GalleryCheckAPI {}

extension LinkClient: GalleryLink {}

/// A photo or video resource to send. `export` makes a readable file of the original (the phone may have to
/// fetch it from iCloud first) and is called only when the item's turn comes.
public struct GalleryItem: Sendable {
    public var sourceId: String
    public var name: String
    public var mime: String?
    public var modified: Date?
    public var sizeHint: Int64
    public var export: @Sendable () async throws -> ExportedFile

    public init(sourceId: String, name: String, mime: String?, modified: Date?, sizeHint: Int64, export: @escaping @Sendable () async throws -> ExportedFile) {
        self.sourceId = sourceId
        self.name = name
        self.mime = mime
        self.modified = modified
        self.sizeHint = sizeHint
        self.export = export
    }
}

public struct ExportedFile: Sendable {
    public var url: URL
    public var size: Int64
    public var cleanup: @Sendable () -> Void

    public init(url: URL, size: Int64, cleanup: @escaping @Sendable () -> Void) {
        self.url = url
        self.size = size
        self.cleanup = cleanup
    }
}

public struct GalleryProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case looking
        case sending
        case waiting
    }

    public var phase: Phase
    public var count: Int
    public var totalCount: Int
    public var bytes: Int64
    public var totalBytes: Int64
    public var failed: Int
}

public enum GalleryResult: Equatable, Sendable {
    case finished(sent: Int, failed: Int)
    /// The computer no longer knows this phone.
    case forgotten
    case diskFull(String)
}

private final class Wire: @unchecked Sendable {
    private let lock = NSLock()
    private var acked: Int64 = 0
    private var inflight: Int64 = 0
    private var lastReport = Date.distantPast

    func acknowledged(_ offset: Int64) {
        lock.lock()
        acked = offset
        inflight = 0
        lock.unlock()
    }

    func sent(_ bytes: Int64) {
        lock.lock()
        inflight = bytes
        lock.unlock()
    }

    var total: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return acked + inflight
    }

    /// True at most four times a second.
    func due() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if now.timeIntervalSince(lastReport) < 0.25 { return false }
        lastReport = now
        return true
    }
}

/// Sends a gallery: asks the computer which of the items it lacks, then exports, hashes and uploads each one.
/// An item that cannot be read is skipped and counted, not retried; a computer out of reach is waited for.
public final class GallerySync: @unchecked Sendable {
    private let items: [GalleryItem]
    private let awaitReachable: @Sendable () async throws -> GalleryLink?
    private let reconnect: @Sendable () async throws -> GalleryLink
    private let report: @Sendable (GalleryProgress) -> Void
    private let retryDelays: [TimeInterval]
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// `awaitReachable` waits until the computer answers and gives nil when it has forgotten this phone;
    /// `reconnect` is one quick try that throws when the computer is out of reach.
    public init(items: [GalleryItem], awaitReachable: @escaping @Sendable () async throws -> GalleryLink?,
                reconnect: @escaping @Sendable () async throws -> GalleryLink, retryDelays: [TimeInterval] = Uploader.retryDelays,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                report: @escaping @Sendable (GalleryProgress) -> Void) {
        self.items = items
        self.awaitReachable = awaitReachable
        self.reconnect = reconnect
        self.retryDelays = retryDelays
        self.sleep = sleep
        self.report = report
    }

    public func run() async throws -> GalleryResult {
        var progress = GalleryProgress(phase: .looking, count: 0, totalCount: items.count, bytes: 0, totalBytes: 0, failed: 0)
        report(progress)
        guard var link = try await awaitReachable() else { return .forgotten }
        var missing: Set<String>
        while true {
            do {
                missing = Set(try await missingIds(items.map(\.sourceId), using: link))
                break
            } catch let error as LinkError where error.isTransient {
                progress.phase = .waiting
                report(progress)
                guard let again = try await awaitReachable() else { return .forgotten }
                link = again
            }
        }
        let todo = items.filter { missing.contains($0.sourceId) }
        progress.phase = .sending
        progress.count = items.count - todo.count
        progress.totalBytes = todo.reduce(0) { $0 + $1.sizeHint }
        report(progress)

        var sent = 0
        for item in todo {
            let base = progress
            let outcome = try await sendOne(item, link: &link, base: base, progress: &progress)
            switch outcome {
            case .sent: sent += 1
            case .skipped: progress.failed += 1
            case .forgotten: return .forgotten
            case .diskFull(let message): return .diskFull(message)
            }
            if outcome == .sent { progress.count += 1 }
            progress.bytes = base.bytes + item.sizeHint
            report(progress)
        }
        return .finished(sent: sent, failed: progress.failed)
    }

    private enum Outcome: Equatable {
        case sent
        case skipped
        case forgotten
        case diskFull(String)
    }

    private func sendOne(_ item: GalleryItem, link: inout GalleryLink, base: GalleryProgress, progress: inout GalleryProgress) async throws -> Outcome {
        let exported: ExportedFile
        do {
            exported = try await item.export()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .skipped
        }
        defer { exported.cleanup() }
        guard let hash = try? sha256Hex(of: exported.url) else { return .skipped }
        let request = ItemRequest(kind: "file", name: item.name, size: exported.size, mime: item.mime,
                                  modified: item.modified.map { ISO8601DateFormatter().string(from: $0) },
                                  sourceId: item.sourceId, sha256: hash)
        let wire = Wire()
        let report = self.report
        while true {
            let first = link
            var used = false
            let reconnect = self.reconnect
            let uploader = Uploader(retryDelays: retryDelays, sleep: sleep) {
                if !used {
                    used = true
                    return first
                }
                return try await reconnect()
            }
            do {
                _ = try await uploader.send(request, source: FileDataSource(url: exported.url), onProgress: { offset in
                    wire.acknowledged(offset)
                    if wire.due() {
                        var shown = base
                        shown.bytes += wire.total
                        report(shown)
                    }
                }, onBytes: { sent in
                    wire.sent(sent)
                    if wire.due() {
                        var shown = base
                        shown.bytes += wire.total
                        report(shown)
                    }
                })
                return .sent
            } catch let error as LinkError {
                if error.isTransient {
                    progress.phase = .waiting
                    report(progress)
                    guard let again = try await awaitReachable() else { return .forgotten }
                    link = again
                    progress.phase = .sending
                } else if error.code == "diskFull" {
                    return .diskFull(error.localizedDescription)
                } else {
                    return .skipped
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .skipped
            }
        }
    }
}
