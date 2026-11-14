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
    func testGalleryInProgress() {
        let app = XCUIApplication.launched(demo: true)
        let progress = app.item("entry.gallery")
        XCTAssertTrue(progress.waitForExistence(timeout: 30))
        XCTAssertTrue(progress.label.hasPrefix("128 of 412"))
        XCTAssertTrue(app.item("entry.gallery.stop").exists)
        attach(app, as: "05-gallery")
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

    @MainActor
    func testReceiveScreen() {
        let app = XCUIApplication.launched(demo: true)
        let receive = app.item("main.receive")
        XCTAssertTrue(receive.waitForExistence(timeout: 30))
        receive.tap()
        let code = app.item("receive.shortCode")
        XCTAssertTrue(code.waitForExistence(timeout: 30))
        XCTAssertEqual(code.label, "7KQ2-M9XD")
        XCTAssertTrue(app.item("receive.copy").exists)
        XCTAssertTrue(app.item("receive.foreground").exists)
        attach(app, as: "06-receive")
    }
}
