import Foundation
import Network
import XCTest
@testable import LazySendKit
@testable import LazySendServer

final class HttpParserTests: XCTestCase {
    private func parse(_ text: String) -> HttpParseResult {
        LinkHttp.parse(Data(text.utf8))
    }

    func testAPlainRequestIsParsed() {
        let result = parse("PUT /v1/items/abc/data?x=1 HTTP/1.1\r\nHost: a\r\nContent-Length: 12\r\nX-Offset: 3\r\n\r\nbody")
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.head?.method, "PUT")
        XCTAssertEqual(result.head?.path, "/v1/items/abc/data")
        XCTAssertEqual(result.head?.query, "x=1")
        XCTAssertEqual(result.head?.contentLength, 12)
        XCTAssertEqual(result.head?.header("x-offset"), "3")
        XCTAssertEqual(result.consumed, head.utf8.count)
    }

    func testAHeadThatHasNotArrivedYetIsIncomplete() {
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nHost: a\r\n").status, .incomplete)
        XCTAssertEqual(parse("GET / HT").status, .incomplete)
    }

    func testStrictnessAboutWhatIsAccepted() {
        XCTAssertEqual(parse("GET / HTTP/1.1\nHost: a\n\n").errorStatus, 400)
        XCTAssertEqual(parse("GET / HTTP/1.1\r\n\r\n").errorStatus, 400)
        XCTAssertEqual(parse("GET / HTTP/1.0\r\nHost: a\r\n\r\n").errorStatus, 505)
        XCTAssertEqual(parse("PATCH / HTTP/1.1\r\nHost: a\r\n\r\n").errorStatus, 501)
        XCTAssertEqual(parse("GET /x#frag HTTP/1.1\r\nHost: a\r\n\r\n").errorStatus, 400)
        XCTAssertEqual(parse("GET http://a/ HTTP/1.1\r\nHost: a\r\n\r\n").errorStatus, 400)
        XCTAssertEqual(parse("POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n").errorStatus, 501)
        XCTAssertEqual(parse("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n").errorStatus, 400)
        XCTAssertEqual(parse("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: +1\r\n\r\n").errorStatus, 400)
        XCTAssertEqual(parse("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1 2\r\n\r\n").errorStatus, 400)
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nHost: a\r\n folded\r\n\r\n").errorStatus, 400)
        XCTAssertEqual(parse("GET / HTTP/1.1\r\n\r\n").errorStatus, 400)
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n").errorStatus, 400)
        XCTAssertEqual(parse("PUT / HTTP/1.1\r\nHost: a\r\nExpect: something\r\n\r\n").errorStatus, 417)
    }

    func testLimits() {
        XCTAssertEqual(parse("GET /" + String(repeating: "a", count: 2100) + " HTTP/1.1\r\nHost: a\r\n\r\n").errorStatus, 414)
        let many = (0..<70).map { "X-\($0): v\r\n" }.joined()
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nHost: a\r\n\(many)\r\n").errorStatus, 431)
        let long = "GET / HTTP/1.1\r\nHost: a\r\nX-Long: " + String(repeating: "a", count: 17_000) + "\r\n\r\n"
        XCTAssertEqual(parse(long).errorStatus, 431)
    }

    func testExpectContinueIsNoticed() {
        let result = parse("PUT / HTTP/1.1\r\nHost: a\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n")
        XCTAssertEqual(result.head?.expectsContinue, true)
    }

    func testBearerTokenAndQuery() {
        let head = parse("GET /v1/outbox?wait=5&x HTTP/1.1\r\nHost: a\r\nAuthorization: Bearer abc123 \r\n\r\n").head
        XCTAssertEqual(head?.bearerToken, "abc123")
        XCTAssertEqual(LinkHttp.queryParameters(head?.query ?? ""), ["wait": "5", "x": ""])
    }
}

final class RequestBodyTests: XCTestCase {
    func testTheBodyIsExactlyItsLengthAndStartsWithWhatArrivedWithTheHead() async throws {
        var rest = Data("cdefghijkl".utf8)
        let body = LinkRequestBody(length: 8, prefix: Data("ab".utf8)) { max in
            let piece = Data(rest.prefix(max))
            rest = rest.dropFirst(piece.count)
            return piece
        }
        var text = ""
        while true {
            let piece = try await body.read(maxLength: 100)
            if piece.isEmpty { break }
            text += String(decoding: piece, as: UTF8.self)
        }
        XCTAssertEqual(text, "abcdefgh")
        XCTAssertEqual(body.remaining, 0)
        XCTAssertEqual(rest.count, 2)
    }

