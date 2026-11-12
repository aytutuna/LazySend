import Foundation
import Security
import LazySendKit

/// A certificate that could not be made.
public struct SelfSignedCertificateError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// A self-signed X.509 v3 certificate for a P-256 key: a random positive 16-byte serial,
/// ecdsa-with-SHA256, issuer and subject CN "<host name> Lazy Send", valid from a day before
/// `now` for `validity`, basicConstraints CA false and keyUsage digitalSignature (both critical),
/// extKeyUsage serverAuth, and subjectAltName with the host name when it is a DNS name.
public enum SelfSignedCertificate {
    public static let validity: TimeInterval = 825 * 24 * 60 * 60
    /// How long before `now` the certificate is valid from, for clocks a little behind.
    public static let backdate: TimeInterval = 24 * 60 * 60

    static let ecdsaWithSha256: [UInt64] = [1, 2, 840, 10045, 4, 3, 2]
    static let commonNameOid: [UInt64] = [2, 5, 4, 3]
    static let basicConstraintsOid: [UInt64] = [2, 5, 29, 19]
    static let keyUsageOid: [UInt64] = [2, 5, 29, 15]
    static let extKeyUsageOid: [UInt64] = [2, 5, 29, 37]
    static let subjectAltNameOid: [UInt64] = [2, 5, 29, 17]
    static let serverAuthOid: [UInt64] = [1, 3, 6, 1, 5, 5, 7, 3, 1]

    /// "AYTU-MAC Lazy Send".
    public static func commonName(hostName: String) -> String {
        "\(hostName) Lazy Send"
    }

    /// The certificate's DER for the P-256 private key `key`, signed with it.
    public static func make(hostName: String, key: SecKey, now: Date) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(key),
              let point = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              let spki = SpkiFingerprint.p256SubjectPublicKeyInfo(point)
        else { throw SelfSignedCertificateError("The key is not a P-256 key.") }
        var generator = SystemRandomNumberGenerator()
        var serial: [UInt8] = []
        for _ in 0..<16 {
            serial.append(UInt8.random(in: UInt8.min...UInt8.max, using: &generator))
        }
        // Positive, and 16 bytes long in DER (no leading zero to strip).
        serial[0] = (serial[0] & 0x7F) | 0x40
        let name = DerWriter.sequence([
            DerWriter.set([DerWriter.sequence([DerWriter.oid(commonNameOid), DerWriter.utf8String(commonName(hostName: hostName))])]),
        ])
        let algorithm = DerWriter.sequence([DerWriter.oid(ecdsaWithSha256)])
        let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 - backdate).rounded(.down))
        let end = Date(timeIntervalSince1970: (now.timeIntervalSince1970 + validity).rounded(.down))
        var extensions: [[UInt8]] = [
            DerWriter.certificateExtension(basicConstraintsOid, critical: true, value: DerWriter.sequence([])),
            // digitalSignature is bit 0: one byte with the seven bits after it unused.
            DerWriter.certificateExtension(keyUsageOid, critical: true, value: DerWriter.bitString([0x80], unusedBits: 7)),
            DerWriter.certificateExtension(extKeyUsageOid, critical: false,
                                           value: DerWriter.sequence([DerWriter.oid(serverAuthOid)])),
        ]
        if isDnsName(hostName) {
            // GeneralName dNSName is [2] IMPLICIT IA5String.
            let dnsName = DerWriter.element(0x82, Array(hostName.utf8))
            extensions.append(DerWriter.certificateExtension(subjectAltNameOid, critical: false,
                                                             value: DerWriter.sequence([dnsName])))
        }
        let tbs = DerWriter.sequence([
            DerWriter.explicit(0, DerWriter.integer([2])),
            DerWriter.integer(serial),
            algorithm,
            name,
            DerWriter.sequence([DerWriter.time(start), DerWriter.time(end)]),
            name,
            [UInt8](spki),
            DerWriter.explicit(3, DerWriter.sequence(extensions)),
        ])
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, Data(tbs) as CFData, &error) as Data?
        else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw SelfSignedCertificateError("The certificate could not be signed: \(reason)")
        }
        return Data(DerWriter.sequence([tbs, algorithm, DerWriter.bitString([UInt8](signature))]))
    }

    /// When the certificate `der` expires; nil when it is not a certificate or its time is not
    /// UTCTime or GeneralizedTime in UTC to the second.
    public static func notAfter(_ der: Data) -> Date? {
        validityPeriod(der)?.notAfter
    }

    /// When the certificate `der` is valid from and until; nil as for `notAfter`.
    static func validityPeriod(_ der: Data) -> (notBefore: Date, notAfter: Date)? {
        let bytes = [UInt8](der)
        guard let certificate = SpkiFingerprint.readElement(bytes, offset: 0, limit: bytes.count), certificate.tag == 0x30,
              let tbs = SpkiFingerprint.readElement(bytes, offset: certificate.contentStart, limit: certificate.end),
              tbs.tag == 0x30
        else { return nil }
        var position = tbs.contentStart
        if position < tbs.end && bytes[position] == 0xA0 {
            guard let version = SpkiFingerprint.readElement(bytes, offset: position, limit: tbs.end) else { return nil }
            position = version.end
        }
        // serialNumber INTEGER, signature SEQUENCE, issuer SEQUENCE.
        let skipped: [UInt8] = [0x02, 0x30, 0x30]
        for tag in skipped {
            guard let element = SpkiFingerprint.readElement(bytes, offset: position, limit: tbs.end), element.tag == tag else {
                return nil
            }
            position = element.end
        }
        guard let period = SpkiFingerprint.readElement(bytes, offset: position, limit: tbs.end), period.tag == 0x30,
              let first = SpkiFingerprint.readElement(bytes, offset: period.contentStart, limit: period.end),
              let second = SpkiFingerprint.readElement(bytes, offset: first.end, limit: period.end),
              let notBefore = parseTime(first.tag, bytes[first.contentStart..<first.end]),
              let notAfter = parseTime(second.tag, bytes[second.contentStart..<second.end])
        else { return nil }
        return (notBefore, notAfter)
    }

    /// The certificate `der` for the Security framework; nil when it does not read it.
    public static func certificate(_ der: Data) -> SecCertificate? {
        SecCertificateCreateWithData(nil, der as CFData)
    }

    /// The DER of an identity's certificate; nil when it has none.
    public static func der(of identity: SecIdentity) -> Data? {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let found = certificate else { return nil }
        return SecCertificateCopyData(found) as Data
    }

    /// Letters, digits and '-' in dot-separated labels of 1 to 63 characters, 253 at most.
    static func isDnsName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 253 else { return false }
        for label in name.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty, label.utf8.count <= 63, label.first != "-", label.last != "-" else { return false }
            for byte in label.utf8 {
                switch byte {
                case 97...122, 65...90, 48...57, 45: continue
                default: return false
                }
            }
        }
        return true
    }

    private static func parseTime(_ tag: UInt8, _ text: ArraySlice<UInt8>) -> Date? {
        let digits = Array(text)
        guard digits.last == UInt8(ascii: "Z") else { return nil }
        var values: [Int] = []
        for byte in digits.dropLast() {
            guard byte >= 48 && byte <= 57 else { return nil }
            values.append(Int(byte) - 48)
        }
        var components = DateComponents()
        var rest: ArraySlice<Int>
        if tag == 0x17 && values.count == 12 {
            let year = values[0] * 10 + values[1]
            components.year = year < 50 ? 2000 + year : 1900 + year
            rest = values[2...]
        } else if tag == 0x18 && values.count == 14 {
            components.year = values[0] * 1000 + values[1] * 100 + values[2] * 10 + values[3]
            rest = values[4...]
        } else {
            return nil
        }
        var fields: [Int] = []
        while let first = rest.first {
            fields.append(first * 10 + rest[rest.startIndex + 1])
            rest = rest.dropFirst(2)
        }
        components.month = fields[0]
        components.day = fields[1]
        components.hour = fields[2]
        components.minute = fields[3]
        components.second = fields[4]
        return DerWriter.utc.date(from: components)
    }
}

