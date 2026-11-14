#if os(macOS)
import Foundation
import dnssd
import LazySendKit

private let registered: DNSServiceRegisterReply = { _, _, _, _, _, _, _ in
    // A name conflict is settled by mDNSResponder, which renames the service.
}

/// Advertises `_lazysend._tcp` on every interface for as long as it is registered, so phones on the network find
/// this Mac by name, and so do other computers that connect to it; scanning the pairing code works without it.
final class Advertiser {
    private let queue = DispatchQueue(label: "lazysend.advertiser")
    private var service: DNSServiceRef?

    /// The TXT record: the protocol version, the computer's id and its name, cut to 64 UTF-8 bytes and left out when empty.
    static func txtRecord(desktopId: String, name: String) -> [UInt8] {
        var record: [UInt8] = []
        var entries = [("v", "1"), ("id", desktopId)]
        let shown = DisplayName.clean(name, maxBytes: LinkProtocol.maxTxtNameBytes)
        if !shown.isEmpty { entries.append((LinkProtocol.txtNameKey, shown)) }
        for (key, value) in entries {
            let entry = Array("\(key)=\(value)".utf8)
            record.append(UInt8(entry.count))
            record.append(contentsOf: entry)
        }
        return record
    }

    func register(port: Int, desktopId: String, name: String) {
        unregister()
        let record = Advertiser.txtRecord(desktopId: desktopId, name: name)
        queue.sync {
            var ref: DNSServiceRef?
            let error = record.withUnsafeBytes { bytes in
                DNSServiceRegister(&ref, 0, 0, nil, "_lazysend._tcp", nil, nil, UInt16(port).bigEndian,
                                   UInt16(bytes.count), bytes.baseAddress, registered, nil)
            }
            guard Int(error) == kDNSServiceErr_NoError, let started = ref else { return }
            _ = DNSServiceSetDispatchQueue(started, queue)
            service = started
        }
    }

    func unregister() {
        queue.sync {
            if let service = service { DNSServiceRefDeallocate(service) }
            service = nil
        }
    }
}
#endif
