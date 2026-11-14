import Foundation
import LazySendKit
import SwiftUI
import UniformTypeIdentifiers

enum ShareState: Equatable {
    case loading
    case ready
    case sending
    case sent
    case saved(String)
    case failed(String, retry: Bool)
    case notPaired
}

private enum ShareError: Error, LocalizedError {
    case unreadable
    case unreachable(String)
    case forgotten(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: return String(localized: "Lazy Send could not read what you shared.")
        case .unreachable(let name): return String(localized: "\(name) is not reachable")
        case .forgotten(let name): return String(localized: "\(name) no longer knows this phone.")
        }
    }
}

/// One thing that was shared: a note (the request is ready) or a file copied to a temp folder of its own.
private struct Piece {
    var label: String
    var request: ItemRequest?
    var file: URL?
    var name = ""
    var mime: String?
    var modified: Date?
    var size: Int64 = 0
}

/// A computer to send to, or a phone paired with this one as its host (its id starts with `HostedPhones.prefix`).
struct ShareTarget: Identifiable, Equatable {
    var id: String
    var name: String
}

@MainActor
final class ShareModel: ObservableObject {
    @Published private(set) var state = ShareState.loading
    @Published private(set) var progress = 0.0
    @Published var chosen: String
    @Published private(set) var summary = ""
    let targets: [ShareTarget]

    private let store: PcStore
    private let connector: PcConnector
    private let queue: ShareQueue
    private let providers: [NSItemProvider]
    private let finish: () -> Void
    private let cancel: () -> Void
    private var pieces: [Piece] = []

    init(providers: [NSItemProvider], finish: @escaping () -> Void, cancel: @escaping () -> Void) {
        let folder = AppGroup.folder()
        store = PcStore(file: folder.appendingPathComponent("pcs.json"), secrets: ShareSecrets(), repairs: false)
        connector = PcConnector(store: store, discovery: .live)
        queue = ShareQueue(root: folder)
        targets = store.pcs.map { ShareTarget(id: $0.id, name: $0.name) }
            + HostedPhones.read(in: AppGroup.hostFolder()).map { ShareTarget(id: HostedPhones.target($0.id), name: $0.name) }
        chosen = targets.first?.id ?? ""
        self.providers = providers
        self.finish = finish
        self.cancel = cancel
        ShareModel.removeStaleCopies()
        if targets.isEmpty {
            state = .notPaired
        } else {
            Task { await load() }
        }
    }

