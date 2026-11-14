import Foundation

public enum PairingError: Error, LocalizedError, Equatable {
    case unreachable
    /// The computer refused: declined, expired, used, closed or too many phones (its own message).
    case refused(String)
    case notKept
    /// The user saw different digits on the two screens, so the short code was never sent.
    case notConfirmed

    public var errorDescription: String? {
        switch self {
        case .unreachable:
            return "Could not reach your PC. Both need to be on the same Wi-Fi, the phone's hotspot or a USB tether."
        case .refused(let message): return message
        case .notKept: return "The pairing could not be saved on this phone."
        case .notConfirmed: return "Cancelled: the digits did not match, so nothing was sent."
        }
    }
}

public enum Pairing {
    /// Pairs with the computer in `code`: the first address that answers with its key gets the request, and
    /// the computer's user is asked to approve it. The pairing is kept only once its secret is saved.
    public static func pair(_ code: PairingCode, phoneName: String, appVersion: String, platform: String = "ios",
                            connector: PcConnector, store: PcStore) async throws -> PairedPc {
        guard store.secretsAvailable else { throw PairingError.notKept }
        guard let reached = await connector.reachForPairing(addresses: code.addresses, port: code.port, pin: code.pin) else {
            throw PairingError.unreachable
        }
        return try await finish(token: code.token, client: reached.client, host: reached.host, pin: code.pin, desktopId: code.desktopId,
                                name: code.name, known: code.addresses, port: code.port, phoneName: phoneName,
                                appVersion: appVersion, platform: platform, store: store)
    }

    /// Pairs with `host` by the short code its screen shows. Its key is not known yet, so it is taken from the first
    /// answer and `confirm` gets the six digits worked out from it and the code: the user checks them against the
    /// host's screen, and the code is not sent unless the answer is yes. The pairing request then goes over a
    /// connection pinned to the key that was met.
    public static func pair(code typed: String, with host: NearbyHost, phoneName: String, appVersion: String, platform: String,
                            confirm: (String) async -> Bool, connector: PcConnector, store: PcStore) async throws -> PairedPc {
        guard store.secretsAvailable else { throw PairingError.notKept }
        guard let code = ShortCode.normalize(typed) else {
            throw PairingError.refused("A code is 8 letters and digits, like 7KQ2-M9XD.")
        }
        guard let met = await connector.reachUnpinned(addresses: host.addresses, port: host.port) else { throw PairingError.unreachable }
        guard await confirm(SpkiFingerprint.matchCode(met.fingerprint, shortCode: code)) else { throw PairingError.notConfirmed }
        let client = LinkClient(endpoint: met.reached.client.endpoint, pin: met.fingerprint)
        return try await finish(token: code, client: client, host: met.reached.host, pin: met.fingerprint, desktopId: host.id,
                                name: host.name, known: host.addresses, port: host.port, phoneName: phoneName,
                                appVersion: appVersion, platform: platform, store: store)
    }

    private static func finish(token: String, client: LinkClient, host: String, pin: Data, desktopId: String, name: String, known: [String],
                               port: Int, phoneName: String, appVersion: String, platform: String, store: PcStore) async throws -> PairedPc {
        let answer: PairResponse
        do {
            answer = try await client.pair(token: token, phoneId: store.phoneId, phoneName: phoneName, appVersion: appVersion, platform: platform)
        } catch let error as LinkError {
            switch error {
            case .refused: throw PairingError.refused(error.localizedDescription)
            case .network: throw PairingError.unreachable
            default: throw error
            }
        }
        guard answer.desktopId == desktopId, Base64Url.decode(answer.deviceSecret)?.count == 32 else { throw LinkError.badResponse }
        let shown = DisplayName.clean(answer.desktopName)
        let pc = PairedPc(id: answer.desktopId, name: shown.isEmpty ? name : shown, fingerprint: Base64Url.encode(pin),
                          addresses: AddressBook.merged(hello: [host], known: known), port: port, lastAddress: host)
        do {
            try store.put(pc, secret: answer.deviceSecret)
        } catch {
            let credentials = Credentials(deviceId: store.phoneId, secret: answer.deviceSecret)
            try? await LinkClient(endpoint: client.endpoint, pin: pin, credentials: credentials).forgetSelf()
            throw PairingError.notKept
        }
        return pc
    }
}