/// The few DER encodings a certificate needs (X.690): definite lengths, low tag numbers.
enum DerWriter {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func element(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var rest = count
        while rest > 0 {
            bytes.insert(UInt8(rest & 0xFF), at: 0)
            rest >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func sequence(_ parts: [[UInt8]]) -> [UInt8] {
        element(0x30, Array(parts.joined()))
    }

    /// A SET of one element, or of elements already in DER order.
    static func set(_ parts: [[UInt8]]) -> [UInt8] {
        element(0x31, Array(parts.joined()))
    }

    /// A non-negative INTEGER from its big-endian bytes, in the fewest bytes that keep it positive.
    static func integer(_ bytes: [UInt8]) -> [UInt8] {
        var content = Array(bytes.drop(while: { $0 == 0 }))
        if content.isEmpty || content[0] & 0x80 != 0 { content.insert(0, at: 0) }
        return element(0x02, content)
    }

    static func boolean(_ value: Bool) -> [UInt8] {
        element(0x01, [value ? 0xFF : 0x00])
    }

    static func bitString(_ bytes: [UInt8], unusedBits: UInt8 = 0) -> [UInt8] {
        element(0x03, [unusedBits] + bytes)
    }

    static func octetString(_ bytes: [UInt8]) -> [UInt8] {
        element(0x04, bytes)
    }

    static func utf8String(_ text: String) -> [UInt8] {
        element(0x0C, Array(text.utf8))
    }

    static func oid(_ arcs: [UInt64]) -> [UInt8] {
        var content: [UInt8] = []
        var values: [UInt64] = [arcs[0] * 40 + arcs[1]]
        values.append(contentsOf: arcs.dropFirst(2))
        for value in values {
            var chunk: [UInt8] = [UInt8(value & 0x7F)]
            var rest = value >> 7
            while rest > 0 {
                chunk.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
                rest >>= 7
            }
            content.append(contentsOf: chunk)
        }
        return element(0x06, content)
    }

    /// UTCTime for the years 1950 to 2049, GeneralizedTime otherwise (RFC 5280), to the second in UTC.
    static func time(_ date: Date) -> [UInt8] {
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = c.year ?? 1970
        let rest = String(format: "%02d%02d%02d%02d%02dZ", c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        if year >= 1950 && year < 2050 {
            return element(0x17, Array((String(format: "%02d", year % 100) + rest).utf8))
        }
        return element(0x18, Array((String(format: "%04d", year) + rest).utf8))
    }

    /// [n] EXPLICIT: a constructed context-specific tag around `content`.
    static func explicit(_ number: UInt8, _ content: [UInt8]) -> [UInt8] {
        element(0xA0 | number, content)
    }

    /// Extension ::= SEQUENCE { extnID, critical BOOLEAN DEFAULT FALSE, extnValue OCTET STRING }.
    static func certificateExtension(_ oid: [UInt64], critical: Bool, value: [UInt8]) -> [UInt8] {
        var parts = [self.oid(oid)]
        if critical { parts.append(boolean(true)) }
        parts.append(octetString(value))
        return sequence(parts)
    }
}
