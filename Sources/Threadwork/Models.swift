import Foundation

struct NetworkContext: Codable, Equatable, Sendable {
    let interface: String
    let address: String
    let netmask: String
    let gateway: String?
    let gatewayMAC: String?
    let wifiName: String?
    let connectionType: String
    // IP ranges repeat across homes. Never merge history by IP range alone.
    var id: String? { gatewayMAC.map { "router:\($0.lowercased())" } }
    var title: String { wifiName ?? "\(connectionType) · \(interface)" }
}

struct DiscoveredDevice: Identifiable, Codable, Equatable, Sendable {
    let address: String
    let mac: String?
    let hostname: String?
    let isThisMac: Bool
    let isRouter: Bool
    var id: String { isThisMac ? "this-mac" : mac?.lowercased() ?? "ip:\(address)" }
    var canRememberName: Bool { isThisMac || mac != nil }
    var title: String { isThisMac ? "This Mac" : isRouter ? "Router" : hostname ?? "Unnamed device" }
}

struct TrafficReading: Sendable {
    let received: UInt64
    let sent: UInt64
    let time: TimeInterval
}

struct TrafficPoint: Identifiable, Sendable {
    let id = UUID()
    let download: Double
    let upload: Double
}

struct DiagnosticResult: Identifiable, Codable, Sendable {
    var id = UUID()
    let date: Date
    let downloadMbps: Double?
    let uploadMbps: Double?
    let latencyMs: Double?
    let packetLoss: Double?
    let dnsMs: Double?
    let routerLatencyMs: Double?
    let notes: [String]
    var summary: String {
        if packetLoss == 100 { return "Internet probes were unanswered. ICMP may be blocked; see the other measurements." }
        if let loss = packetLoss, loss > 0 { return "Packets were lost during this check. Calls and games may stutter." }
        if let router = routerLatencyMs, router > 20 { return "Your connection to the router is slow. Try moving closer or using Ethernet." }
        if let latency = latencyMs, latency > 100 { return "Internet response time is high. Calls and games may feel delayed." }
        if let dns = dnsMs, dns > 200 { return "DNS is taking a while. Websites may be slow to start loading." }
        if let speed = downloadMbps, speed < 10 { return "Download speed is low. Large downloads and video may struggle." }
        if downloadMbps != nil, uploadMbps != nil, latencyMs != nil, packetLoss != nil, dnsMs != nil, routerLatencyMs != nil, notes.isEmpty { return "No obvious connection problem in this check." }
        return "The check is incomplete. See the individual results below." 
    }
}

struct SavedNetwork: Identifiable, Codable {
    let id: String
    var name: String
    var lastSeen: Date
    var nicknames: [String: String] = [:]
    var devices: [DiscoveredDevice] = []
    var checks: [DiagnosticResult] = []
}

func rateText(_ bytes: Double) -> String {
    if bytes >= 1_000_000 { return String(format: "%.1f MB/s", bytes / 1_000_000) }
    if bytes >= 1_000 { return String(format: "%.0f KB/s", bytes / 1_000) }
    return String(format: "%.0f B/s", max(0, bytes))
}
