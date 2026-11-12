import Foundation

public enum PairingCodeProblem: Equatable {
    case notPairingCode
    case newerVersion
    case damaged
}

public struct PairingCodeError: Error, LocalizedError, Equatable {
    public let problem: PairingCodeProblem
    public let message: String

    public var errorDescription: String? { message }

    static let notPairingCode = PairingCodeError(problem: .notPairingCode, message: "This is not a Lazy Send pairing code.")
    static let newerVersion = PairingCodeError(
        problem: .newerVersion,
        message: "This pairing code is from a newer version of Lazy Send. Update the app on this phone, then scan it again.")
    static let damaged = PairingCodeError(
        problem: .damaged,
        message: "This pairing code could not be read. Show the code on the computer again and scan it once more.")
}

/// What the computer's QR code carries: `lazysend://pair?v=1&id=&n=&fp=&a=&p=&t=`.
public struct PairingCode: Equatable {
    public var desktopId: String
    public var name: String
    public var fingerprint: String
    public var addresses: [String]
    public var port: Int
    public var token: String

    static let prefix = "lazysend://pair?"
    static let maxLength = 2048

    public var pin: Data { Base64Url.decode(fingerprint) ?? Data() }

    public var checkCode: String { SpkiFingerprint.checkCode(pin) }

    public static func looksLikeCode(_ text: String) -> Bool {
        text.lowercased().hasPrefix(prefix)
    }

    public static func parse(_ text: String) throws -> PairingCode {
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.lowercased().hasPrefix("lazysend:") else { throw PairingCodeError.notPairingCode }
        let printable = code.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
        guard code.utf8.count <= maxLength, code.lowercased().hasPrefix(prefix), printable, !code.contains("#") else {
            throw PairingCodeError.damaged
        }
        var raw: [String: String] = [:]
        for part in code.dropFirst(prefix.count).split(separator: "&", omittingEmptySubsequences: true) {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(pieces[0])
            let value = pieces.count > 1 ? String(pieces[1]) : ""
            guard !key.isEmpty, percentDecode(value) != nil, raw[key] == nil else { throw PairingCodeError.damaged }
            raw[key] = value
        }
        func value(_ key: String) -> String? { raw[key].flatMap(percentDecode) }

        guard let version = value("v").flatMap({ Int($0) }) else { throw PairingCodeError.damaged }
        if version > LinkProtocol.version { throw PairingCodeError.newerVersion }
        guard version >= 1, let id = value("id"), let name = value("n"), let fp = value("fp"),
              let port = value("p").flatMap({ Int($0) }), let token = value("t") else { throw PairingCodeError.damaged }
        var addresses: [String] = []
        if let list = raw["a"], !list.isEmpty {
            for item in list.split(separator: ",", omittingEmptySubsequences: false) {
                guard let address = percentDecode(String(item)) else { throw PairingCodeError.damaged }
                addresses.append(address)
            }
        }
        guard Base64Url.decode(fp)?.count == SpkiFingerprint.byteCount, (1...65535).contains(port),
              Base64Url.decode(token)?.count == 16 else { throw PairingCodeError.damaged }
        return PairingCode(desktopId: id, name: name, fingerprint: fp, addresses: addresses, port: port, token: token)
    }
}

func percentDecode(_ text: String) -> String? {
    var bytes: [UInt8] = []
    let input = Array(text.utf8)
    var i = 0
    while i < input.count {
        if input[i] == UInt8(ascii: "%") {
            guard i + 2 < input.count, let high = hexValue(input[i + 1]), let low = hexValue(input[i + 2]) else { return nil }
            bytes.append(UInt8(high * 16 + low))
            i += 3
        } else {
            bytes.append(input[i])
            i += 1
        }
    }
    return String(bytes: bytes, encoding: .utf8)
}

private func hexValue(_ byte: UInt8) -> Int? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(byte - UInt8(ascii: "0"))
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return Int(byte - UInt8(ascii: "a")) + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return Int(byte - UInt8(ascii: "A")) + 10
    default: return nil
    }
}

public enum Base64Url {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    /// Nil unless `text` is exactly what `encode` writes (no padding, no stray characters).
    public static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), encode(data) == text else { return nil }
        return data
    }
}
