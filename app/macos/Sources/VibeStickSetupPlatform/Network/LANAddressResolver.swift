import Darwin
import Foundation
import VibeStickSetupCore

public struct LANAddressResolver: Sendable {
    public init() {}

    public func resolve() -> [NetworkAddress] {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return [] }
        defer { freeifaddrs(firstAddress) }

        var addresses: [NetworkAddress] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let interface = pointer?.pointee {
            defer { pointer = interface.ifa_next }
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: interface.ifa_name)
            guard !isIgnoredInterface(name) else { continue }

            var socketAddress = unsafeBitCast(address.pointee, to: sockaddr_in.self)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &socketAddress.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip = String(cString: buffer)
            guard isPrivateIPv4(ip) else { continue }
            addresses.append(NetworkAddress(interface: name, address: ip))
        }

        return Array(Set(addresses)).sorted {
            let lhsRank = interfaceRank($0.interface)
            let rhsRank = interfaceRank($1.interface)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return $0.address.localizedStandardCompare($1.address) == .orderedAscending
        }
    }

    private func isIgnoredInterface(_ name: String) -> Bool {
        ["lo", "utun", "awdl", "llw", "p2p", "gif", "stf"].contains { name.hasPrefix($0) }
    }

    private func interfaceRank(_ name: String) -> Int {
        if name == "en0" { return 0 }
        if name.hasPrefix("en") { return 1 }
        return 2
    }

    private func isPrivateIPv4(_ value: String) -> Bool {
        let octets = value.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        if octets[0] == 10 { return true }
        if octets[0] == 172, (16...31).contains(octets[1]) { return true }
        if octets[0] == 192, octets[1] == 168 { return true }
        return false
    }
}