    func testAWithheldBodyIsNotReadWhenDiscarded() async throws {
        var asked = 0
        let body = LinkRequestBody(length: 10, sendContinue: { asked += 1 }) { _ in
            XCTFail("The body should not be read")
            return Data()
        }
        XCTAssertTrue(body.isWithheld)
        let all = try await body.discard(maxBytes: 100)
        XCTAssertTrue(all)
        XCTAssertEqual(asked, 0)
    }

    func testABodyOverTheLimitIsNotDiscarded() async throws {
        let body = LinkRequestBody(length: 100, prefix: Data()) { _ in Data(count: 10) }
        let all = try await body.discard(maxBytes: 50)
        XCTAssertFalse(all)
    }
}

final class FileNameTests: XCTestCase {
    func testSeparatorsAndControlCharactersBecomeUnderscores() {
        XCTAssertEqual(FileNames.clean("a/b\\c:d\u{07}e.txt"), "a_b_c_d_e.txt")
    }

    func testEmptyAndDotOnlyNamesFallBack() {
        XCTAssertEqual(FileNames.clean(""), "file")
        XCTAssertEqual(FileNames.clean("  . . "), "file")
        XCTAssertEqual(FileNames.clean(nil, fallback: "Phone"), "Phone")
    }

    func testLongNamesKeepTheirExtensionAndFitInBytes() {
        let name = FileNames.clean(String(repeating: "é", count: 300) + ".jpeg")
        XCTAssertTrue(name.hasSuffix(".jpeg"))
        XCTAssertLessThanOrEqual(name.utf8.count, 240)
    }

    func testUniqueAddsANumberBeforeTheExtension() throws {
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                 appropriateFor: FileManager.default.temporaryDirectory, create: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(FileNames.unique(in: folder, name: "a.txt"), "a.txt")
        FileManager.default.createFile(atPath: folder.appendingPathComponent("a.txt").path, contents: nil)
        XCTAssertEqual(FileNames.unique(in: folder, name: "a.txt"), "a (2).txt")
        FileManager.default.createFile(atPath: folder.appendingPathComponent("a (2).txt").path, contents: nil)
        XCTAssertEqual(FileNames.unique(in: folder, name: "a.txt"), "a (3).txt")
        XCTAssertEqual(FileNames.unique(in: folder, name: "noext"), "noext")
    }
}

final class PeerTests: XCTestCase {
    private func host(_ text: String) -> NWEndpoint.Host {
        NWEndpoint.Host(text)
    }

    func testLocalRangesAreAnswered() {
        for address in ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.1", "192.168.1.9", "169.254.3.4", "::1", "fe80::1", "fd12::5",
                        "::ffff:192.168.1.9"] {
            XCTAssertTrue(Peers.isLocal(host(address)), address)
        }
    }

    func testOtherAddressesAreNot() {
        for address in ["8.8.8.8", "172.32.0.1", "100.64.1.1", "2001:db8::1", "::ffff:8.8.8.8"] {
            XCTAssertFalse(Peers.isLocal(host(address)), address)
        }
    }

    func testAnOwnSubnetLetsASharedAddressIn() {
        let subnet = Subnet(name: "utun3", address: ipv4ToInt("100.64.1.10")!, prefix: 10)
        XCTAssertTrue(Peers.isAllowed(host("100.100.5.5"), subnets: [subnet]))
        XCTAssertFalse(Peers.isAllowed(host("100.100.5.5"), subnets: []))
        XCTAssertFalse(Peers.isAllowed(host("8.8.8.8"), subnets: [subnet]))
    }

    func testPairingAddressesPutSelfAssignedOnesLastAndStopAtEight() {
        let subnets = [
            Subnet(name: "en1", address: ipv4ToInt("169.254.9.9")!, prefix: 16),
            Subnet(name: "en0", address: ipv4ToInt("192.168.1.5")!, prefix: 24),
            Subnet(name: "bridge100", address: ipv4ToInt("172.20.10.2")!, prefix: 28),
        ]
        XCTAssertEqual(Peers.pairingAddresses(subnets), ["192.168.1.5", "172.20.10.2", "169.254.9.9"])
        let many = (1...12).map { Subnet(name: "en\($0)", address: ipv4ToInt("10.0.\($0).1")!, prefix: 24) }
        XCTAssertEqual(Peers.pairingAddresses(many).count, 8)
    }
}

