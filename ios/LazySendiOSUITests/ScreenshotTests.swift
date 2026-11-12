import XCTest

final class ScreenshotTests: XCTestCase {
    @MainActor
    func testEmptyState() {
        let app = XCUIApplication.launched()
        let title = app.item("empty.title")
        XCTAssertTrue(title.waitForExistence(timeout: 30))
        XCTAssertEqual(title.label, "Nothing paired yet")
        XCTAssertTrue(app.item("empty.pair").exists)
        attach(app, as: "01-empty")
    }

    @MainActor
    func testMainScreenWithDemoData() {
        let app = XCUIApplication.launched(demo: true)
        XCTAssertTrue(app.item("main.timeline").waitForExistence(timeout: 30))
        XCTAssertTrue(app.item("main.send").exists)
        XCTAssertTrue(app.item("main.pcs").exists)
        attach(app, as: "02-main")
    }

    @MainActor
    func testSendScreen() {
        let app = XCUIApplication.launched(demo: true)
        let send = app.item("main.send")
        XCTAssertTrue(send.waitForExistence(timeout: 30))
        send.tap()
        XCTAssertTrue(app.item("send.text").waitForExistence(timeout: 30))
        XCTAssertTrue(app.item("send.gallery").exists)
        attach(app, as: "03-send")
    }

    @MainActor
    func testPairScreenWithoutCamera() {
        let app = XCUIApplication.launched()
        let pair = app.item("empty.pair")
        XCTAssertTrue(pair.waitForExistence(timeout: 30))
        pair.tap()
        XCTAssertTrue(app.item("pair.scanner.message").waitForExistence(timeout: 30))
        XCTAssertTrue(app.item("pair.paste").exists)
        attach(app, as: "04-pair")
    }
}
