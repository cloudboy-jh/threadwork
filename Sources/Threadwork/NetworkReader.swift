import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

/// IPv4 LAN observations, not an inventory of every device on the network.
enum NetworkReader {
    static func context() async throws -> NetworkContext {
        let snapshot = try await offMain { try Self.snapshot() }
        var neighbors = try await arp(on: snapshot.context, names: false)
        if let gateway = snapshot.context.gateway,
           neighbors.first(where: { $0.address == gateway }) == nil,
           let address = IPv4(gateway), address.isLAN,
           snapshot.subnet.containsHost(address) {
            try await ping(gateway, on: snapshot.context)
            neighbors = try await arp(on: snapshot.context, names: false)
        }
        try Task.checkCancellation()
        try await offMain { try validate(snapshot.context) }
        let context = snapshot.context
        return NetworkContext(
            interface: context.interface, address: context.address, netmask: context.netmask,
            gateway: context.gateway,
            gatewayMAC: neighbors.first(where: { $0.address == context.gateway })?.mac,
            wifiName: context.wifiName, connectionType: context.connectionType
        )
    }

    static func devices(on context: NetworkContext, actively: Bool) async throws -> [DiscoveredDevice] {
        let current = try await offMain { try snapshot() }
        try ensureSameNetwork(context, current.context)
        if actively {
            guard let local = IPv4(context.address), local.isLAN else {
                throw ReaderError.unsupportedRange
            }
            // For larger LANs, probe only the /24 containing this Mac. Smaller
            // subnets keep their real host boundaries, including /31 and /32.
            let subnet = current.subnet
            let scanMask = subnet.mask | 0xffff_ff00
            let start = local.value & scanMask
            let end = start | ~scanMask
            let targets = (start...end).compactMap { value -> String? in
                let candidate = IPv4(value: value)
                return candidate != local && candidate.isLAN && subnet.containsHost(candidate)
                    ? candidate.description : nil
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                var next = targets.makeIterator()
                for _ in 0..<min(16, targets.count) {
                    if let target = next.next() {
                        group.addTask { try await ping(target, on: context) }
                    }
                }
                while try await group.next() != nil {
                    try Task.checkCancellation()
                    if let target = next.next() {
                        group.addTask { try await ping(target, on: context) }
                    }
                }
            }
        }
        try await offMain { try validate(context) }
        let neighbors = try await arp(on: context, names: false)
        if let expectedMAC = context.gatewayMAC,
           let observedMAC = neighbors.first(where: { $0.address == context.gateway })?.mac,
           expectedMAC.lowercased() != observedMAC {
            throw ReaderError.networkChanged
        }
        // One globally bounded symbolic ARP pass, never one blocking DNS lookup
        // per device. A slow resolver can at most consume this short deadline.
        let named = try await arp(on: context, names: true)
        try await offMain { try validate(context) }
        let names = Dictionary(named.compactMap { neighbor in
            neighbor.hostname.map { (neighbor.address, $0) }
        }, uniquingKeysWith: { first, _ in first })
        var observed: [String: DiscoveredDevice] = [:]
        for neighbor in neighbors + named {
            observed[neighbor.address] = DiscoveredDevice(
                address: neighbor.address, mac: neighbor.mac,
                hostname: names[neighbor.address] ?? neighbor.hostname,
                isThisMac: neighbor.address == context.address,
                isRouter: neighbor.address == context.gateway
            )
        }
        observed[context.address] = DiscoveredDevice(
            address: context.address, mac: current.mac, hostname: current.localName,
            isThisMac: true, isRouter: context.address == context.gateway
        )
        if let gateway = context.gateway, observed[gateway] == nil {
            // The configured router is an observed route even when ARP has not
            // resolved its hardware address. Do not invent a MAC or hostname.
            observed[gateway] = DiscoveredDevice(
                address: gateway, mac: nil, hostname: nil,
                isThisMac: false, isRouter: true
            )
        }
        return observed.values.sorted {
            if $0.isThisMac != $1.isThisMac { return $0.isThisMac }
            if $0.isRouter != $1.isRouter { return $0.isRouter }
            return (IPv4($0.address)?.value ?? 0) < (IPv4($1.address)?.value ?? 0)
        }
    }

