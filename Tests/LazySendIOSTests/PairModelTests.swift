#if os(iOS)
import LazySendKit
import XCTest
@testable import LazySendIOS

@MainActor
final class PairModelTests: XCTestCase {
    private func codeText() -> String {
        let fingerprint = Base64Url.encode(Data(repeating: 1, count: 32))
        let token = Base64Url.encode(Data(repeating: 2, count: 16))
        return "lazysend://pair?v=1&id=office-pc-1&n=Office%20PC&fp=\(fingerprint)&a=127.0.0.1&p=9&t=\(token)"
    }

    func testTextThatIsNotACodeShowsTheParseError() {
        let pair = PairModel(app: AppModel(env: .temporary()))
        pair.submit("hello")
        XCTAssertEqual(pair.parseError, "This is not a Lazy Send pairing code.")
        XCTAssertEqual(pair.step, .scanning)
    }

    func testDamagedCodeShowsTheParseError() {
        let pair = PairModel(app: AppModel(env: .temporary()))
        pair.submit("lazysend://pair?v=1&id=x")
        XCTAssertNotNil(pair.parseError)
        XCTAssertEqual(pair.step, .scanning)
    }

    func testValidCodeShowsItsCheckCodeThenFailsWhenThePcIsNotThere() async throws {
        let pair = PairModel(app: AppModel(env: .temporary()))
        let expected = try PairingCode.parse(codeText()).checkCode
        pair.submit(codeText())
        XCTAssertNil(pair.parseError)
        XCTAssertEqual(pair.step, .waiting(checkCode: expected))
        XCTAssertFalse(expected.isEmpty)
        await pair.finished()
        XCTAssertEqual(pair.step, .failed(try XCTUnwrap(PairingError.unreachable.errorDescription)))
        pair.retry()
        XCTAssertEqual(pair.step, .scanning)
    }
}
#endif
