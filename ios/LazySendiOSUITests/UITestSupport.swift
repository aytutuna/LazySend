import XCTest

// The app is launched with `-uiTesting`: settings, secrets and the timeline are in a temp folder and nothing on the
// network is searched. The app opens on the Camera tab, so a test lands on the Files tab unless it asks for another (`tab: nil`
// stays on Camera). `-demoData` adds one paired PC that cannot be reached and a filled timeline. Elements are found by
// identifier among every element: toolbar items and some rows are not buttons in the Simulator's tree.

extension XCUIApplication {
    @MainActor
    static func launched(demo: Bool = false, approval: Bool = false, tab: String? = "Files", slowPairing: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"] + (demo ? ["-demoData"] : []) + (approval ? ["-demoApproval"] : []) + (slowPairing ? ["-slowPairing"] : [])
        app.launch()
        if let tab {
            let button = app.tabBars.buttons[tab]
            if button.waitForExistence(timeout: 30) { button.tap() }
        }
        return app
    }

    @MainActor
    func item(_ id: String) -> XCUIElement {
        descendants(matching: .any)[id].firstMatch
    }
}

extension XCTestCase {
    @MainActor
    func attach(_ app: XCUIApplication, as name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
