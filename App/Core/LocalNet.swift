import Darwin
import Foundation

/** The phone's own place on the home network. */
enum LocalNet {
    /** This phone's IPv4 address on Wi-Fi (en0), else on any other active interface but the loopback; nil off a network. */
    static func ownIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var wifi: String?
        var other: String?
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let addr = String(cString: host)
            let name = String(cString: ifa.pointee.ifa_name)
            if name == "en0" { wifi = addr } else if other == nil, name.hasPrefix("en") || name.hasPrefix("bridge") { other = addr }
        }
        return wifi ?? other
    }
}
