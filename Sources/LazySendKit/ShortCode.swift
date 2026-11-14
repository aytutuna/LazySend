import CryptoKit
import Foundation

/// The short code of a pairing session, typed by a guest that cannot scan the QR code (CONTRACTS.md, "Short code").
public enum ShortCode {
    public static let length = 8
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// A short code as typed (any case, with dashes or spaces) in its canonical form; nil when it is not 8
    /// characters of the alphabet, which also tells it from a 22-character token.
    public static func normalize(_ text: String?) -> String? {
        guard let text = text, text.utf8.count <= 32 else { return nil }
        var code = ""
        for scalar in text.unicodeScalars {
            if scalar == "-" || scalar == " " { continue }
            let upper = scalar.value >= 97 && scalar.value <= 122 ? Unicode.Scalar(scalar.value - 32)! : scalar
            guard alphabet.contains(Character(upper)) else { return nil }
            code.unicodeScalars.append(upper)
        }
        return code.count == length ? code : nil
    }
}

extension SpkiFingerprint {
    /// The check code of a pairing by short code: the same six digits, taken from SHA-256 over the fingerprint
    /// and the canonical short code. A guest that typed the code has no fingerprint in advance, and a key can be
    /// ground until the plain check code of the real certificate comes out; the short code is not known when the
    /// certificate is chosen, so this cannot be ground.
    public static func matchCode(_ fingerprint: Data, shortCode: String) -> String {
        guard fingerprint.count == byteCount else { return "" }
        return checkCode(Data(SHA256.hash(data: fingerprint + Data(shortCode.utf8))))
    }
}
