import XCTest
@testable import LazySendKit

final class PcStoreTests: XCTestCase {
    private let pc = PairedPc(id: "pc-1", name: "Office PC", fingerprint: Base64Url.encode(Data(repeating: 3, count: 32)), addresses: ["10.0.0.2"], port: 52734)

    func testAKeychainThatCannotBeReadLeavesEverythingAlone() throws {
        let secrets = MemorySecrets()
        let file = try temporaryFolder().appendingPathComponent("pcs.json")
        let first = PcStore(file: file, secrets: secrets)
        try first.put(pc, secret: "secret")
        let phone = first.phoneId
        let before = try Data(contentsOf: file)

        secrets.failsLoads = true
        let locked = PcStore(file: file, secrets: secrets)
        XCTAssertFalse(locked.secretsAvailable)
        XCTAssertNil(locked.secret(for: pc.id))
        XCTAssertEqual(locked.pcs, [pc])
        XCTAssertThrowsError(try locked.put(pc, secret: "other"))
        XCTAssertEqual(try Data(contentsOf: file), before)

        secrets.failsLoads = false
        XCTAssertEqual(try secrets.load(for: pc.id), Data("secret".utf8))
        XCTAssertEqual(locked.secret(for: pc.id), "secret")
        XCTAssertEqual(locked.phoneId, phone)
        XCTAssertEqual(locked.pcs, [pc])
    }

    func testAMissingSecretStillStartsOver() throws {
        let secrets = MemorySecrets()
        let file = try temporaryFolder().appendingPathComponent("pcs.json")
        let first = PcStore(file: file, secrets: secrets)
        try first.put(pc, secret: "secret")
        try secrets.delete(for: pc.id)

        let second = PcStore(file: file, secrets: secrets)
        XCTAssertTrue(second.pcs.isEmpty)
        XCTAssertNotEqual(second.phoneId, first.phoneId)
    }
}
