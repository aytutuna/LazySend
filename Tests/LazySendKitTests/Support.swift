import Foundation
@testable import LazySendKit

final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    var failsSaves = false
    var failsLoads = false

    func save(_ data: Data, for key: String) throws {
        if failsSaves { throw CocoaError(.fileWriteUnknown) }
        lock.lock()
        items[key] = data
        lock.unlock()
    }

    func load(for key: String) throws -> Data? {
        if failsLoads { throw CocoaError(.fileReadUnknown) }
        lock.lock()
        defer { lock.unlock() }
        return items[key]
    }

    func delete(for key: String) throws {
        lock.lock()
        items[key] = nil
        lock.unlock()
    }
}

func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lazysend-tests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

func randomFile(in folder: URL, bytes: Int, name: String = "payload.bin") throws -> (url: URL, data: Data) {
    var generator = SystemRandomNumberGenerator()
    let data = Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &generator) })
    let url = folder.appendingPathComponent(name)
    try data.write(to: url)
    return (url, data)
}
