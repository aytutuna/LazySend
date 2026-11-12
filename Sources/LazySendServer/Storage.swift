import Foundation

/// Where the app keeps its files. Everything but the received files lives under `root`.
public struct SendPaths: Sendable {
    public var root: URL
    public var defaultReceiveRoot: URL

    public init(root: URL, defaultReceiveRoot: URL) {
        self.root = root
        self.defaultReceiveRoot = defaultReceiveRoot
    }

    var devicesFile: URL { root.appendingPathComponent("devices.json") }
    var settingsFile: URL { root.appendingPathComponent("settings.json") }
    var historyFile: URL { root.appendingPathComponent("history.json") }
    var incomingDirectory: URL { root.appendingPathComponent("incoming", isDirectory: true) }
    var indexDirectory: URL { root.appendingPathComponent("index", isDirectory: true) }
    var outboxFile: URL { root.appendingPathComponent("outbox.json") }
}

struct SettingsFile: Codable {
    var receiveFolder = ""
    var receiveBookmark: Data?
    var copyTextToClipboard = false
}

public final class SendSettings: @unchecked Sendable {
    private let paths: SendPaths
    private let lock = NSLock()
    private var file: SettingsFile

    public init(paths: SendPaths) {
        self.paths = paths
        file = JsonFile.load(SettingsFile.self, from: paths.settingsFile) ?? SettingsFile()
    }

    /// The folder received files go under, one folder per phone inside it.
    public var receiveRoot: URL {
        lock.lock()
        defer { lock.unlock() }
        return file.receiveFolder.isEmpty ? paths.defaultReceiveRoot : URL(fileURLWithPath: file.receiveFolder, isDirectory: true)
    }

    public var receiveBookmark: Data? {
        lock.lock()
        defer { lock.unlock() }
        return file.receiveBookmark
    }

    public var isDefaultReceiveRoot: Bool {
        lock.lock()
        defer { lock.unlock() }
        return file.receiveFolder.isEmpty
    }

    /// A folder the user chose, with the bookmark that opens it again after a restart; nil for the default.
    public func setReceiveRoot(_ folder: URL?, bookmark: Data? = nil) {
        lock.lock()
        defer { lock.unlock() }
        file.receiveFolder = folder?.path ?? ""
        file.receiveBookmark = folder == nil ? nil : bookmark
        JsonFile.save(file, to: paths.settingsFile)
    }

    public var copyTextToClipboard: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return file.copyTextToClipboard
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            file.copyTextToClipboard = newValue
            JsonFile.save(file, to: paths.settingsFile)
        }
    }
}

/// JSON files written whole through a temporary file, so a crash leaves the old one or the new one.
enum JsonFile {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The file's value; nil when there is none, and a file that does not read is kept as .bad.
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let value = try? decoder().decode(T.self, from: data) { return value }
        let bad = URL(fileURLWithPath: url.path + ".bad")
        try? FileManager.default.removeItem(at: bad)
        try? FileManager.default.moveItem(at: url, to: bad)
        return nil
    }

    @discardableResult
    static func save<T: Encodable>(_ value: T, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temp = URL(fileURLWithPath: url.path + ".tmp")
            try encoder().encode(value).write(to: temp)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
            return true
        } catch {
            return false
        }
    }
}

/// Names from phones made safe as file and folder names.
enum FileNames {
    static let maxBytes = 240

    /// A name that can be created: separators, ':' and control characters become '_', leading and trailing dots
    /// and spaces go, and the stem is cut so the whole is at most `maxBytes` UTF-8 bytes (room for " (2)").
    static func clean(_ name: String?, fallback: String = "file") -> String {
        var text = ""
        for scalar in (name ?? "").unicodeScalars {
            let bad = scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) || "/\:".unicodeScalars.contains(scalar)
            text.unicodeScalars.append(bad ? "_" : scalar)
        }
        var cleaned = text.trimmingCharacters(in: .whitespaces)
        while cleaned.hasSuffix(".") || cleaned.hasSuffix(" ") { cleaned.removeLast() }
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty { cleaned = fallback }
        let ns = cleaned as NSString
        var ext = ns.pathExtension.isEmpty ? "" : "." + ns.pathExtension
        var stem = ext.isEmpty ? cleaned : ns.deletingPathExtension
        if stem.isEmpty { (stem, ext) = (cleaned, "") }
        if ext.utf8.count > 32 { ext = "" }
        while stem.utf8.count + ext.utf8.count > maxBytes { stem.removeLast() }
        while stem.hasSuffix(".") || stem.hasSuffix(" ") { stem.removeLast() }
        return (stem.isEmpty ? fallback : stem) + ext
    }

    /// The first of `name`, `name (2)`, `name (3)`... that does not exist in `directory`.
    static func unique(in directory: URL, name: String) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension.isEmpty ? "" : "." + ns.pathExtension
        let stem = ext.isEmpty ? name : ns.deletingPathExtension
        var candidate = name
        var n = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(stem) (\(n))\(ext)"
            n += 1
        }
        return candidate
    }
}
