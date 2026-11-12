import XCTest

// The app is launched with `-uiTesting`: settings, secrets and the timeline are in a temp folder and nothing on the
// network is searched. `-demoData` adds one paired PC that cannot be reached and a filled timeline. Elements are found by
// identifier among every element: toolbar items and some rows are not buttons in the Simulator's tree.

extension XCUIApplication {
    @MainActor
    static func launched(demo: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"] + (demo ? ["-demoData"] : [])
        app.launch()
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