    // A share the system ended early leaves its copy behind; an hour is longer than any send from here takes.
    private static func removeStaleCopies() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let folders = (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: keys)) ?? []
        for folder in folders where folder.lastPathComponent.hasPrefix("lazysend-share-") {
            let changed = (try? folder.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? Date.distantPast
            if Date().timeIntervalSince(changed) > 3600 { try? fm.removeItem(at: folder) }
        }
    }

    var chosenName: String {
        targets.first { $0.id == chosen }?.name ?? ""
    }

    func close() {
        discardFiles()
        cancel()
    }

    func done() {
        discardFiles()
        finish()
    }

    func send() {
        Task { await run() }
    }

    func sendLater() {
        guard targets.contains(where: { $0.id == chosen }) else { return }
        save(for: chosen, message: String(localized: "Saved. Lazy Send will send it when you open the app."))
    }

    private func load() async {
        var found: [Piece] = []
        var problem: Error?
        for provider in providers {
            do {
                found.append(try await piece(from: provider))
            } catch {
                problem = error
            }
        }
        pieces = found
        if found.isEmpty {
            state = .failed((problem ?? ShareError.unreadable).localizedDescription, retry: false)
            return
        }
        summary = found.map(\.label).joined(separator: ", ")
        state = .ready
        // With one computer there is nothing to choose, so it goes at once.
        if targets.count == 1 { await run() }
    }

    private func piece(from provider: NSItemProvider) async throws -> Piece {
        let ids = provider.registeredTypeIdentifiers
        switch ShareRouting.kind(of: ids) {
        case .text:
            let text = try await loadText(provider)
            return Piece(label: String(text.prefix(40)), request: try ItemRequest.note(text))
        case .link:
            let address = try await loadURL(provider).absoluteString
            return Piece(label: address, request: try ItemRequest.note(address))
        case .file:
            let file = try await loadFile(provider, type: fileType(ids))
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return Piece(label: file.lastPathComponent, file: file, name: file.lastPathComponent,
                         mime: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType,
                         modified: values?.contentModificationDate, size: Int64(values?.fileSize ?? 0))
        }
    }

    // The first type that is the content itself; an address to a file would give the address, not the file.
    private func fileType(_ ids: [String]) -> String {
        let found = ids.first { id in
            guard let type = UTType(id) else { return false }
            return type.conforms(to: .data) && !type.conforms(to: .url)
        }
        return found ?? UTType.item.identifier
    }

    private func loadText(_ provider: NSItemProvider) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, error in
                if let text = text {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: error ?? ShareError.unreadable)
                }
            }
        }
    }

    private func loadURL(_ provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url = url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? ShareError.unreadable)
                }
            }
        }
    }

    // The system deletes its file when the handler returns, so the copy is made inside it.
    private func loadFile(_ provider: NSItemProvider, type: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url = url else {
                    continuation.resume(throwing: error ?? ShareError.unreadable)
                    return
                }
                do {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lazysend-share-" + UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let copy = folder.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func run() async {
        guard !pieces.isEmpty else { return }
        // A phone paired with this one only connects while the app is open, so there is nothing to send to now.
        if HostedPhones.id(ofTarget: chosen) != nil {
            save(for: chosen, message: String(localized: "Saved. Lazy Send will pass it on when you open the app and \(chosenName) connects."))
            return
        }
        guard let pc = store.get(chosen) else { return }
        if !ShareRouting.sendsDirectly(sizes: pieces.map(\.size)) {
            save(for: chosen, message: String(localized: "Too big to send from here. It is saved and Lazy Send will send it when you open the app."))
            return
        }
        state = .sending
        progress = 0
        do {
            try await sendNow(to: pc)
            state = .sent
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            done()
        } catch {
            state = .failed(error.localizedDescription, retry: true)
        }
    }

    private func sendNow(to pc: PairedPc) async throws {
        let reached: Reached
        switch await connector.connect(pc, userAction: true) {
        case .reached(let found): reached = found
        case .unreachable: throw ShareError.unreachable(pc.name)
        case .forgotten: throw ShareError.forgotten(pc.name)
        }
        let total = Double(pieces.reduce(0) { $0 + max($1.size, 1) })
        var finished = 0.0
        // What went is dropped from the list, so trying again sends only the rest.
        while let piece = pieces.first {
            if let request = piece.request {
                _ = try await reached.client.postItem(request)
            } else if let file = piece.file {
                let base = finished
                try await upload(piece, file: file, using: reached, pc: pc) { [weak self] sent in
                    Task { @MainActor in self?.progress = (base + Double(sent)) / total }
                }
                try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            }
            pieces.removeFirst()
            finished += Double(max(piece.size, 1))
            progress = finished / total
        }
    }

    private func upload(_ piece: Piece, file: URL, using reached: Reached, pc: PairedPc, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        let request = try await Task.detached {
            try ItemRequest.file(at: file, name: piece.name, mime: piece.mime, modified: piece.modified)
        }.value
        let connector = self.connector
        var used = false
        let uploader = Uploader(retryDelays: [1, 2, 4]) { () async throws -> UploadAPI in
            if !used {
                used = true
                return reached.client
            }
            guard let again = await connector.connect(pc, search: false).reached else { throw ShareError.unreachable(pc.name) }
            return again.client
        }
        _ = try await uploader.send(request, source: FileDataSource(url: file), onBytes: onBytes)
    }

    private func save(for target: String, message: String) {
        do {
            while let piece = pieces.first {
                let id = UUID().uuidString.lowercased()
                if let request = piece.request {
                    try queue.add(QueuedItem(id: id, pcId: target, kind: request.kind, text: request.text, url: request.url))
                } else if let file = piece.file {
                    try queue.add(QueuedItem(id: id, pcId: target, kind: "file", name: piece.name, mime: piece.mime, modified: piece.modified),
                                  file: file, move: true)
                    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                }
                pieces.removeFirst()
            }
            state = .saved(message)
        } catch {
            state = .failed(error.localizedDescription, retry: false)
        }
    }

    private func discardFiles() {
        for piece in pieces {
            if let file = piece.file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        }
        pieces = []
    }
}
