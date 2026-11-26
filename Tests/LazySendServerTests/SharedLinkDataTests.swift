import CryptoKit
import Foundation
import XCTest
@testable import LazySendKit
@testable import LazySendServer

// Reads testdata/link, the phone link's shared test data, and checks this code base against every case in it.

private typealias Json = [String: Any]

private func loadFile(_ file: String) throws -> Json {
    var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: folder.appendingPathComponent("testdata/link/\(file)").path) {
        let parent = folder.deletingLastPathComponent()
        guard parent != folder else { throw CocoaError(.fileNoSuchFile) }
        folder = parent
    }
    let data = try Data(contentsOf: folder.appendingPathComponent("testdata/link/\(file)"))
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? Json)
}

private struct DataError: Error, CustomStringConvertible {
    var description: String
}

private func list(_ json: Json, _ key: String) throws -> [Json] {
    guard let items = json[key] as? [Json], !items.isEmpty else { throw DataError(description: "\(key) is missing, empty or not a list of objects") }
    return items
}

private func string(_ json: Json, _ key: String) -> String? { json[key] as? String }

private func int(_ value: Any?) throws -> Int {
    guard let number = value as? NSNumber, !isBool(number) else { throw DataError(description: "\(String(describing: value)) is not a number") }
    return number.intValue
}

private func int64(_ value: Any?) throws -> Int64 {
    guard let number = value as? NSNumber, !isBool(number) else { throw DataError(description: "\(String(describing: value)) is not a number") }
    return number.int64Value
}

private func pattern(_ from: Int64, _ to: Int64) -> Data {
    Data([UInt8](unsafeUninitializedCapacity: Int(to - from)) { buffer, count in
        for i in 0..<Int(to - from) { buffer[i] = UInt8((from + Int64(i)) % 251) }
        count = Int(to - from)
    })
}

private func hasSeparatorOrControl(_ text: String) -> Bool {
    for scalar in text.unicodeScalars {
        let value = scalar.value
        if value < 0x20 || (0x7F...0x9F).contains(value) { return true }
        if value == 0x2F || value == 0x5C || value == 0x3A { return true }
    }
    return false
}

private func isBool(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
}

private func same(_ expected: Any, _ actual: Any?) -> Bool {
    if expected is NSNull { return actual == nil }
    if let text = expected as? String { return actual as? String == text }
    if isBool(expected) { return actual as? Bool == (expected as? NSNumber)?.boolValue }
    if let number = expected as? NSNumber {
        if actual is String || actual is Bool || actual == nil { return false }
        return (actual as? NSNumber)?.int64Value == number.int64Value || (actual as? Int64) == number.int64Value || (actual as? Int) == number.intValue
    }
    if let items = expected as? [String] { return actual as? [String] == items }
    return false
}

final class SharedLinkDataTests: XCTestCase {
    func testPairingCodesAreReadAsTheDataSays() throws {
        for c in try list(try loadFile("pairing-uris.json"), "cases") {
            let name = string(c, "name")!
            let result = string(c, "result")!
            let uri = string(c, "uri")!
            do {
                let read = try PairingCode.parse(uri)
                guard result == "ok" else { XCTFail("\(name): expected \(result), got a code"); continue }
                let p = c["pairing"] as! Json
                XCTAssertEqual(read.desktopId, string(p, "desktopId"), name)
                XCTAssertEqual(read.name, string(p, "name"), name)
                XCTAssertEqual(read.fingerprint, string(p, "fingerprint"), name)
                XCTAssertEqual(read.port, try int(p["port"]), name)
                XCTAssertEqual(read.token, string(p, "token"), name)
                XCTAssertEqual(read.addresses, p["addresses"] as? [String], name)
                XCTAssertEqual(read.checkCode, string(p, "checkCode"), name)
                XCTAssertEqual(try PairingCode.parse(read.uri), read, "\(name): writing and reading again gives another code")
            } catch let error as PairingCodeError {
                XCTAssertEqual(String(describing: error.problem).lowercased(), result.lowercased(), name)
            }
        }
    }

    func testCheckCodesMatch() throws {
        for c in try list(try loadFile("check-codes.json"), "cases") {
            let fingerprint = Data((c["fingerprint"] as! [NSNumber]).map { UInt8($0.intValue) })
            XCTAssertEqual(SpkiFingerprint.checkCode(fingerprint), string(c, "checkCode"))
            XCTAssertEqual(SpkiFingerprint.matchCode(fingerprint, shortCode: string(c, "shortCode")!), string(c, "matchCode"))
        }
    }