    /// Call from the sampling worker, not the main actor. Counters belong to
    /// exactly this physical interface, not the loopback/VPN/aggregate path.
    static func traffic(interface: String) -> TrafficReading? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        var found = false
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name) == interface,
                  isUp(entry.pointee),
                  let address = entry.pointee.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_LINK else { continue }
            let link = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_dl.self).pointee
            found = link.sdl_type == UInt8(IFT_ETHER)
            break
        }
        guard found, physicalInterfaces()[interface] != nil else { return nil }
        let index = if_nametoindex(interface)
        guard index != 0 else { return nil }
        // getifaddrs' if_data byte counters are only 32-bit on Darwin. Read the
        // same interface's 64-bit kernel counters to avoid wrapping at 4 GiB.
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(index), IFDATA_GENERAL]
        var data = ifmibdata()
        var size = MemoryLayout<ifmibdata>.size
        guard sysctl(&mib, u_int(mib.count), &data, &size, nil, 0) == 0 else { return nil }
        return TrafficReading(
            received: data.ifmd_data.ifi_ibytes, sent: data.ifmd_data.ifi_obytes,
            time: ProcessInfo.processInfo.systemUptime
        )
    }

    private struct Snapshot: Sendable {
        let context: NetworkContext
        let subnet: Subnet
        let mac: String?
        let localName: String?
    }

    private struct Neighbor: Sendable {
        let address: String
        let mac: String
        let hostname: String?
    }

    private struct IPv4: Equatable, Sendable, CustomStringConvertible {
        let value: UInt32

        init(value: UInt32) { self.value = value }

        init?(_ string: String) {
            let parts = string.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            var value: UInt32 = 0
            for part in parts {
                guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let byte = UInt8(part) else { return nil }
                value = (value << 8) | UInt32(byte)
            }
            self.value = value
        }

        var description: String {
            "\(value >> 24).\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255)"
        }

        var isUnicast: Bool {
            value >> 24 != 0 && value >> 24 != 127 && value >> 24 < 224
        }

        var isLAN: Bool {
            value >> 24 == 10 || value >> 20 == 0xac1 || value >> 16 == 0xc0a8 || value >> 16 == 0xa9fe
        }
    }

    private struct Subnet: Sendable {
        let address: IPv4
        let mask: UInt32

        init?(address: String, netmask: String) {
            guard let address = IPv4(address), let mask = IPv4(netmask)?.value else { return nil }
            let inverse = ~mask
            guard inverse & (inverse &+ 1) == 0 else { return nil }
            self.address = address
            self.mask = mask
        }

        func containsHost(_ candidate: IPv4) -> Bool {
            guard candidate.isUnicast, candidate.value & mask == address.value & mask else { return false }
            // Both addresses of a point-to-point /31 are usable; /32 has one.
            if mask >= 0xffff_fffe { return true }
            return candidate.value != address.value & mask && candidate.value != (address.value & mask) | ~mask
        }
    }

    private static func physicalInterfaces() -> [String: String] {
        var result: [String: String] = [:]
        for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let kind = SCNetworkInterfaceGetInterfaceType(interface) as String? else { continue }
            if kind == kSCNetworkInterfaceTypeIEEE80211 as String {
                result[name] = "Wi-Fi"
            } else if kind == kSCNetworkInterfaceTypeEthernet as String {
                result[name] = "Ethernet"
            }
        }
        return result
    }

    private static func isUp(_ interface: ifaddrs) -> Bool {
        let required = UInt32(IFF_UP | IFF_RUNNING)
        return interface.ifa_flags & required == required
            && interface.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0
    }

    private static func snapshot() throws -> Snapshot {
        let physical = physicalInterfaces()
        guard let store = SCDynamicStoreCreate(nil, "Threadwork.NetworkReader" as CFString, nil, nil) else {
            throw ReaderError.noNetwork
        }
        let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let primary = global?["PrimaryInterface"] as? String
        if let primary, physical[primary] == nil {
            throw ReaderError.unsupportedInterface(primary)
        }
        let preferredAddresses: [String]
        if let primary {
            let state = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(primary)/IPv4" as CFString) as? [String: Any]
            preferredAddresses = state?["Addresses"] as? [String] ?? []
        } else {
            preferredAddresses = []
        }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else {
            throw ReaderError.interfaces(String(cString: strerror(errno)))
        }
        defer { freeifaddrs(first) }
        var addresses: [(name: String, address: String, mask: String)] = []
        var macs: [String: String] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let item = entry.pointee
            let name = String(cString: item.ifa_name)
            guard physical[name] != nil, primary == nil || primary == name,
                  isUp(item), let address = item.ifa_addr else { continue }
            if Int32(address.pointee.sa_family) == AF_INET, let mask = item.ifa_netmask {
                let ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
                let netmask = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee
                let parsed = IPv4(value: UInt32(bigEndian: ip.sin_addr.s_addr))
                if parsed.isUnicast {
                    addresses.append((name, parsed.description, IPv4(value: UInt32(bigEndian: netmask.sin_addr.s_addr)).description))
                }
            } else if Int32(address.pointee.sa_family) == AF_LINK {
                let link = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_dl.self).pointee
                let offset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)! + Int(link.sdl_nlen)
                if link.sdl_type == UInt8(IFT_ETHER), link.sdl_alen == 6,
                   Int(address.pointee.sa_len) >= offset + 6 {
                    let bytes = UnsafeRawPointer(address).advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                    macs[name] = normalizedMAC((0..<6).map { String(format: "%02x", bytes[$0]) }.joined(separator: ":"))
                }
            }
        }
        addresses.sort {
            let leftPreferred = preferredAddresses.first == $0.address
            let rightPreferred = preferredAddresses.first == $1.address
            if leftPreferred != rightPreferred { return leftPreferred }
            return ($0.name, $0.address) < ($1.name, $1.address)
        }
        guard let selected = addresses.first, macs[selected.name] != nil,
              let subnet = Subnet(address: selected.address, netmask: selected.mask) else {
            throw ReaderError.noNetwork
        }
        // With no default route, do not guess among multiple attached LANs.
        if primary == nil, Set(addresses.map(\.name)).count > 1 {
            throw ReaderError.ambiguousNetwork
        }
        let router = (global?["Router"] as? String).flatMap(IPv4.init)
        let gateway = router.flatMap { subnet.containsHost($0) ? $0.description : nil }
        let wifiName = physical[selected.name] == "Wi-Fi"
            ? CWWiFiClient.shared().interface(withName: selected.name)?.ssid() : nil
        return Snapshot(
            context: NetworkContext(
                interface: selected.name, address: selected.address, netmask: selected.mask,
                gateway: gateway, gatewayMAC: nil, wifiName: wifiName,
                connectionType: physical[selected.name] ?? "Ethernet"
            ),
            subnet: subnet, mac: macs[selected.name],
            localName: SCDynamicStoreCopyLocalHostName(store) as String?
        )
    }

    private static func ensureSameNetwork(_ expected: NetworkContext, _ current: NetworkContext) throws {
        guard expected.interface == current.interface, expected.address == current.address,
              expected.netmask == current.netmask, expected.gateway == current.gateway,
              expected.wifiName == current.wifiName else { throw ReaderError.networkChanged }
    }

    private static func validate(_ context: NetworkContext) throws {
        try ensureSameNetwork(context, snapshot().context)
    }

    private static func arp(on context: NetworkContext, names: Bool) async throws -> [Neighbor] {
        let arguments = (names ? ["-a"] : ["-a", "-n"]) + ["-i", context.interface]
        let result = try await LANCommand.run("/usr/sbin/arp", arguments, timeout: names ? 0.7 : 2)
        if !names { try result.requireSuccess("read the LAN neighbor table") }
        guard let subnet = Subnet(address: context.address, netmask: context.netmask) else {
            throw ReaderError.noNetwork
        }
        return result.output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 6, fields[2] == "at", fields[4] == "on", fields[5] == context.interface,
                  fields[1].first == "(", fields[1].last == ")",
                  let ip = IPv4(String(fields[1].dropFirst().dropLast())), subnet.containsHost(ip),
                  let mac = normalizedMAC(fields[3]),
                  !fields.contains("reject"), !fields.contains("blackhole"), !fields.contains("published") else { return nil }
            let hostname = fields[0] == "?" || IPv4(fields[0]) != nil ? nil : fields[0]
            return Neighbor(address: ip.description, mac: mac, hostname: hostname)
        }
    }

    private static func normalizedMAC(_ string: String) -> String? {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        let bytes = parts.compactMap { part -> UInt8? in
            guard (1...2).contains(part.count) else { return nil }
            return UInt8(part, radix: 16)
        }
        guard bytes.count == 6, bytes[0] & 1 == 0, bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    private static func ping(_ target: String, on context: NetworkContext) async throws {
        try await offMain { try validate(context) }
        guard let subnet = Subnet(address: context.address, netmask: context.netmask),
              let address = IPv4(target), address.isLAN, subnet.containsHost(address) else {
            throw ReaderError.unsupportedRange
        }
        let result = try await LANCommand.run(
            "/sbin/ping", ["-n", "-q", "-r", "-b", context.interface, "-S", context.address,
                           "-c", "1", "-W", "350", "-t", "1", target], timeout: 1.2
        )
        // Silence/no ICMP response is normal, not evidence that a device is absent.
        if !result.timedOut && result.status != 0 && result.status != 2 {
            try result.requireSuccess("probe a local LAN address")
        }
    }

    private static func offMain<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let value = try operation()
            try Task.checkCancellation()
            return value
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private enum ReaderError: LocalizedError {
        case noNetwork, ambiguousNetwork, networkChanged, unsupportedRange
        case unsupportedInterface(String), interfaces(String)

        var errorDescription: String? {
            switch self {
            case .noNetwork:
                return "No active IPv4 Wi-Fi or Ethernet LAN was found. Connect to a local network and try again."
            case .ambiguousNetwork:
                return "Multiple LANs are connected without a default IPv4 route. Select a default connection before discovering devices."
            case .networkChanged:
                return "The local network changed during discovery. Refresh and try again."
            case .unsupportedRange:
                return "Active discovery is limited to private or link-local IPv4 LAN addresses. Public and VPN ranges are not scanned."
            case .unsupportedInterface(let interface):
                return "The default IPv4 route uses \(interface), a VPN or unsupported virtual interface. Disconnect the VPN to inspect the physical LAN."
            case .interfaces(let detail):
                return "Could not read the network interfaces: \(detail)"
            }
        }
    }
}

