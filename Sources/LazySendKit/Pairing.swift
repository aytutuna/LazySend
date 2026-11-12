import Foundation

public enum PairingError: Error, LocalizedError, Equatable {
    case unreachable
    /// The computer refused: declined, expired, used, closed or too many phones (its own message).
    case refused(String)
    case notKept

    public var errorDescription: String? {
        switch self {
        case .unreachable:
            return "Could not reach your PC. Both need to be on the same Wi-Fi, the phone's hotspot or a USB tether."
        case .refused(let message): return message
        case .notKept: return "The pairing could not be saved on this phone."
        }
    }
}

public enum Pairing {
    /// Pairs with the computer in `code`: the first address that answers with its key gets the request, and
    /// the computer's user is asked to approve it. The pairing is kept only once its secret is saved.
    public static func pair(_ code: PairingCode, phoneName: String, appVersion: String, connector: PcConnector, store: PcStore) async throws -> PairedPc {
        guard let reached = await connector.reachForPairing(addresses: code.addresses, port: code.port, pin: code.pin) else {
            throw PairingError.unreachable
        }
        let answer: PairResponse
        do {
            answer = try await reached.client.pair(token: code.token, phoneId: store.phoneId, phoneName: phoneName, appVersion: appVersion)
        } catch let error as LinkError {
            switch error {
            case .refused: throw PairingError.refused(error.localizedDescription)
            case .network: throw PairingError.unreachable
            default: throw error
            }
        }
        guard answer.desktopId == code.desktopId, Base64Url.decode(answer.deviceSecret)?.count == 32 else { throw LinkError.badResponse }
        let pc = PairedPc(id: answer.desktopId, name: answer.desktopName.isEmpty ? code.name : answer.desktopName, fingerprint: code.fingerprint,
                          addresses: AddressBook.merged(hello: [reached.host], known: code.addresses), port: code.port, lastAddress: reached.host)
        do {
            try store.put(pc, secret: answer.deviceSecret)
        } catch {
            let credentials = Credentials(deviceId: store.phoneId, secret: answer.deviceSecret)
            try? await LinkClient(endpoint: reached.client.endpoint, pin: code.pin, credentials: credentials).forgetSelf()
            throw PairingError.notKept
        }
        return pc
    }
}