final class PairingSessionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testTheRightTokenIsAcceptedOnce() {
        let session = PairingSession(opened: start)
        XCTAssertEqual(session.redeem(session.token, now: start), .accepted)
        XCTAssertEqual(session.redeem(session.token, now: start), .alreadyUsed)
        XCTAssertEqual(session.state(at: start), .used)
    }

    func testTheSessionExpiresAfterFiveMinutes() {
        let session = PairingSession(opened: start)
        XCTAssertEqual(session.state(at: start.addingTimeInterval(299)), .open)
        XCTAssertEqual(session.remaining(at: start.addingTimeInterval(100)), 200, accuracy: 0.001)
        XCTAssertEqual(session.redeem(session.token, now: start.addingTimeInterval(300)), .expired)
        XCTAssertEqual(session.remaining(at: start.addingTimeInterval(300)), 0)
    }

    func testFiveWrongTokensFromOnePeerRefuseThatPeerOnly() {
        let session = PairingSession(opened: start)
        let wrong = Base64Url.encode(Data(repeating: 1, count: 16))
        for _ in 0..<5 { XCTAssertEqual(session.redeem(wrong, now: start, peer: [10, 0, 0, 1]), .wrongToken) }
        XCTAssertEqual(session.redeem(session.token, now: start, peer: [10, 0, 0, 1]), .closed)
        XCTAssertEqual(session.redeem(session.token, now: start, peer: [10, 0, 0, 2]), .accepted)
    }

    func testTwentyFiveWrongTokensFromAnyoneCloseTheSession() {
        let session = PairingSession(opened: start)
        let wrong = Base64Url.encode(Data(repeating: 1, count: 16))
        for index in 0..<25 { _ = session.redeem(wrong, now: start, peer: [10, 0, 0, UInt8(index)]) }
        XCTAssertEqual(session.state(at: start), .closed)
        XCTAssertEqual(session.redeem(session.token, now: start, peer: [10, 0, 1, 1]), .closed)
    }

    func testATokenOfTheWrongShapeIsWrong() {
        let session = PairingSession(opened: start)
        XCTAssertEqual(session.redeem(nil, now: start), .wrongToken)
        XCTAssertEqual(session.redeem("short", now: start), .wrongToken)
        XCTAssertEqual(session.redeem(String(session.token.dropLast()), now: start), .wrongToken)
    }

    func testTheTokenIsSixteenRandomBytes() {
        let a = PairingSession(opened: start)
        let b = PairingSession(opened: start)
        XCTAssertNotEqual(a.token, b.token)
        XCTAssertEqual(Base64Url.decode(a.token)?.count, 16)
    }
}

final class RateLimiterTests: XCTestCase {
    private let host = NWEndpoint.Host("10.0.0.5")
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testTenFailuresBlockAnAddressUntilTheWindowPasses() {
        let limiter = LinkRateLimiter()
        for _ in 0..<9 { limiter.recordFailure(host, now: start) }
        XCTAssertFalse(limiter.isBlocked(host, now: start))
        limiter.recordFailure(host, now: start)
        XCTAssertTrue(limiter.isBlocked(host, now: start))
        XCTAssertFalse(limiter.tryRequest(host, now: start))
        XCTAssertFalse(limiter.isBlocked(host, now: start.addingTimeInterval(61)))
    }

    func testRequestsAreLimitedPerMinute() {
        let limiter = LinkRateLimiter()
        for _ in 0..<3000 { XCTAssertTrue(limiter.tryRequest(host, now: start)) }
        XCTAssertFalse(limiter.tryRequest(host, now: start))
        XCTAssertTrue(limiter.tryRequest(host, now: start.addingTimeInterval(61)))
    }

    func testAnIPv4MappedAddressIsTheSamePeer() {
        let limiter = LinkRateLimiter()
        for _ in 0..<10 { limiter.recordFailure(NWEndpoint.Host("::ffff:10.0.0.5"), now: start) }
        XCTAssertTrue(limiter.isBlocked(host, now: start))
    }
}
