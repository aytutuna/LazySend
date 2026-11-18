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
        XCTAssertTrue(app.item("files.add").exists)
        XCTAssertTrue(app.item("main.pcs").exists)
        attach(app, as: "02-main")
    }

    @MainActor
    func testTheEmptyFilesStateOffersThePlusMenu() {
        let app = XCUIApplication.launched(tab: "Files", pairedOnly: true)
        XCTAssertTrue(app.item("files.empty").waitForExistence(timeout: 30))
        let add = app.item("files.add")
        XCTAssertTrue(add.exists)
        add.tap()
        XCTAssertTrue(app.item("source.photos").waitForExistence(timeout: 30))
        XCTAssertTrue(app.item("source.files").exists)
        XCTAssertTrue(app.item("source.format").exists)
        attach(app, as: "03-files-empty")
    }

    @MainActor
    func testTheFilesTabListsNoTextsAndTheClipboardListsThem() {
        let app = XCUIApplication.launched(demo: true, tab: "Files")
        XCTAssertTrue(app.item("main.timeline").waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["The door code is 4821"].exists)
        XCTAssertTrue(app.staticTexts["Quarterly report.pdf"].exists)
        app.tabBars.buttons["Clipboard"].tap()
        XCTAssertTrue(app.staticTexts["The door code is 4821"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["Quarterly report.pdf"].exists)
    }

    @MainActor
    func testTheGalleryScreenIsInThePlusMenu() {
        let app = XCUIApplication.launched(demo: true)
        let add = app.item("files.add")
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        add.tap()
        let gallery = app.item("source.gallery")
        XCTAssertTrue(gallery.waitForExistence(timeout: 30))
        gallery.tap()
        XCTAssertTrue(app.item("send.gallery").waitForExistence(timeout: 30))
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
    func testTheClipboardTextBoxEnablesSendOnlyWithText() {
        let app = XCUIApplication.launched(demo: true, tab: "Clipboard")
        let field = app.item("clip.text")
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        XCTAssertFalse(app.item("clip.send").isEnabled)
        field.tap()
        field.typeText("the door code is 4821")
        XCTAssertTrue(app.item("clip.send").isEnabled)
        attach(app, as: "11-clipboard-text")
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

    // A well-formed code for a computer that is not there, typed in as text; -slowPairing holds the pairing for a while so the
    // waiting screen can be looked at before it fails.
    private static let unreachableCode = "lazysend://pair?v=1&id=office-pc-1&n=Office%20PC&fp=AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE&a=192.0.2.1&p=9&t=AgICAgICAgICAgICAgICAg"

    @MainActor
    private func assertWaitingScreenStays(from tab: String, button: String) {
        let app = XCUIApplication.launched(tab: nil, slowPairing: true)
        if tab != "Camera" { app.tabBars.buttons[tab].tap() }
        let open = app.item(button)
        XCTAssertTrue(open.waitForExistence(timeout: 30))
        open.tap()
        let field = app.item("pair.paste")
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap()
        field.typeText(ScreenshotTests.unreachableCode)
        let connect = app.item("pair.connect")
        XCTAssertTrue(connect.waitForExistence(timeout: 30))
        connect.tap()
        let code = app.item("pair.checkCode")
        XCTAssertTrue(code.waitForExistence(timeout: 30))
        let later = expectation(description: "a few seconds pass")
        later.isInverted = true
        wait(for: [later], timeout: 4)
        XCTAssertTrue(code.exists)
        XCTAssertFalse(app.item("pair.paste").exists)
        XCTAssertFalse(app.item("pair.scanner.message").exists)
        attach(app, as: "10-pair-waiting")
    }

    @MainActor
    func testPairingStaysOnTheWaitingScreenWhenOpenedFromTheCamera() {
        assertWaitingScreenStays(from: "Camera", button: "camera.pair")
    }

    @MainActor
    func testPairingStaysOnTheWaitingScreenWhenOpenedFromTheClipboard() {
        assertWaitingScreenStays(from: "Clipboard", button: "clip.pair")
    }
}
