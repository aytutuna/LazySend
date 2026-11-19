import XCTest

// Scan mode on the camera tab. The Simulator has no camera, so these run under `-demoScan`: one drawn frame stands in for the
// viewfinder and is every shot, found by a stand-in for the corner model, and the pages go through the real pipeline, the
// page stack and the send.

final class ScanTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Takes a page by the shutter and waits until the page count reads `label`; the corner editor, if the shot was not found
    /// clearly, is answered with the corners it offers.
    @MainActor
    private func takePage(_ app: XCUIApplication, expecting label: String) {
        let shutter = app.item("scan.shutter")
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        shutter.tap()
        let pages = app.item("scan.pages")
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if pages.exists && pages.label == label { return }
            let use = app.item("corners.use")
            if use.exists && use.isHittable { use.tap() }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("The page count never read \(label)")
    }

    @MainActor
    func testTheCameraTabSwitchesBetweenPhotoAndScan() {
        let app = XCUIApplication.launched(demo: true, tab: nil)
        XCTAssertTrue(app.item("camera.shutter").waitForExistence(timeout: 30))
        XCTAssertTrue(app.item("mode.photo").isSelected)
        XCTAssertFalse(app.item("scan.shutter").exists)
        app.item("mode.scan").tap()
        XCTAssertTrue(app.item("scan.shutter").waitForExistence(timeout: 30))
        XCTAssertTrue(app.item("mode.scan").isSelected)
        XCTAssertFalse(app.item("camera.shutter").exists)
        XCTAssertTrue(app.item("scan.auto").exists)
        XCTAssertTrue(app.item("drawer.toggle").exists)
        XCTAssertTrue(app.item("camera.target").exists)
        // The tab bar stays, and the mode is kept when the tab is left.
        app.tabBars.buttons["Files"].tap()
        XCTAssertTrue(app.item("main.timeline").waitForExistence(timeout: 30))
        app.tabBars.buttons["Camera"].tap()
        XCTAssertTrue(app.item("scan.shutter").waitForExistence(timeout: 30))
        app.item("mode.photo").tap()
        XCTAssertTrue(app.item("camera.shutter").waitForExistence(timeout: 30))
        XCTAssertFalse(app.item("scan.shutter").exists)
    }

    @MainActor
    func testTheScanPageSaysWhenAPageIsFoundAndAutoCanBeTurnedOff() {
        let app = XCUIApplication.launched(demo: true, scan: true, tab: nil)
        app.item("mode.scan").tap()
        let found = app.item("scan.found")
        XCTAssertTrue(found.waitForExistence(timeout: 30))
        XCTAssertEqual(found.label, "Page found · hold still")
        XCTAssertTrue(app.item("scan.shutter").isEnabled)
        attach(app, as: "12-scan")
        app.item("scan.auto").tap()
        XCTAssertTrue(waitForNonexistence(found))
        app.item("scan.auto").tap()
        XCTAssertTrue(found.waitForExistence(timeout: 30))
    }

    @MainActor
    func testTheControlsDrawerPicksTheFilterNewPagesGet() {
        let app = XCUIApplication.launched(demo: true, scan: true, tab: nil)
        app.item("mode.scan").tap()
        XCTAssertFalse(app.item("scan.filter.enhanced").exists)
        app.item("drawer.toggle").tap()
        let enhanced = app.item("scan.filter.enhanced")
        XCTAssertTrue(enhanced.waitForExistence(timeout: 30))
        XCTAssertTrue(enhanced.isSelected)
        for name in ["original", "whiteboard", "grayscale", "blackAndWhite"] {
            XCTAssertTrue(app.item("scan.filter." + name).exists, name)
        }
        app.item("scan.filter.whiteboard").tap()
        XCTAssertTrue(app.item("scan.filter.whiteboard").isSelected)
        XCTAssertFalse(enhanced.isSelected)
        attach(app, as: "13-scan-controls")
        app.item("drawer.toggle").tap()
        XCTAssertTrue(waitForNonexistence(app.item("scan.filter.original")))
    }

    @MainActor
    func testPagesCanBeViewedMovedCutAgainDeletedAndSentAsOnePdf() {
        let app = XCUIApplication.launched(demo: true, scan: true, tab: nil)
        app.item("mode.scan").tap()
        app.item("drawer.toggle").tap()
        // A different filter for each page tells them apart in the stack.
        takePage(app, expecting: "1 page")
        app.item("scan.filter.original").tap()
        takePage(app, expecting: "2 pages")
        app.item("scan.filter.grayscale").tap()
        takePage(app, expecting: "3 pages")
        app.item("scan.pages").tap()
        XCTAssertTrue(app.item("page.2").waitForExistence(timeout: 30))
        XCTAssertTrue(app.item("page.0").label.contains("Enhanced"))
        XCTAssertTrue(app.item("page.1").label.contains("Original"))
        XCTAssertTrue(app.item("page.2").label.contains("Grayscale"))
        XCTAssertEqual(app.item("pages.footer").label, "Done sends the pages to Office PC as one PDF.")
        attach(app, as: "14-scan-pages")

        // The first page moves later; the order follows.
        app.item("page.0.menu").tap()
        app.buttons["Move later"].tap()
        XCTAssertTrue(app.item("page.0").label.contains("Original"))
        XCTAssertTrue(app.item("page.1").label.contains("Enhanced"))

        // A page is looked at, and closed again.
        app.item("page.2").tap()
        XCTAssertTrue(app.item("viewer.page").waitForExistence(timeout: 30))
        app.item("viewer.close").tap()
        XCTAssertTrue(app.item("page.2").waitForExistence(timeout: 30))

        // A page is cut again: the editor opens at its corners, and cutting it keeps the page where it is.
        app.item("page.1.menu").tap()
        app.buttons["Crop"].tap()
        XCTAssertTrue(app.item("corners.use").waitForExistence(timeout: 30))
        XCTAssertTrue(app.item("corners.cancel").exists)
        XCTAssertFalse(app.item("corners.reason").exists)
        attach(app, as: "15-scan-corners")
        app.item("corners.use").tap()
        XCTAssertTrue(app.item("page.1").waitForExistence(timeout: 30))
        XCTAssertTrue(app.item("page.1").label.contains("Enhanced"))

        // The last page is deleted.
        app.item("page.2.menu").tap()
        app.buttons["Delete"].tap()
        XCTAssertTrue(waitForNonexistence(app.item("page.2")))
        XCTAssertEqual(app.item("pages.footer").label, "Done sends the pages to Office PC as one PDF.")

        // Done sends the two pages and empties the stack.
        app.item("pages.done").tap()
        XCTAssertTrue(app.item("scan.status").waitForExistence(timeout: 60))
        XCTAssertEqual(app.item("scan.pages").label, "0 pages")
        app.tabBars.buttons["Files"].tap()
        let sent = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Scan 2' AND label ENDSWITH '.pdf'")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 30))
    }

    @MainActor
    func testOnePageGoesAsAnImageNotAPdf() {
        let app = XCUIApplication.launched(demo: true, scan: true, tab: nil)
        app.item("mode.scan").tap()
        takePage(app, expecting: "1 page")
        app.item("scan.pages").tap()
        XCTAssertTrue(app.item("page.0").waitForExistence(timeout: 30))
        XCTAssertEqual(app.item("pages.footer").label, "Done sends the page to Office PC as an image.")
        app.item("pages.done").tap()
        XCTAssertTrue(app.item("scan.status").waitForExistence(timeout: 60))
        app.tabBars.buttons["Files"].tap()
        let sent = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Scan 2' AND label ENDSWITH '.jpg'")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 30))
    }

    @MainActor
    func testAShotThePageIsNotFoundInOpensTheCornerEditor() {
        let app = XCUIApplication.launched(demo: true, scan: true, unsure: true, tab: nil)
        app.item("mode.scan").tap()
        let shutter = app.item("scan.shutter")
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        shutter.tap()
        XCTAssertTrue(app.item("corners.use").waitForExistence(timeout: 60))
        XCTAssertTrue(app.item("corners.reason").exists)
        XCTAssertTrue(app.item("corner.0").exists)
        XCTAssertTrue(app.item("corners.whole").exists)
        attach(app, as: "16-scan-unsure")
        // Retake leaves the shot out.
        app.item("corners.retake").tap()
        XCTAssertTrue(waitForNonexistence(app.item("corners.use")))
        XCTAssertEqual(app.item("scan.pages").label, "0 pages")
        // Using the corners makes it a page.
        shutter.tap()
        XCTAssertTrue(app.item("corners.use").waitForExistence(timeout: 60))
        app.item("corners.use").tap()
        let pages = app.item("scan.pages")
        XCTAssertTrue(waitForLabel(pages, "1 page"))
        // And the whole photo is a page too.
        shutter.tap()
        XCTAssertTrue(app.item("corners.whole").waitForExistence(timeout: 60))
        app.item("corners.whole").tap()
        XCTAssertTrue(waitForLabel(pages, "2 pages"))
    }

    @MainActor
    private func waitForNonexistence(_ element: XCUIElement, timeout: TimeInterval = 30) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 60) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