    func testShortCodesAreReadAndRedeemedAsTheDataSays() throws {
        let data = try loadFile("short-codes.json")
        XCTAssertEqual(String(ShortCode.alphabet), string(data, "alphabet"))
        for n in try list(data, "normalize") {
            let typed = n["typed"] as? String
            XCTAssertEqual(ShortCode.normalize(typed), n["canonical"] as? String, "normalize \(typed ?? "nothing")")
        }
        let token = Data((data["tokenBytes"] as! [NSNumber]).map { UInt8($0.intValue) })
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        for r in try list(data, "redeem") {
            let session = PairingSession(opened: opened, token: token)
            let typed = session.shortCode.prefix(4).lowercased() + "-" + session.shortCode.suffix(4).lowercased()
            for (step, a) in try list(r, "attempts").enumerated() {
                let presented: String?
                switch a["token"] as? String {
                case "$token": presented = session.token
                case "$shortCode": presented = session.shortCode
                case "$shortCodeTyped": presented = typed
                case let other: presented = other
                }
                let address = string(a, "peer")!
                let peer = address.contains(":") ? Array(address.utf8) : address.split(separator: ".").map { UInt8($0)! }
                let at = try int(a["at"])
                let got = session.redeem(presented, now: opened.addingTimeInterval(Double(at)), peer: peer)
                XCTAssertEqual(String(describing: got).lowercased(), string(a, "expect")!.lowercased(),
                               "\(string(r, "name")!), attempt \(step + 1)")
            }
        }
    }

    private func fields(_ type: String, _ body: Data) throws -> [String: Any?] {
        let decoder = JSONDecoder()
        switch type {
        case "PairRequest":
            let v = try decoder.decode(PairRequest.self, from: body)
            return ["token": v.token, "phoneId": v.phoneId, "phoneName": v.phoneName, "platform": v.platform, "appVersion": v.appVersion]
        case "PairResponse":
            let v = try decoder.decode(PairResponse.self, from: body)
            return ["protocolVersion": v.protocolVersion, "desktopId": v.desktopId, "desktopName": v.desktopName, "deviceSecret": v.deviceSecret]
        case "Hello":
            let v = try decoder.decode(Hello.self, from: body)
            return ["protocolVersion": v.protocolVersion, "desktopId": v.desktopId, "desktopName": v.desktopName,
                    "maxChunkBytes": v.maxChunkBytes, "addresses": v.addresses]
        case "ItemRequest":
            let v = try decoder.decode(ItemRequest.self, from: body)
            return ["kind": v.kind, "text": v.text, "url": v.url, "name": v.name, "size": v.size, "mime": v.mime,
                    "sourceId": v.sourceId, "sha256": v.sha256, "sendId": v.sendId, "clip": v.clip]
        case "ItemState":
            let v = try decoder.decode(ItemState.self, from: body)
            return ["id": v.id, "offset": v.offset, "done": v.done, "duplicate": v.duplicate]
        case "OutboxReply":
            let v = try decoder.decode(OutboxReply.self, from: body)
            return ["ids": v.items.map(\.id), "kinds": v.items.map(\.kind), "more": v.more,
                    "firstText": v.items.first?.text, "firstClip": v.items.first?.clip,
                    "secondUrl": v.items.count > 1 ? v.items[1].url : nil,
                    "thirdName": v.items.count > 2 ? v.items[2].name : nil, "thirdSize": v.items.count > 2 ? v.items[2].size : nil]
        case "ApiError":
            let v = try decoder.decode(ApiError.self, from: body)
            return ["error": v.error, "message": v.message, "offset": v.offset]
        default:
            throw CocoaError(.coderInvalidValue)
        }
    }

    func testMessagesAreReadAsTheDataSays() throws {
        let data = try loadFile("messages.json")
        for c in try list(data, "cases") {
            let name = string(c, "name")!
            let body = try JSONSerialization.data(withJSONObject: c["json"]!)
            let read: [String: Any?]
            do {
                read = try fields(string(c, "type")!, body)
            } catch {
                XCTFail("\(name): not read (\(error))")
                continue
            }
            for (key, value) in c["expect"] as! Json {
                XCTAssertTrue(read.keys.contains(key) && same(value, read[key] ?? nil), "\(name): \(key) is \(String(describing: read[key] ?? nil)), expected \(value)")
            }
        }
        for c in try list(data, "invalid") {
            XCTAssertThrowsError(try fields(string(c, "type")!, Data(string(c, "body")!.utf8)), "\(string(c, "name")!): read although it is not valid")
        }
    }

