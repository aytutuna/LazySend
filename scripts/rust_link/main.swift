import CryptoKit
import Foundation
import Security

// Checks the Rust link core through its UniFFI Swift bindings; scripts/rust_link_swift.sh builds both and passes the testdata/link folder.

var failures: [String] = []

func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition { failures.append(message()) }
}

func load(_ file: String) -> Any {
    let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(file)
    return try! JSONSerialization.jsonObject(with: Data(contentsOf: url))
}

func bytes(_ values: Any) -> Data {
    Data((values as! [Int]).map { UInt8($0) })
}

func fromBase64Url(_ text: String) -> Data {
    var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while base.count % 4 != 0 { base += "=" }
    return Data(base64Encoded: base)!
}

func hex(_ data: some Sequence<UInt8>) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

func pairingCodes() {
    let cases = (load("pairing-uris.json") as! [String: Any])["cases"] as! [[String: Any]]
    for c in cases {
        let name = c["name"] as! String
        let result = c["result"] as! String
        let uri = c["uri"] as! String
        if result != "ok" {
            do {
                _ = try parsePairingCode(text: uri)
                check(false, "\(name): expected \(result)")
            } catch let error as LinkError {
                check("\(error)".lowercased() == result.lowercased(), "\(name): got \(error)")
            } catch {
                check(false, "\(name): got \(error)")
            }
            continue
        }
        do {
            let code = try parsePairingCode(text: uri)
            let want = c["pairing"] as! [String: Any]
            check(code.desktopId == want["desktopId"] as! String, "\(name): desktop id")
            check(code.name == want["name"] as! String, "\(name): name")
            check(code.fingerprint == want["fingerprint"] as! String, "\(name): fingerprint")
            check(code.addresses == want["addresses"] as! [String], "\(name): addresses")
            check(Int(code.port) == want["port"] as! Int, "\(name): port")
            check(code.token == want["token"] as! String, "\(name): token")
            check(try checkCode(fingerprint: fromBase64Url(code.fingerprint)) == want["checkCode"] as! String, "\(name): check code")
            let written = try formatPairingCode(code: code)
            check(try formatPairingCode(code: parsePairingCode(text: written)) == written, "\(name): format and read again")
        } catch {
            check(false, "\(name): \(error)")
        }
    }
}

func checkCodes() throws {
    let cases = (load("check-codes.json") as! [String: Any])["cases"] as! [[String: Any]]
    for c in cases {
        let fingerprint = bytes(c["fingerprint"]!)
        check(try checkCode(fingerprint: fingerprint) == c["checkCode"] as! String, "check code")
        check(try matchCode(fingerprint: fingerprint, shortCode: c["shortCode"] as! String) == c["matchCode"] as! String, "match code")
    }
}

func shortCodes() throws {
    let data = load("short-codes.json") as! [String: Any]
    for n in data["normalize"] as! [[String: Any]] {
        guard let typed = n["typed"] as? String else { continue }
        check(try normalizeShortCode(text: typed) == n["canonical"] as? String, "normalize \(typed)")
    }
    let token = bytes(data["tokenBytes"]!)
    for r in data["redeem"] as! [[String: Any]] {
        let session = try PairingSession(openedMs: 0, token: token, codeEntropy: Data([7, 3, 21, 0, 9, 31, 12, 5]))
        let code = session.shortCode()
        let typedCode = (code.prefix(4) + "-" + code.dropFirst(4)).lowercased()
        for a in r["attempts"] as! [[String: Any]] {
            let presented: String?
            switch a["token"] as? String {
            case "$token": presented = session.token()
            case "$shortCode": presented = code
            case "$shortCodeTyped": presented = typedCode
            default: presented = a["token"] as? String
            }
            let got = try session.redeem(token: presented, nowMs: Int64(a["at"] as! Int) * 1000, peer: a["peer"] as? String)
            check("\(got)".lowercased() == (a["expect"] as! String).lowercased(), "\(r["name"] as! String): expected \(a["expect"] as! String), got \(got)")
        }
    }
}

// The key stays in the Security framework: Rust only sees the hash going out and the signature coming back.
func makeKey() -> (SecKey, SecKey) {
    let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256]
    let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
    return (key, SecKeyCopyPublicKey(key)!)
}

func verifies(_ key: SecKey, _ data: Data, _ signature: Data) -> Bool {
    SecKeyVerifySignature(key, .ecdsaSignatureMessageX962SHA256, data as CFData, signature as CFData, nil)
}

func signature(_ key: SecKey, _ hash: Data) -> Data {
    SecKeyCreateSignature(key, .ecdsaSignatureDigestX962SHA256, hash as CFData, nil)! as Data
}

final class KeySigner: Signer, @unchecked Sendable {
    let key: SecKey
    init(_ key: SecKey) { self.key = key }

    func sign(hash: Data) throws -> Data { signature(key, hash) }
}

final class SlowKeySigner: AsyncSigner, @unchecked Sendable {
    let key: SecKey
    init(_ key: SecKey) { self.key = key }

    func sign(hash: Data) async throws -> Data {
        try await Task.sleep(nanoseconds: 20_000_000)
        return signature(key, hash)
    }
}

struct Locked: Error {}

final class LockedSigner: Signer, @unchecked Sendable {
    func sign(hash: Data) throws -> Data { throw Locked() }
}

func signing() async throws {
    let (key, publicKey) = makeKey()
    let signer = KeySigner(key)
    let slow = SlowKeySigner(key)
    let data = Data([1, 2, 3, 4, 5])
    check(verifies(publicKey, data, try signData(signer: signer, data: data)), "signature from the native signer")
    let later = Data([9, 8, 7])
    check(verifies(publicKey, later, try await signDataAsync(signer: slow, data: later)), "signature from the async signer")
    do {
        _ = try signData(signer: LockedSigner(), data: Data([1]))
        check(false, "a signer that throws should fail the call")
    } catch LinkError.Unexpected {
    } catch {
        check(false, "a signer that throws: got \(error)")
    }
}

func panics() throws {
    do {
        _ = try panicNow(message: "boom")
        check(false, "expected a panic to throw")
    } catch {
        check("\(error)".contains("boom"), "the panic message: \(error)")
    }
    check(try checkCode(fingerprint: Data([1])) == "", "the library after a panic")
}

func bigBuffers() throws {
    let size = 50 * 1024 * 1024
    let data = Data((0..<size).map { UInt8($0 % 251) })
    check(try hashBytes(data: data) == hex(SHA256.hash(data: data)), "hash of 50 MB")
    check(try patternBytes(len: UInt32(size)) == data, "50 MB back")
}

pairingCodes()
try checkCodes()
try shortCodes()
try await signing()
try panics()
try bigBuffers()

if failures.isEmpty {
    print("all checks passed")
} else {
    for f in failures { print("FAIL \(f)") }
    exit(1)
}
