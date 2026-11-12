#if os(macOS)
import Foundation
import dnssd

private let registered: DNSServiceRegisterReply = { _, _, _, _, _, _, _ in
    // A name conflict is settled by mDNSResponder, which renames the service.
}

/// Advertises `_lazysend._tcp` on every interface for as long as it is registered, so phones on the network find
/// this Mac by name; scanning the pairing code works without it.
final class Advertiser {
    private let queue = DispatchQueue(label: "lazysend.advertiser")
    private var service: DNSServiceRef?

    func register(port: Int, desktopId: String) {
        unregister()
        var record: [UInt8] = []
        for (key, value) in [("v", "1"), ("id", desktopId)] {
            let entry = Array("\(key)=\(value)".utf8)
            record.append(UInt8(entry.count))
            record.append(contentsOf: entry)
        }
        let queue = self.queue
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
