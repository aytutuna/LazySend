import XCTest
@testable import LazySendKit

final class ConnectorTests: XCTestCase {
    private func store(for pc: FakePc, addresses: [String], last: String? = nil) throws -> PcStore {
        // The fake knows this phone by its id, so the store has to start with that one.
        let secrets = MemorySecrets()
        try secrets.save(Data(pc.phoneId.utf8), for: "phone-id")
        let store = PcStore(file: try temporaryFolder().appendingPathComponent("pcs.json"), secrets: secrets)
        try store.put(PairedPc(id: pc.desktopId, name: "Test PC", fingerprint: Base64Url.encode(pc.pin), addresses: addresses,
                               port: pc.server.port, lastAddress: last), secret: pc.secret)
        XCTAssertEqual(store.phoneId, pc.phoneId)
        return store
    }

    private func quiet(announced: [String: NearbyHost] = [:], probed: [String] = []) -> Discovery {
        Discovery(announced: { _ in announced }, subnets: { [Subnet(name: "en0", address: ipv4ToInt("127.0.0.9")!, prefix: 8)] }, probe: { _, _ in probed })
    }

    func testReachesTheLastAddressAndLearnsTheComputersOwnList() async throws {
        let pc = try FakePc()
        let store = try store(for: pc, addresses: ["10.255.255.1"], last: "127.0.0.1")
        let connector = PcConnector(store: store, discovery: quiet())
        let reach = await connector.connect(store.pcs[0], search: false)
        XCTAssertEqual(reach.reached?.host, "127.0.0.1")
        XCTAssertEqual(store.pcs[0].lastAddress, "127.0.0.1")
        XCTAssertEqual(store.pcs[0].addresses, ["127.0.0.1", "172.20.10.2", "10.255.255.1"])
    }

    func testAPhoneThePcForgotIsForgotten() async throws {
        let pc = try FakePc()
        pc.knowsPhone = false
        let store = try store(for: pc, addresses: ["127.0.0.1"])
        let reach = await PcConnector(store: store, discovery: quiet()).connect(store.pcs[0])
        guard case .forgotten = reach else { return XCTFail("Expected forgotten, got \(reach)") }
    }

    func testFindsTheComputerByAnnouncement() async throws {
        let pc = try FakePc()
        let store = try store(for: pc, addresses: [])
        let announced = [pc.desktopId: NearbyHost(id: pc.desktopId, name: "Test PC", addresses: ["127.0.0.1"], port: pc.server.port)]
        let connector = PcConnector(store: store, discovery: quiet(announced: announced))
        let reach = await connector.connect(store.pcs[0])
        XCTAssertEqual(reach.reached?.host, "127.0.0.1")
    }

    func testFollowsTheComputerToTheAnnouncedPort() async throws {
        let pc = try FakePc()
        let store = try store(for: pc, addresses: ["127.0.0.1"])
        store.update(pc.desktopId) { $0.port = 9 }
        let announced = [pc.desktopId: NearbyHost(id: pc.desktopId, name: "Test PC", addresses: ["127.0.0.1"], port: pc.server.port)]
        let connector = PcConnector(store: store, discovery: quiet(announced: announced))
        let reach = await connector.connect(store.pcs[0])
        XCTAssertEqual(reach.reached?.client.endpoint.port, pc.server.port)
        XCTAssertEqual(store.pcs[0].port, pc.server.port)
        XCTAssertEqual(store.pcs[0].lastAddress, "127.0.0.1")
    }

    func testFindsTheComputerByProbingTheLocalSubnets() async throws {
        let pc = try FakePc()
        let store = try store(for: pc, addresses: [])
        let connector = PcConnector(store: store, discovery: quiet(probed: ["127.0.0.1"]))
        let reach = await connector.connect(store.pcs[0])
        XCTAssertEqual(reach.reached?.host, "127.0.0.1")
    }

    func testNothingFoundIsUnreachable() async throws {
        let pc = try FakePc()
        let store = try store(for: pc, addresses: [])
        let reach = await PcConnector(store: store, discovery: quiet()).connect(store.pcs[0])
        guard case .unreachable = reach else { return XCTFail("Expected unreachable, got \(reach)") }
    }