    func testErrorCodesAreTheOnesInTheData() throws {
        let codes = [
            LazySendServer.Failure.unauthorized, .pairingClosed, .tokenInvalid, .tokenExpired, .tokenUsed, .declined, .tooManyDevices, .tooLarge,
            .rateLimited, .notFound, .methodNotAllowed, .badRequest, .lengthRequired, .busy, .offsetMismatch(1), .hashMismatch,
            .diskFull, .rangeNotSatisfiable, .changed, .serverError,
        ].map(\.error)
        let wanted = try XCTUnwrap(try loadFile("messages.json")["errorCodes"] as? [String])
        XCTAssertEqual(codes.sorted(), wanted.sorted())
    }

    func testNamesAndIdsAreMadeSafeAsTheDataSays() throws {
        let data = try loadFile("names.json")
        let maxBytes = try int(data["maxFileNameBytes"])
        for c in try list(data, "cleanFileName") {
            let name = c["name"] as? String
            let clean = FileNames.clean(name)
            let label = "\"\(name ?? "nothing")\" became \"\(clean)\""
            XCTAssertTrue(!clean.isEmpty && clean.utf8.count <= maxBytes, "\(label): empty or too long")
            XCTAssertFalse(hasSeparatorOrControl(clean), "\(label): a separator or control character is left")
            XCTAssertFalse(clean.hasSuffix(".") || clean.hasSuffix(" "), "\(label): ends with a dot or space")
            if let keep = string(c, "keep") { XCTAssertTrue(clean.hasSuffix(keep), "\(label): lost \(keep)") }
            if let exact = string(c, "exact") { XCTAssertEqual(clean, exact, label) }
        }
        for id in data["validIds"] as! [String] { XCTAssertTrue(isValidId(id), "id \(id) refused") }
        for id in data["invalidIds"] as! [String] { XCTAssertFalse(isValidId(id), "id \(id) accepted") }
    }

    func testLargeFileIsDescribedByItsSizeAndFingerprint() throws {
        let data = try loadFile("large-file.json")
        let size = try int64(data["size"])
        var sha = SHA256()
        var at: Int64 = 0
        while at < size {
            let to = min(size, at + (1 << 20))
            sha.update(data: pattern(at, to))
            at = to
        }
        XCTAssertEqual(sha.finalize().map { String(format: "%02x", $0) }.joined(), string(data, "sha256"))
    }

