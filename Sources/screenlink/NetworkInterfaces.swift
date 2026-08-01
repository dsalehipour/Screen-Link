import Foundation

enum NetworkInterfaces {
    struct Interface {
        let name: String
        let address: String
    }

    /// Non-loopback IPv4 addresses on running interfaces, in the order the system reports them.
    ///
    /// Deliberately excludes anything that is not a real local network address: binding a service
    /// that can drive the whole machine to the wrong interface is the kind of mistake that should
    /// take an explicit choice rather than a default.
    static func localIPv4() -> [Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [Interface] = []
        for cursor in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(cursor.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = cursor.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                     &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }

            let address = String(cString: host)
            // Link-local addresses mean DHCP never completed; they are not usefully reachable.
            guard !address.hasPrefix("169.254.") else { continue }
            found.append(Interface(name: String(cString: cursor.pointee.ifa_name), address: address))
        }
        return found
    }

    /// The most likely LAN address: Wi-Fi and Ethernet come before virtual interfaces, which are
    /// usually VPN or container bridges that a phone on the same network cannot reach.
    static func primaryIPv4() -> String? {
        let candidates = localIPv4()
        let preferred = ["en0", "en1", "en2", "en3"]
        for name in preferred {
            if let match = candidates.first(where: { $0.name == name }) { return match.address }
        }
        return candidates.first?.address
    }
}
