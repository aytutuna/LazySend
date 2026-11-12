import Foundation
import CryptoKit

/// The fingerprint a computer is pinned by: the SHA-256 of its certificate's SubjectPublicKeyInfo (the key,
/// not the whole certificate, so a renewed certificate with the same key keeps every pin). The
/// SubjectPublicKeyInfo is found by a small DER walk over the certificate's bytes (what
/// `SecCertificateCopyData` returns), so the phone hashes the same bytes as .NET's
/// `PublicKey.ExportSubjectPublicKeyInfo` does on the computer.
public enum SpkiFingerprint {
    public static let byteCount = 32

    /// The SubjectPublicKeyInfo (its whole DER element) of the X.509 certificate `certificateDER`;
    /// nil when the bytes are not one well-formed certificate. Walks Certificate, tbsCertificate,
    /// [0] version (optional), serialNumber, signature, issuer, validity, subject, then
    /// subjectPublicKeyInfo, checking every length against its parent.
    public static func subjectPublicKeyInfo(_ certificateDER: Data) -> Data? {
        let der = [UInt8](certificateDER)
        guard let certificate = readElement(der, offset: 0, limit: der.count),
              certificate.tag == 0x30, certificate.end == der.count,
              let tbs = readElement(der, offset: certificate.contentStart, limit: certificate.end), tbs.tag == 0x30
        else { return nil }
        var position = tbs.contentStart
        if position < tbs.end && der[position] == 0xA0 {
            guard let version = readElement(der, offset: position, limit: tbs.end) else { return nil }
            position = version.end
        }
        // serialNumber INTEGER, signature SEQUENCE, issuer SEQUENCE, validity SEQUENCE, subject SEQUENCE.
        for tag: UInt8 in [0x02, 0x30, 0x30, 0x30, 0x30] {
            guard let element = readElement(der, offset: position, limit: tbs.end), element.tag == tag else { return nil }
            position = element.end
        }
        // SubjectPublicKeyInfo ::= SEQUENCE { algorithm AlgorithmIdentifier, subjectPublicKey BIT STRING }.
        guard let spki = readElement(der, offset: position, limit: tbs.end), spki.tag == 0x30,
              let algorithm = readElement(der, offset: spki.contentStart, limit: spki.end), algorithm.tag == 0x30,
              let key = readElement(der, offset: algorithm.end, limit: spki.end), key.tag == 0x03,
              key.end == spki.end
        else { return nil }
        return Data(der[position..<spki.end])
    }

    public static func of(_ certificateDER: Data) -> Data? {
        subjectPublicKeyInfo(certificateDER).map(ofSubjectPublicKeyInfo)
    }

    public static func ofSubjectPublicKeyInfo(_ spki: Data) -> Data {
        Data(SHA256.hash(data: spki))
    }

    /// Whether two fingerprints are the same, in time that does not depend on where they differ.
    public static func matches(_ fingerprint: Data, _ expected: Data) -> Bool {
        let a = [UInt8](fingerprint)
        let b = [UInt8](expected)
        guard a.count == byteCount, b.count == byteCount else { return false }
        var difference: UInt8 = 0
        for i in 0..<byteCount {
            difference |= a[i] ^ b[i]
        }
        return difference == 0
    }

    /// The six digits the computer shows as well, so a person can see both ends hold the same key: the
    /// fingerprint's first four bytes as a big-endian number, modulo one million ("004 213").
    public static func checkCode(_ fingerprint: Data) -> String {
        let bytes = [UInt8](fingerprint)
        guard bytes.count >= 4 else { return "" }
        let value = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        let code = String(format: "%06d", value % 1_000_000)
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    /// One DER element: its tag, where its content starts and where it ends (exclusive).
    struct Element {
        let tag: UInt8
        let contentStart: Int
        let end: Int
    }

    /// The DER element at `offset`, which must end by `limit`. Low tag numbers only; definite lengths
    /// in short form or long form of up to four bytes.
    static func readElement(_ der: [UInt8], offset: Int, limit: Int) -> Element? {
        guard offset >= 0, limit <= der.count, offset + 2 <= limit else { return nil }
        let tag = der[offset]
        guard tag & 0x1F != 0x1F else { return nil }
        var position = offset + 1
        let first = der[position]
        position += 1
        var length = 0
        if first < 0x80 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            guard count > 0, count <= 4, position + count <= limit else { return nil }
            for _ in 0..<count {
                length = (length << 8) | Int(der[position])
                position += 1
            }
        }
        guard length <= limit - position else { return nil }
        return Element(tag: tag, contentStart: position, end: position + length)
    }
}
