import XCTest
@testable import LazySendKit

final class ShareQueueTests: XCTestCase {
    func testAFileCanBeMovedInOrCopied() throws {
        let queue = ShareQueue(root: try temporaryFolder())
        let source = try randomFile(in: try temporaryFolder(), bytes: 64)
        try queue.add(QueuedItem(id: "a", pcId: "pc", kind: "file", name: "x.bin"), file: source.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.url.path))
        try queue.add(QueuedItem(id: "b", pcId: "pc", kind: "file", name: "x.bin"), file: source.url, move: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.url.path))
        XCTAssertEqual(try Data(contentsOf: queue.dataURL("b")), source.data)
    }

    func testTheServerItemIdIsKept() throws {
        let queue = ShareQueue(root: try temporaryFolder())
        try queue.add(QueuedItem(id: "a", pcId: "pc", kind: "text", text: "hi"))
        XCTAssertNil(queue.items().first?.itemId)
        queue.update("a") { $0.itemId = "item7" }
        XCTAssertEqual(queue.items().first?.itemId, "item7")
        XCTAssertEqual(queue.items().first?.text, "hi")
    }
}

final class HostedPhonesTests: XCTestCase {
    func testTheListIsReadFromTheHostsDevicesFile() throws {
        let folder = try temporaryFolder()
        let json = #"{"desktopId":"abc12345","devices":[{"id":"phone-0001","name":"Pixel","platform":"android","secretHash":"x"}]}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("devices.json"))
        XCTAssertEqual(HostedPhones.read(in: folder), [HostedPhone(id: "phone-0001", name: "Pixel")])
    }

    func testNoFileOrAnUnreadableOneIsNoPhones() throws {
        let folder = try temporaryFolder()
        XCTAssertEqual(HostedPhones.read(in: folder), [])
        try Data("nonsense".utf8).write(to: folder.appendingPathComponent("devices.json"))
        XCTAssertEqual(HostedPhones.read(in: folder), [])
    }

    func testTargetsKeepThePhonesApartFromComputers() {
        XCTAssertEqual(HostedPhones.id(ofTarget: HostedPhones.target("abc12345")), "abc12345")
        XCTAssertNil(HostedPhones.id(ofTarget: "abc12345"))
    }
}
