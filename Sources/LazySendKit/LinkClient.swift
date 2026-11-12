import Foundation

public struct Endpoint: Hashable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

public struct Credentials: Sendable {
    public var deviceId: String
    public var secret: String

    public init(deviceId: String, secret: String) {
        self.deviceId = deviceId
        self.secret = secret
    }
}

public protocol UploadAPI: Sendable {
    func postItem(_ item: ItemRequest) async throws -> ItemState
    func itemState(_ id: String) async throws -> ItemState
    /// Sends `data` at `offset`; `onBytes` gets how much of it has gone out so far.
    func putChunk(id: String, offset: Int64, data: Data, onBytes: @escaping @Sendable (Int64) -> Void) async throws -> ItemState
}

public protocol GalleryCheckAPI: Sendable {
    func galleryMissing(_ ids: [String]) async throws -> [String]
}

public protocol OutboxAPI: Sendable {
    func outbox(wait: Int) async throws -> OutboxReply
    /// Opens the file of an outbox item from `from`. `onStart` sees the status (200 or 206) and the file's full
    /// size (-1 when unknown) before any byte; `sink` gets the bytes.
    func download(id: String, from: Int64, onStart: @escaping (Int, Int64) throws -> Void, sink: @escaping (Data) throws -> Void) async throws
    func acknowledge(_ id: String) async throws
}

/// One computer at one address, over the pinned session. The computer closes after every answer, so each
/// call is a connection of its own.
public final class LinkClient: UploadAPI, GalleryCheckAPI, OutboxAPI, @unchecked Sendable {
    public let endpoint: Endpoint
    private let session: PinnedSession
    private let credentials: Credentials?

    public init(endpoint: Endpoint, session: PinnedSession, credentials: Credentials?) {
        self.endpoint = endpoint
        self.session = session
        self.credentials = credentials
    }

    public convenience init(endpoint: Endpoint, pin: Data, credentials: Credentials? = nil) {
        self.init(endpoint: endpoint, session: PinnedSession(pin: pin), credentials: credentials)
    }

    static func url(_ endpoint: Endpoint, path: String, query: [String: String] = [:]) -> URL? {
        var host = endpoint.host
        if host.contains(":") && !host.hasPrefix("[") { host = "[" + host + "]" }
        var text = "https://\(host):\(endpoint.port)\(path)"
        if !query.isEmpty {
            text += "?" + query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        }
        return URL(string: text)
    }

    private func makeRequest(_ method: String, _ path: String, query: [String: String] = [:], timeout: TimeInterval = 30,
                         authenticated: Bool = true) throws -> URLRequest {
        guard let url = LinkClient.url(endpoint, path: path, query: query) else { throw LinkError.network("Bad address \(endpoint.host).") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        if authenticated, let credentials = credentials {
            request.setValue(credentials.deviceId, forHTTPHeaderField: "X-Device-Id")
            request.setValue("Bearer " + credentials.secret, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func json<T: Decodable>(_ type: T.Type, _ request: URLRequest, body: Encodable? = nil) async throws -> T {
        var request = request
        var data: Data?
        if let body = body {
            data = try JSONEncoder().encode(AnyEncodable(body))
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        let (answer, response) = try await session.run(request, body: data)
        try LinkClient.check(answer, response)
        do {
            return try JSONDecoder().decode(T.self, from: answer)
        } catch {
            throw LinkError.badResponse
        }
    }

    static func check(_ data: Data, _ response: HTTPURLResponse) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        let sent = try? JSONDecoder().decode(ApiError.self, from: data)
        let message = sent?.message.flatMap { $0.isEmpty ? nil : $0 } ?? "The computer answered \(response.statusCode)."
        throw LinkError.refused(status: response.statusCode, code: sent?.error ?? "http\(response.statusCode)", message: message, offset: sent?.offset)
    }

    public func health() async throws -> Health {
        try await json(Health.self, makeRequest("GET", "/v1/health", timeout: 4))
    }

    /// Waits for the person at the computer: it answers after they approve, or declines after 120 seconds.
    public func pair(token: String, phoneId: String, phoneName: String, appVersion: String) async throws -> PairResponse {
        let body = PairRequest(token: token, phoneId: phoneId, phoneName: phoneName, appVersion: appVersion)
        return try await json(PairResponse.self, makeRequest("POST", "/v1/pair", timeout: 130, authenticated: false), body: body)
    }

    public func hello(timeout: TimeInterval = 4) async throws -> Hello {
        try await json(Hello.self, makeRequest("GET", "/v1/hello", timeout: timeout))
    }

    public func forgetSelf() async throws {
        let (data, response) = try await session.run(makeRequest("DELETE", "/v1/devices/self"))
        try LinkClient.check(data, response)
    }

    public func postItem(_ item: ItemRequest) async throws -> ItemState {
        try await json(ItemState.self, makeRequest("POST", "/v1/items"), body: item)
    }

    public func itemState(_ id: String) async throws -> ItemState {
        try await json(ItemState.self, makeRequest("GET", "/v1/items/\(id)"))
    }

    public func putChunk(id: String, offset: Int64, data: Data, onBytes: @escaping @Sendable (Int64) -> Void) async throws -> ItemState {
        var request = try makeRequest("PUT", "/v1/items/\(id)/data")
        request.setValue(String(offset), forHTTPHeaderField: "X-Offset")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("100-continue", forHTTPHeaderField: "Expect")
        let (answer, response) = try await session.run(request, body: data, progress: onBytes)
        try LinkClient.check(answer, response)
        do {
            return try JSONDecoder().decode(ItemState.self, from: answer)
        } catch {
            throw LinkError.badResponse
        }
    }

    public func galleryMissing(_ ids: [String]) async throws -> [String] {
        try await json(GalleryCheckReply.self, makeRequest("POST", "/v1/gallery/check"), body: GalleryCheckRequest(ids: ids)).missing
    }

    public func outbox(wait: Int) async throws -> OutboxReply {
        let seconds = min(max(wait, 0), LinkProtocol.maxOutboxWait)
        return try await json(OutboxReply.self, makeRequest("GET", "/v1/outbox", query: ["wait": String(seconds)], timeout: TimeInterval(seconds + 15)))
    }

    public func download(id: String, from: Int64, onStart: @escaping (Int, Int64) throws -> Void, sink: @escaping (Data) throws -> Void) async throws {
        var request = try makeRequest("GET", "/v1/outbox/\(id)/data")
        if from > 0 { request.setValue("bytes=\(from)-", forHTTPHeaderField: "Range") }
        let (data, response) = try await session.run(request, onResponse: { response in
            try onStart(response.statusCode, LinkClient.fullSize(response, from: from))
        }, sink: sink)
        try LinkClient.check(data, response)
    }

    /// The whole file's size from a 200's length or a 206's Content-Range; -1 when the answer does not say.
    static func fullSize(_ response: HTTPURLResponse, from: Int64) -> Int64 {
        if response.statusCode == 206 {
            let range = response.value(forHTTPHeaderField: "Content-Range") ?? ""
            if let slash = range.lastIndex(of: "/"), let size = Int64(range[range.index(after: slash)...]) { return size }
            return -1
        }
        return Int64(response.value(forHTTPHeaderField: "Content-Length") ?? "") ?? -1
    }

    public func acknowledge(_ id: String) async throws {
        let (data, response) = try await session.run(makeRequest("DELETE", "/v1/outbox/\(id)"))
        try LinkClient.check(data, response)
    }
}

private struct AnyEncodable: Encodable {
    let value: Encodable

    init(_ value: Encodable) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}