    func testSessionsRunAsTheDataSays() async throws {
        let data = try loadFile("sessions.json")
        let large = try loadFile("large-file.json")
        for c in try list(data, "cases") {
            if let readers = c["readers"] as? [String], !readers.contains("swift") { continue }
            let harness = try await Harness()
            do {
                let phone = try await harness.pair()
                let session = Session(harness: harness, phone: phone, large: large)
                for (step, s) in try list(c, "steps").enumerated() {
                    do {
                        try await session.run(s)
                    } catch {
                        XCTFail("\(string(c, "name")!), step \(step + 1) (\(string(s, "op")!)): \(error)")
                        break
                    }
                }
            }
            await harness.tearDown()
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    private final class Session {
        let harness: Harness
        let phone: Phone
        let large: Json
        var id = ""
        var size: Int64 = 0
        var offset: Int64 = 0
        var settled: Int64 = 0
        var polled: [String] = []
        var folder: URL { harness.received.appendingPathComponent("Test iPhone") }

        init(harness: Harness, phone: Phone, large: Json) {
            self.harness = harness
            self.phone = phone
            self.large = large
        }

        func check(_ expect: Json, _ state: ItemState) throws {
            if let o = expect["offset"] {
                let wanted = try int64(o)
                if wanted != state.offset { throw Failure("offset is \(state.offset), expected \(wanted)") }
            }
            if let d = expect["done"], (d as? Bool) != state.done { throw Failure("done is \(state.done)") }
        }

        func expectRefused(_ s: Json, _ block: () async throws -> Void) async throws {
            do {
                try await block()
            } catch let error as LinkError {
                let status = try int(s["status"])
                if error.status != status || error.code != string(s, "code") {
                    throw Failure("answered \(String(describing: error.status)) \(error.code ?? "")")
                }
                if let o = s["offset"] {
                    let wanted = try int64(o)
                    if error.offset != wanted { throw Failure("offset is \(String(describing: error.offset))") }
                }
                return
            }
            throw Failure("expected \(string(s, "code")!)")
        }

        func put(_ from: Int64, _ to: Int64) async throws -> ItemState {
            try await phone.put(id, offset: from, pattern(from, to))
        }

        func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

        func run(_ s: Json) async throws {
            switch string(s, "op")! {
            case "begin":
                let content = s["content"]!
                size = try int64((content as? String) != nil ? large["size"] : (content as! Json)["size"])
                let hash: String?
                if s["hash"] != nil {
                    hash = (content as? String) != nil ? string(large, "sha256") : sha(pattern(0, size))
                } else if s["hashOfOther"] != nil {
                    hash = sha(Data("other".utf8))
                } else {
                    hash = nil
                }
                let state = try await phone.client.postItem(ItemRequest(kind: "file", name: string(s, "name"), size: size, sha256: hash))
                id = state.id
                offset = state.offset
                try check(s["expect"] as! Json, state)
            case "put":
                let from = try int64(s["from"])
                let to = try int64(s["to"])
                let state = try await put(from, to)
                offset = state.offset
                try check(s["expect"] as! Json, state)
            case "putAll":
                let chunk = try int64(s["chunk"])
                var last: ItemState?
                while offset < size {
                    last = try await put(offset, min(size, offset + chunk))
                    offset = last!.offset
                }
                try check(s["expect"] as! Json, last!)
            case "putError":
                let from = try int64(s["from"])
                let to = try int64(s["to"])
                try await expectRefused(s) { _ = try await put(from, to) }
            case "drop":
                let at = try int64(s["offset"])
                let declared = try int(s["declared"])
                let sent = try int64(s["sent"])
                _ = try await phone.partialChunk(id, offset: at, declared: declared, sent: pattern(at, at + sent), hangUp: true)
            case "settle":
                var last: Int64 = -1
                for _ in 0..<100 {
                    let now = try await phone.client.itemState(id).offset
                    if now == last { break }
                    last = now
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                let between = (s["between"] as! [NSNumber]).map(\.int64Value)
                if last < between[0] || last > between[1] { throw Failure("\(last) is not between \(between[0]) and \(between[1])") }
                settled = last
            case "resume":
                try check(s["expect"] as! Json, try await put(settled, size))
            case "state":
                try check(s["expect"] as! Json, try await phone.client.itemState(id))
            case "stateError":
                try await expectRefused(s) { _ = try await phone.client.itemState(id) }
            case "restart":
                try await harness.restart()
            case "expectFile":
                let bytes = try Data(contentsOf: folder.appendingPathComponent(string(s, "name")!))
                if let content = s["content"] as? Json {
                    let expected = pattern(0, try int64(content["size"]))
                    if bytes != expected { throw Failure("the file is not what was sent") }
                } else if sha(bytes) != string(large, "sha256") {
                    throw Failure("the file is not what was sent")
                }
            case "expectNoFile":
                if FileManager.default.fileExists(atPath: folder.appendingPathComponent(string(s, "name")!).path) { throw Failure("the file is there") }
            case "post":
                let item = string(s, "kind") == "text" ? ItemRequest(kind: "text", text: string(s, "text")) : ItemRequest(kind: "link", url: string(s, "url"))
                _ = try await phone.client.postItem(item)
                harness.clock.now += 1
            case "expectReceived":
                let got = harness.service.history.items.reversed().map { [$0.kind, $0.kind == "text" ? $0.text ?? "" : $0.url ?? ""] }
                let want = (s["items"] as! [[String]])
                if got != want { throw Failure("received \(got), expected \(want)") }
            case "queue":
                if string(s, "kind") == "text" {
                    _ = try harness.service.outbox.queueText(phone.id, string(s, "text")!)
                } else {
                    _ = try harness.service.outbox.queueLink(phone.id, string(s, "url")!)
                }
            case "poll":
                let items = try await phone.client.outbox(wait: 0).items
                polled = items.map(\.id)
                let got = items.map { [$0.kind, $0.kind == "text" ? $0.text ?? "" : $0.url ?? ""] }
                let want = (s["items"] as! [[String]])
                if got != want { throw Failure("listed \(got), expected \(want)") }
            case "ack":
                let index = try int(s["index"])
                try await phone.client.acknowledge(polled[index])
                polled.remove(at: index)
            default:
                throw Failure("unknown step")
            }
        }
    }
}
