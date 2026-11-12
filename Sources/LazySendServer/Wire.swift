import Foundation
import LazySendKit

enum Route {
    static let health = "/v1/health"
    static let pair = "/v1/pair"
    static let hello = "/v1/hello"
    static let deviceSelf = "/v1/devices/self"
    static let items = "/v1/items"
    static let itemsPrefix = "/v1/items/"
    static let galleryCheck = "/v1/gallery/check"
    static let outbox = "/v1/outbox"
    static let outboxPrefix = "/v1/outbox/"
    static let deviceIdHeader = "X-Device-Id"
    static let offsetHeader = "X-Offset"
}

public enum Limits {
    public static let maxSmallBody = 8192
    public static let maxItemBody = 8 * 1024 * 1024
    public static let maxGalleryBody = 512 * 1024
    public static let maxGalleryIds = 1000
    public static let maxUrlLength = 8192
    public static let maxSourceIdLength = 256
    public static let maxChunk: Int64 = 64 * 1024 * 1024
    public static let minFree: Int64 = 1024 * 1024 * 1024
    public static let maxOutboxItemsPerReply = 100
    public static let maxOutboxInlineBytes = 4 * 1024 * 1024
    public static let maxOutboxItemsPerDevice = 1000
    public static let maxDevices = 16
    public static let maxNameBytes = 128
}

enum ItemKind {
    static let text = "text"
    static let link = "link"
    static let file = "file"
}

public func isValidId(_ id: String?) -> Bool {
    guard let id = id, (8...64).contains(id.utf8.count) else { return false }
    return id.utf8.allSatisfy { byte in
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "_"):
            return true
        default:
            return false
        }
    }
}

func newId() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
}

func isAcceptableLink(_ url: String?) -> Bool {
    guard let url = url, !url.isEmpty, url.count <= Limits.maxUrlLength, let parsed = URL(string: url),
          let scheme = parsed.scheme?.lowercased() else { return false }
    return (scheme == "http" || scheme == "https") && parsed.host?.isEmpty == false
}

/// What went wrong, for the phone: a stable code and a sentence to show.
struct Failure: Codable, Error {
    var error: String
    var message: String
    var offset: Int64?

    static let unauthorized = Failure(error: "unauthorized", message: "This computer no longer recognizes this phone. Pair it again.")
    static let pairingClosed = Failure(error: "pairingClosed", message: "Pairing is not open on this computer. Choose Pair a phone there and scan the new code.")
    static let tokenInvalid = Failure(error: "tokenInvalid", message: "This pairing code is not valid. Scan the code shown on the computer again.")
    static let tokenExpired = Failure(error: "tokenExpired", message: "This pairing code has expired. Show a new code on the computer.")
    static let tokenUsed = Failure(error: "tokenUsed", message: "This pairing code was already used. Show a new code on the computer.")
    static let declined = Failure(error: "declined", message: "Pairing was declined on the computer.")
    static let tooManyDevices = Failure(error: "tooManyDevices", message: "This computer is paired with \(Limits.maxDevices) phones already. Remove one there first.")
    static let tooLarge = Failure(error: "tooLarge", message: "The request is larger than this computer takes.")
    static let rateLimited = Failure(error: "rateLimited", message: "Too many attempts. Wait a minute, then try again.")
    static let notFound = Failure(error: "notFound", message: "Not found.")
    static let methodNotAllowed = Failure(error: "methodNotAllowed", message: "This address does not take that request.")
    static let badRequest = Failure(error: "badRequest", message: "The request was not understood.")
    static let lengthRequired = Failure(error: "lengthRequired", message: "The request must say how long it is (Content-Length).")
    static let busy = Failure(error: "busy", message: "This file is still being received. Try again in a moment.")
    static let hashMismatch = Failure(error: "hashMismatch", message: "The file arrived damaged. Send it again from the start.")
    static let diskFull = Failure(error: "diskFull", message: "This computer is almost out of disk space.")
    static let rangeNotSatisfiable = Failure(error: "rangeNotSatisfiable", message: "That part of the file is not available.")
    static let changed = Failure(error: "changed", message: "The file changed on the computer after it was queued.")
    static let serverError = Failure(error: "serverError", message: "The computer could not store this.")

    static func offsetMismatch(_ offset: Int64) -> Failure {
        Failure(error: "offsetMismatch", message: "The file is not at that offset here. Continue from the offset given.", offset: offset)
    }
}

/// A refusal the router answers with `status` and `failure`.
struct Refusal: Error {
    var status: Int
    var failure: Failure
}

extension JSONEncoder {
    static let link: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()
}
