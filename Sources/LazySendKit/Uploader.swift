import CryptoKit
import Foundation

public protocol DataSource: Sendable {
    /// Up to `length` bytes from `offset`; fewer only at the end of the data.
    func read(offset: Int64, length: Int) throws -> Data
}

public struct FileDataSource: DataSource {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func read(offset: Int64, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: length) ?? Data()
    }
}

public func sha256Hex(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty {
        hasher.update(data: block)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// The file being sent cannot be read as it was sized; trying again will not help.
public enum UploadSourceError: Error, LocalizedError {
    case shorterThanSized

    public var errorDescription: String? { "The file is shorter than it was." }
}

public struct UploadResult: Equatable {
    public var duplicate: Bool
}

/// Sends one file in chunks and carries on after drops: it asks the computer where the file stands and
/// continues from the offset it is told, never from what it sent. One instance per file.
public final class Uploader: @unchecked Sendable {
    public static let retryDelays: [TimeInterval] = [1, 2, 4, 8, 15, 30, 30, 30]

    private let connect: () async throws -> UploadAPI
    private let chunkBytes: Int64
    private let retryDelays: [TimeInterval]
    private let sleep: (TimeInterval) async throws -> Void
    private var client: UploadAPI?
    private var resumeItemId: String?

    /// `connect` gives a client for the computer, a new one when asked again after a failure. With a
    /// `resumeItemId` from an earlier run the upload carries on from where the computer says that item stands;
    /// when the computer no longer has it, the file is announced again.
    public init(chunkBytes: Int = LinkProtocol.chunkBytes, retryDelays: [TimeInterval] = Uploader.retryDelays, resumeItemId: String? = nil,
                sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                connect: @escaping () async throws -> UploadAPI) {
        self.connect = connect
        self.chunkBytes = Int64(chunkBytes)
        self.retryDelays = retryDelays
        self.resumeItemId = resumeItemId
        self.sleep = sleep
    }

    /// `onProgress` gets the bytes the computer is known to have, and `onBytes` the bytes of the chunk on
    /// the wire as they go. `onItem` gets the computer's id for the file as soon as it is known. Throws the
    /// last connection error once the computer has stayed out of reach.
    public func send(_ request: ItemRequest, source: DataSource, onItem: @escaping (String) -> Void = { _ in },
                     onProgress: @escaping @Sendable (Int64) -> Void = { _ in },
                     onBytes: @escaping @Sendable (Int64) -> Void = { _ in }) async throws -> UploadResult {
        guard let size = request.size else { throw LinkError.badResponse }
        client = try await connect()
        var restarted = false
        var state = try await begin(request, onItem: onItem)
        if state.duplicate == true { return UploadResult(duplicate: true) }
        onProgress(state.offset)
        while !state.done {
            do {
                state = try await sendChunk(state, length: min(chunkBytes, size - state.offset), source: source, onBytes: onBytes)
            } catch let error as LinkError {
                if error.code == "offsetMismatch", let offset = error.offset {
                    state = ItemState(id: state.id, offset: offset, done: false)
                } else if (error.code == "hashMismatch" || error.code == "notFound") && !restarted {
                    restarted = true
                    state = try await begin(request, onItem: onItem)
                } else {
                    throw error
                }
            }
            onProgress(state.offset)
        }
        return UploadResult(duplicate: false)
    }

    private func begin(_ request: ItemRequest, onItem: (String) -> Void) async throws -> ItemState {
        var failures = 0
        while true {
            do {
                let state: ItemState
                if let id = resumeItemId {
                    do {
                        state = try await api().itemState(id)
                        resumeItemId = nil
                    } catch let error as LinkError where error.code == "notFound" {
                        resumeItemId = nil
                        state = try await api().postItem(request)
                    }
                } else {
                    state = try await api().postItem(request)
                }
                if state.duplicate != true, !state.id.isEmpty { onItem(state.id) }
                return state
            } catch let error as LinkError where error.isTransient {
                failures = try await backOff(failures, error)
            }
        }
    }

    private func sendChunk(_ state: ItemState, length: Int64, source: DataSource, onBytes: @escaping @Sendable (Int64) -> Void) async throws -> ItemState {
        let data = try source.read(offset: state.offset, length: Int(max(length, 0)))
        if Int64(data.count) != max(length, 0) { throw UploadSourceError.shorterThanSized }
        var failures = 0
        while true {
            do {
                return try await api().putChunk(id: state.id, offset: state.offset, data: data, onBytes: onBytes)
            } catch let error as LinkError where error.isTransient {
                failures = try await backOff(failures, error)
                // The chunk may have landed before the answer was lost, so ask before sending it again.
                do {
                    return try await api().itemState(state.id)
                } catch let again as LinkError where again.isTransient {
                    continue
                }
            }
        }
    }

    private func api() throws -> UploadAPI {
        guard let client = client else { throw LinkError.network("Not connected.") }
        return client
    }

    private func backOff(_ failures: Int, _ cause: LinkError) async throws -> Int {
        if failures >= retryDelays.count { throw cause }
        try await sleep(retryDelays[failures])
        if let fresh = try? await connect() { client = fresh }
        return failures + 1
    }
}

public func missingIds(_ ids: [String], using api: GalleryCheckAPI) async throws -> [String] {
    var missing: [String] = []
    var start = 0
    while start < ids.count {
        let end = min(start + LinkProtocol.galleryBatch, ids.count)
        missing += try await api.galleryMissing(Array(ids[start..<end]))
        start = end
    }
    return missing
}