    func testSearchIsNotRepeatedWithinItsBackOff() async throws {
        let pc = try FakePc()
        let store = try store(for: pc, addresses: [])
        let counter = Waits()
        let discovery = Discovery(announced: { _ in
            await counter.add(1)
            return [:]
        }, subnets: { [] }, probe: { _, _ in [] })
        let connector = PcConnector(store: store, discovery: discovery)
        _ = await connector.connect(store.pcs[0])
        _ = await connector.connect(store.pcs[0])
        let searches = await counter.values.count
        XCTAssertEqual(searches, 1)
        _ = await connector.connect(store.pcs[0], userAction: true)
        let again = await counter.values.count
        XCTAssertEqual(again, 1, "A person waiting may search again only after 10 seconds")
    }

    func testLinkKindFollowsTheInterfaceOfTheAddress() {
        let subnets = [
            Subnet(name: "en0", address: ipv4ToInt("192.168.1.20")!, prefix: 24),
            Subnet(name: "bridge100", address: ipv4ToInt("172.20.10.1")!, prefix: 28),
            Subnet(name: "en2", address: ipv4ToInt("10.0.0.5")!, prefix: 24),
        ]
        XCTAssertEqual(LocalNetworks.kind(of: "192.168.1.5", in: subnets), .wifi)
        XCTAssertEqual(LocalNetworks.kind(of: "172.20.10.2", in: subnets), .hotspot)
        XCTAssertEqual(LocalNetworks.kind(of: "10.0.0.9", in: subnets), .other)
        XCTAssertEqual(LocalNetworks.kind(of: "8.8.8.8", in: subnets), .other)
        XCTAssertEqual(LocalNetworks.kind(of: "fe80::1", in: subnets), .other)
    }

    func testProbesOnlyLocalInterfacesAndNeverThePhoneItself() {
        let subnets = [
            Subnet(name: "en0", address: ipv4ToInt("192.168.1.20")!, prefix: 24),
            Subnet(name: "bridge100", address: ipv4ToInt("172.20.10.1")!, prefix: 28),
            Subnet(name: "pdp_ip0", address: ipv4ToInt("100.70.1.1")!, prefix: 24),
            Subnet(name: "utun3", address: ipv4ToInt("10.8.0.2")!, prefix: 24),
        ]
        let hosts = LocalNetworks.probeCandidates(subnets)
        XCTAssertTrue(hosts.contains("192.168.1.1"))
        XCTAssertTrue(hosts.contains("192.168.1.254"))
        XCTAssertFalse(hosts.contains("192.168.1.20"))
        XCTAssertFalse(hosts.contains("192.168.1.0"))
        XCTAssertFalse(hosts.contains("192.168.1.255"))
        XCTAssertTrue(hosts.contains("172.20.10.2"))
        XCTAssertFalse(hosts.contains("172.20.10.1"))
        XCTAssertFalse(hosts.contains("172.20.10.16"))
        XCTAssertFalse(hosts.contains { $0.hasPrefix("100.70.") || $0.hasPrefix("10.8.") })
        XCTAssertEqual(hosts.count, 253 + 13)
    }

    func testProbeKeepsToItsLimit() async {
        let counter = Waits()
        let hosts = (1...100).map { "10.0.0.\($0)" }
        let found = await LocalNetworks.probe(hosts, port: 1, limit: 8, connect: { host, _ in
            await counter.add(0)
            return host.hasSuffix(".7")
        })
        XCTAssertEqual(found, ["10.0.0.7"])
        let attempts = await counter.values.count
        XCTAssertEqual(attempts, 100)
    }

    func testAddressOrder() {
        XCTAssertEqual(AddressBook.order(lastAddress: "b", known: ["a", "b", "c", "fe80::1%en0", "a"]), ["b", "a", "c"])
        XCTAssertEqual(AddressBook.order(lastAddress: nil, known: ["a"]), ["a"])
        XCTAssertEqual(AddressBook.merged(hello: ["h1", "a"], known: ["a", "b"]), ["h1", "a", "b"])
        let many = (1...12).map { "10.0.0.\($0)" }
        XCTAssertEqual(AddressBook.merged(hello: many, known: []).count, 8)
    }
}
