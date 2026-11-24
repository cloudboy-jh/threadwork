import AppKit
import SwiftUI

private enum Ink {
    // Brand anchor: oklch(0.62 0.20 353); download: oklch(0.82 0.14 183).
    static let upload = Color(red: 0.87, green: 0.28, blue: 0.57)
    static let download = Color(red: 0.25, green: 0.86, blue: 0.77)
}

struct ThreadworkView: View {
    @EnvironmentObject private var store: NetworkStore
    @State private var selected: DiscoveredDevice?
    @State private var showingNetworks = false
    @State private var confirmCheck = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    traffic
                    diagnostics
                    devices
                    if let message = store.error { notice(message, icon: "exclamationmark.triangle") }
                    if let message = store.storageError { notice(message, icon: "externaldrive.badge.exclamationmark") }
                    if let message = store.shortcutError { notice(message, icon: "keyboard") }
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Ink.upload)
        .sheet(item: $selected) { DeviceDetails(device: $0).environmentObject(store) }
        .sheet(isPresented: $showingNetworks) { NetworkHistory().environmentObject(store) }
        .alert("Run a speed check?", isPresented: $confirmCheck) {
            Button("Run Check") { store.runCheck() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The speed test uses Apple’s networkQuality service and can transfer substantial data. Your connection may be busy for about 30 seconds. Latency probes go to Cloudflare (1.1.1.1); DNS checks resolve apple.com.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.grid.3x3.fill")
                .font(.system(size: 24)).foregroundStyle(Ink.upload)
            VStack(alignment: .leading, spacing: 4) {
                Text("Threadwork").font(.system(size: 20, weight: .semibold, design: .rounded))
                HStack(spacing: 6) {
                    Image(systemName: store.network == nil ? "network.slash" : "network")
                    Text(store.networkName).lineLimit(1)
                }.font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { showingNetworks = true } label: { Image(systemName: "clock.arrow.circlepath") }
                .buttonStyle(.borderless).help("Remembered networks and checks")
                .accessibilityLabel("Remembered networks and checks")
        }.padding(.horizontal, 24).padding(.vertical, 20)
    }

    private var traffic: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("This Mac’s traffic").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(store.hasTraffic ? "Live · last 60 samples" : "Waiting for traffic counters")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            VStack(spacing: 16) {
                DotChart(title: "Download", symbol: "arrow.down", values: store.points.map(\.download),
                         tint: Ink.download, available: store.hasTraffic)
                DotChart(title: "Upload", symbol: "arrow.up", values: store.points.map(\.upload),
                         tint: Ink.upload, available: store.hasTraffic)
            }
            .padding(16)
            .background(Color(white: 0.065), in: RoundedRectangle(cornerRadius: 12))
            Text("Actual transfer rate, not your connection’s maximum speed.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connection check").font(.system(size: 14, weight: .semibold))
                Spacer()
                if store.checking {
                    Button("Cancel") { store.cancelCheck() }.controlSize(.small)
                } else {
                    Button("Run Check") { confirmCheck = true }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(store.network == nil || store.scanning)
                }
            }
            if store.checking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(store.progress).font(.system(size: 12))
                }.accessibilityElement(children: .combine)
            }
            if let result = store.result {
                Text(result.summary).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow {
                        metric("Download", result.downloadMbps.map { String(format: "%.1f Mbps", $0) })
                        metric("Upload", result.uploadMbps.map { String(format: "%.1f Mbps", $0) })
                        metric("Latency", result.latencyMs.map { String(format: "%.0f ms", $0) })
                    }
                    GridRow {
                        metric("Packet loss", result.packetLoss.map { String(format: "%.0f%%", $0) })
                        metric("DNS", result.dnsMs.map { String(format: "%.0f ms", $0) })
                        metric("Router", result.routerLatencyMs.map { String(format: "%.0f ms", $0) })
                    }
                }
                ForEach(Array(result.notes.enumerated()), id: \.offset) { _, note in
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(result.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let previous = store.currentSaved?.checks.dropLast().last?.downloadMbps,
                   let current = result.downloadMbps, previous > 0 {
                    Text(String(format: "Download %.0f%% %@ the previous check.", abs(current / previous - 1) * 100,
                                current >= previous ? "above" : "below"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if !store.checking {
                Text("Find out whether the slowdown is near your Mac or further away.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Visible devices").font(.system(size: 14, weight: .semibold))
                Text("\(store.devices.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if store.scanning { ProgressView().controlSize(.small) }
                Button("Scan") { store.scan() }.controlSize(.small)
                    .disabled(store.network == nil || store.scanning || store.checking)
                    .help("Discover devices on the connected local network")
            }
            if store.devices.isEmpty {
                Text(store.network == nil ? "Connect to Wi-Fi or Ethernet to discover nearby devices." :
                        store.scanning ? "Looking for devices on this network…" : "No devices found. Try Scan; isolated networks may hide other devices.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(store.devices) { device in
                Button { selected = device } label: {
                    HStack(spacing: 12) {
                        Image(systemName: device.isThisMac ? "laptopcomputer" : device.isRouter ? "wifi.router" : "desktopcomputer")
                            .font(.system(size: 16)).frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.name(for: device)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(device.address).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(device.isThisMac ? "Live traffic above" : "Traffic unavailable")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(.vertical, 6).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if device.id != store.devices.last?.id { Divider() }
            }
            Text("Some devices stay hidden. Other devices’ bandwidth requires router support.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Text("⌃⌥Space to open · Esc to dismiss").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("Remembered Networks") { showingNetworks = true }
                Divider()
                Button("Quit Threadwork") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Threadwork menu")
        }.padding(.horizontal, 24).padding(.vertical, 12)
    }

    private func metric(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value ?? "Unavailable").font(.system(size: 12, weight: .medium, design: .monospaced))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func notice(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DotChart: View {
    let title: String
    let symbol: String
    let values: [Double]
    let tint: Color
    let available: Bool
    private var ceiling: Double { max(1_024, values.max() ?? 0) }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(tint)
                Spacer()
                Text(available ? rateText(values.last ?? 0) : "—")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
            }
            Canvas { context, size in
                let columns = 60, rows = 9
                let dx = size.width / Double(columns), dy = size.height / Double(rows)
                let diameter = min(dx, dy) * 0.57
                let offset = columns - values.count
                for column in 0..<columns {
                    let index = column - offset
                    let level = index >= 0 && index < values.count ? Int(ceil(values[index] / ceiling * Double(rows))) : 0
                    for row in 0..<rows {
                        let rect = CGRect(x: (Double(column) + 0.5) * dx - diameter / 2,
                                          y: size.height - (Double(row) + 0.5) * dy - diameter / 2,
                                          width: diameter, height: diameter)
                        context.fill(Path(ellipseIn: rect), with: .color(row < level ? tint : Color(white: 0.20)))
                    }
                }
            }.frame(height: 58).accessibilityHidden(true)
            HStack {
                Text("60 samples ago")
                Spacer()
                Text("Scale 0–\(rateText(ceiling))")
                Spacer()
                Text("Now")
            }.font(.system(size: 9, design: .monospaced)).foregroundStyle(Color(white: 0.72))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(available ? rateText(values.last ?? 0) : "unavailable"). Peak \(rateText(values.max() ?? 0)) over the last \(values.count) samples.")
    }
}

private struct DeviceDetails: View {
    @EnvironmentObject private var store: NetworkStore
    @Environment(\.dismiss) private var dismiss
    let device: DiscoveredDevice
    @State private var nickname = ""
    private var canSave: Bool { device.canRememberName && store.currentSaved != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(store.name(for: device)).font(.system(size: 20, weight: .semibold))
            LabeledContent("IP address", value: device.address)
            LabeledContent("Hardware address", value: device.mac ?? "Unavailable")
            if let hostname = device.hostname { LabeledContent("Hostname", value: hostname) }
            Divider()
            TextField("Device nickname", text: $nickname).textFieldStyle(.roundedBorder).disabled(!canSave)
                .onSubmit { save() }
            Text(canSave ? "Remembered on this network using the device’s hardware address. Private addresses can change." :
                    "A stable device and router address are needed to remember a nickname safely.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text(device.isThisMac ? "Live traffic for this Mac appears in the main panel." :
                    "This Mac cannot measure this device’s bandwidth without router data.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Name") { save() }.buttonStyle(.borderedProminent).disabled(!canSave)
            }
        }.padding(24).frame(width: 400)
            .onAppear { nickname = store.currentSaved?.nicknames[device.id] ?? "" }
    }
    private func save() { guard canSave else { return }; store.rename(device: device, to: nickname); dismiss() }
}

private struct NetworkHistory: View {
    @EnvironmentObject private var store: NetworkStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remembered networks").font(.system(size: 20, weight: .semibold))
            if store.currentSaved != nil {
                HStack {
                    TextField("Current network name", text: $name).textFieldStyle(.roundedBorder)
                    Button("Save") { store.renameNetwork(name) }
                }
            } else {
                Text("This network can’t be remembered until its router’s hardware address is available. Matching only an IP range could confuse two homes.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.saved.isEmpty { Text("Networks and your last 30 checks per network will stay on this Mac.").foregroundStyle(.secondary) }
                    ForEach(store.saved.sorted { $0.lastSeen > $1.lastSeen }) { network in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(network.name).fontWeight(.semibold)
                                if network.id == store.network?.id { Text("Current").foregroundStyle(.secondary) }
                            }
                            Text("Last seen \(network.lastSeen.formatted(date: .abbreviated, time: .shortened)) · \(network.devices.count) devices observed")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            ForEach(network.checks.reversed()) { check in
                                HStack(alignment: .top) {
                                    Text(check.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text("↓ \(check.downloadMbps.map { String(format: "%.1f", $0) } ?? "—")  ↑ \(check.uploadMbps.map { String(format: "%.1f", $0) } ?? "—") Mbps")
                                        Text(check.summary).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                                    }
                                }.font(.system(size: 11))
                            }
                            Divider()
                        }
                    }
                }
            }.frame(maxHeight: 330)
            HStack { Text("Stored locally. No account.").font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 440)
            .onAppear { name = store.networkName }
    }
}