/// File-private, cancellable subprocesses: no shell, no sudo, no main-thread
/// wait, and no unbounded pipe writes or DNS waits.
private enum LANCommand {
    struct Result: Sendable {
        let output: String
        let error: String
        let status: Int32
        let timedOut: Bool

        func requireSuccess(_ action: String) throws {
            guard !timedOut, status == 0 else {
                let detail = timedOut ? "The operation timed out." : error.trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure(message: "Could not \(action). \(detail.isEmpty ? "Command exited with status \(status)." : detail)")
            }
        }
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.lock(); value = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> Result {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        if cancellation.isCancelled { throw CancellationError() }
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: executable)
                        process.arguments = arguments
                        var environment = ProcessInfo.processInfo.environment
                        environment["LC_ALL"] = "C"
                        process.environment = environment
                        let output = Pipe()
                        let error = Pipe()
                        process.standardOutput = output
                        process.standardError = error
                        process.standardInput = FileHandle.nullDevice
                        try process.run()
                        // Child owns the write ends; close ours so EOF is real.
                        output.fileHandleForWriting.closeFile()
                        error.fileHandleForWriting.closeFile()
                        defer {
                            output.fileHandleForReading.closeFile()
                            error.fileHandleForReading.closeFile()
                        }
                        let outputFD = output.fileHandleForReading.fileDescriptor
                        let errorFD = error.fileHandleForReading.fileDescriptor
                        guard fcntl(outputFD, F_SETFL, O_NONBLOCK) != -1,
                              fcntl(errorFD, F_SETFL, O_NONBLOCK) != -1 else {
                            let detail = String(cString: strerror(errno))
                            _ = Darwin.kill(process.processIdentifier, SIGKILL)
                            process.waitUntilExit()
                            throw Failure(message: "Could not configure LAN command output: \(detail)")
                        }
                        var stdout = Data()
                        var stderr = Data()
                        let deadline = ProcessInfo.processInfo.systemUptime + timeout
                        var timedOut = false
                        while process.isRunning {
                            drain(outputFD, into: &stdout)
                            drain(errorFD, into: &stderr)
                            if cancellation.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                                timedOut = !cancellation.isCancelled
                                // Direct children only; SIGKILL guarantees a bound
                                // even if a resolver ignores graceful termination.
                                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                                break
                            }
                            usleep(15_000)
                        }
                        process.waitUntilExit()
                        drain(outputFD, into: &stdout)
                        drain(errorFD, into: &stderr)
                        if cancellation.isCancelled { throw CancellationError() }
                        continuation.resume(returning: Result(
                            output: String(decoding: stdout, as: UTF8.self),
                            error: String(decoding: stderr, as: UTF8.self),
                            status: process.terminationStatus, timedOut: timedOut
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func drain(_ descriptor: Int32, into data: inout Data) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                return
            }
        }
    }
}
