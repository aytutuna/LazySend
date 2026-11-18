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
    func testTheTabsSwitchAndTheClipboardHasAPasteButton() {
        let app = XCUIApplication.launched(demo: true, tab: nil)
        // The Simulator has no camera.
        XCTAssertTrue(app.item("camera.message").waitForExistence(timeout: 30))
        XCTAssertEqual(app.item("camera.message").label, "No camera here")
        XCTAssertTrue(app.item("camera.target").exists)
        XCTAssertTrue(app.item("camera.shutter").exists)
        attach(app, as: "08-camera")
        app.tabBars.buttons["Files"].tap()
        XCTAssertTrue(app.item("main.timeline").waitForExistence(timeout: 30))
        app.tabBars.buttons["Clipboard"].tap()
        XCTAssertTrue(app.item("clip.hint").waitForExistence(timeout: 30))
        XCTAssertEqual(app.item("clip.hint").label, "Paste here to put it on Office PC's clipboard.")
        XCTAssertTrue(app.item("clip.paste").exists || app.buttons["Paste"].exists)
        attach(app, as: "09-clipboard")
        app.tabBars.buttons["Camera"].tap()
        XCTAssertTrue(app.item("camera.message").waitForExistence(timeout: 30))
    }

    @MainActor
    func testTheCameraWithoutAComputerOffersPairing() {
        let app = XCUIApplication.launched(tab: nil)
        XCTAssertTrue(app.item("camera.pairTitle").waitForExistence(timeout: 30))
        let pair = app.item("camera.pair")
        XCTAssertTrue(pair.exists)
        XCTAssertFalse(app.item("camera.target").exists)
        pair.tap()
        XCTAssertTrue(app.item("pair.scanner.message").waitForExistence(timeout: 30))
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

    @MainActor
    func testAllowingAPhoneOnTheApprovalPromptPairsIt() {
        let app = XCUIApplication.launched(demo: true, approval: true)
        app.item("main.receive").tap()
        let allow = app.alerts.buttons["Allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 30))
        attach(app, as: "07-approval")
        allow.tap()
        let paired = app.item("receive.paired")
        XCTAssertTrue(paired.waitForExistence(timeout: 30))
        XCTAssertEqual(paired.label, "Paired with Pixel 9.")
    }

    @MainActor
    func testDecliningAPhoneOnTheApprovalPromptDoesNotPairIt() {
        let app = XCUIApplication.launched(demo: true, approval: true)
        app.item("main.receive").tap()
        let decline = app.alerts.buttons["Don't allow"]
        XCTAssertTrue(decline.waitForExistence(timeout: 30))
        decline.tap()
        XCTAssertTrue(app.item("receive.shortCode").waitForExistence(timeout: 30))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(app.item("receive.paired").exists)
    }
}
