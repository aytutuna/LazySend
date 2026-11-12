import Foundation

public enum LinkProtocol {
    public static let version = 1
    public static let defaultPort = 52734
    public static let serviceType = "_lazysend._tcp"
    public static let txtIdKey = "id"
    public static let chunkBytes = 8 * 1024 * 1024
    public static let galleryBatch = 1000
    public static let maxOutboxWait = 25
    public static let maxTextBytes = 1024 * 1024
    public static let maxAddresses = 8
}

public struct PairRequest: Codable, Equatable {
    public var token: String
    public var phoneId: String
    public var phoneName: String
    public var platform: String
    public var appVersion: String

    public init(token: String, phoneId: String, phoneName: String, platform: String = "ios", appVersion: String) {
        self.token = token
        self.phoneId = phoneId
        self.phoneName = phoneName
        self.platform = platform
        self.appVersion = appVersion
    }
}

public struct PairResponse: Codable, Equatable {
    public var protocolVersion: Int
    public var desktopId: String
    public var desktopName: String
    public var deviceSecret: String
}

public struct Health: Codable, Equatable {
    public var service: String
    public var protocolVersion: Int
    public var paired: Bool?
}

public struct Hello: Decodable, Equatable {
    public var protocolVersion: Int
    public var desktopId: String
    public var desktopName: String
    public var maxChunkBytes: Int64
    public var addresses: [String]

    public init(protocolVersion: Int, desktopId: String, desktopName: String, maxChunkBytes: Int64 = 64 * 1024 * 1024, addresses: [String] = []) {
        self.protocolVersion = protocolVersion
        self.desktopId = desktopId
        self.desktopName = desktopName
        self.maxChunkBytes = maxChunkBytes
        self.addresses = addresses
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        desktopId = try c.decode(String.self, forKey: .desktopId)
        desktopName = try c.decode(String.self, forKey: .desktopName)
        maxChunkBytes = try c.decodeIfPresent(Int64.self, forKey: .maxChunkBytes) ?? 64 * 1024 * 1024
        addresses = try c.decodeIfPresent([String].self, forKey: .addresses) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, desktopId, desktopName, maxChunkBytes, addresses
    }
}

public struct ItemRequest: Codable, Equatable {
    public var kind: String
    public var text: String?
    public var url: String?
    public var name: String?
    public var size: Int64?
    public var mime: String?
    public var modified: String?
    public var sourceId: String?
    public var sha256: String?

    public init(kind: String, text: String? = nil, url: String? = nil, name: String? = nil, size: Int64? = nil,
                mime: String? = nil, modified: String? = nil, sourceId: String? = nil, sha256: String? = nil) {
        self.kind = kind
        self.text = text
        self.url = url
        self.name = name
        self.size = size
        self.mime = mime
        self.modified = modified
        self.sourceId = sourceId
        self.sha256 = sha256
    }
}

public struct ItemState: Codable, Equatable {
    public var id: String
    public var offset: Int64
    public var done: Bool
    public var duplicate: Bool?

    public init(id: String, offset: Int64, done: Bool, duplicate: Bool? = nil) {
        self.id = id
        self.offset = offset
        self.done = done
        self.duplicate = duplicate
    }
}

struct GalleryCheckRequest: Encodable {
    var ids: [String]
}

struct GalleryCheckReply: Decodable {
    var missing: [String]
}

public struct OutboxEntry: Codable, Equatable {
    public var id: String
    public var kind: String
    public var text: String?
    public var url: String?
    public var name: String?
    public var size: Int64?
    public var mime: String?

    public init(id: String, kind: String, text: String? = nil, url: String? = nil, name: String? = nil, size: Int64? = nil, mime: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.url = url
        self.name = name
        self.size = size
        self.mime = mime
    }
}

public struct OutboxReply: Decodable, Equatable {
    public var items: [OutboxEntry]
    public var more: Bool

    public init(items: [OutboxEntry] = [], more: Bool = false) {
        self.items = items
        self.more = more
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([OutboxEntry].self, forKey: .items) ?? []
        more = try c.decodeIfPresent(Bool.self, forKey: .more) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case items, more
    }
}

struct ApiError: Decodable {
    var error: String
    var message: String?
    var offset: Int64?
}

/// Why a request to the computer failed: its error answer (the codes are the stable ones in CONTRACTS.md),
/// or a connection that did not work.
public enum LinkError: Error, LocalizedError, Equatable {
    case refused(status: Int, code: String, message: String, offset: Int64?)
    case network(String)
    case wrongCertificate
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .refused(_, _, let message, _): return message
        case .network(let reason): return reason
        case .wrongCertificate: return "The computer's certificate is not the one in the pairing code."
        case .badResponse: return "The computer sent an answer this app cannot read."
        }
    }

    public var status: Int? {
        if case .refused(let status, _, _, _) = self { return status }
        return nil
    }

    public var code: String? {
        if case .refused(_, let code, _, _) = self { return code }
        return nil
    }

    /// The computer asked for a pause (rate limit) or is still finishing the last request for this file.
    public var isBusy: Bool {
        if case .refused(let status, let code, _, _) = self { return status == 429 || code == "busy" || code == "rateLimited" }
        return false
    }

    /// Worth trying again after a wait: no connection, or the computer asked for a pause.
    public var isTransient: Bool {
        if case .network = self { return true }
        return isBusy
    }
}
