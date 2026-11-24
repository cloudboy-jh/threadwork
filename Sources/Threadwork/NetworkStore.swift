import AppKit
import Foundation
import SwiftUI

@MainActor
final class NetworkStore: ObservableObject {
    @Published var network: NetworkContext?
    @Published var devices: [DiscoveredDevice] = []
    @Published var points: [TrafficPoint] = []
    @Published var saved: [SavedNetwork] = []
    @Published var scanning = false
    @Published var checking = false
    @Published var progress = ""
    @Published var result: DiagnosticResult?
    @Published var error: String?
    @Published var storageError: String?
    @Published var shortcutError: String?
    @Published var hasTraffic = false
    private var loop: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var scanID = UUID()
    private var checkID = UUID()
    private var previous: TrafficReading?
    private let file: URL

    init(storageURL: URL? = nil) {
        file = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Threadwork/networks.json")
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                saved = try JSONDecoder().decode([SavedNetwork].self, from: Data(contentsOf: file))
            }
        } catch { storageError = "Could not read saved networks: \(error.localizedDescription)" }
    }

    var currentSaved: SavedNetwork? { saved.first { $0.id == network?.id } }
    var networkName: String { currentSaved?.name ?? network?.title ?? "Not connected" }
    var currentDownload: Double { points.last?.download ?? 0 }
    var currentUpload: Double { points.last?.upload ?? 0 }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if tick % 5 == 0 { await self.refreshContext() }
                await self.sample()
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() { loop?.cancel(); scanTask?.cancel(); checkTask?.cancel() }

    private func refreshContext() async {
        do {
            let next = try await NetworkReader.context()
            guard !Task.isCancelled else { return }
            if next != network {
                scanTask?.cancel(); checkTask?.cancel()
                devices = []; points = []; previous = nil; hasTraffic = false
                result = nil; error = nil; scanning = false; checking = false
                network = next
                if let id = next.id {
                    if let index = saved.firstIndex(where: { $0.id == id }) { saved[index].lastSeen = Date() }
                    else { saved.append(SavedNetwork(id: id, name: next.title, lastSeen: Date())) }
                    result = currentSaved?.checks.last
                    persist()
                }
                scan(actively: false)
            }
        } catch {
            guard !Task.isCancelled else { return }
            scanTask?.cancel(); checkTask?.cancel()
            network = nil; devices = []; points = []; previous = nil; hasTraffic = false
            result = nil; scanning = false; checking = false
            self.error = error.localizedDescription
        }
    }

    private func sample() async {
        guard let context = network else { hasTraffic = false; previous = nil; return }
        let reading = await Task.detached(priority: .utility) { NetworkReader.traffic(interface: context.interface) }.value
        guard network == context, let reading else {
            hasTraffic = false; previous = nil; return
        }
        defer { previous = reading }
        guard let before = previous, reading.time > before.time,
              reading.received >= before.received, reading.sent >= before.sent else { return }
        let elapsed = reading.time - before.time
        points.append(TrafficPoint(download: Double(reading.received - before.received) / elapsed,
                                   upload: Double(reading.sent - before.sent) / elapsed))
        if points.count > 60 { points.removeFirst(points.count - 60) }
        hasTraffic = true
    }

    func scan(actively: Bool = true) {
        guard let context = network, !scanning else { return }
        scanning = true; error = nil
        let operation = UUID(); scanID = operation
        scanTask = Task {
            defer { if scanID == operation, network == context { scanning = false } }
            do {
                let found = try await NetworkReader.devices(on: context, actively: actively)
                guard !Task.isCancelled, network == context else { return }
                devices = found
                if let index = saved.firstIndex(where: { $0.id == context.id }) {
                    saved[index].devices = found
                    saved[index].lastSeen = Date()
                    persist()
                }
            } catch is CancellationError { }
            catch { if !Task.isCancelled, network == context { self.error = error.localizedDescription } }
        }
    }

    func runCheck() {
        guard let context = network, !checking else { return }
        checking = true; progress = "Starting connection check…"; error = nil
        let operation = UUID(); checkID = operation
        checkTask = Task { [self] in
            defer { if checkID == operation, network == context { checking = false; progress = "" } }
            do {
                let report = try await Diagnostics.run(on: context) { [weak self] text in
                    Task { @MainActor in
                        guard let self, self.checking, self.checkID == operation, self.network == context else { return }
                        self.progress = text
                    }
                }
                guard !Task.isCancelled, network == context else { return }
                result = report
                if let index = saved.firstIndex(where: { $0.id == context.id }) {
                    saved[index].checks.append(report)
                    if saved[index].checks.count > 30 { saved[index].checks.removeFirst(saved[index].checks.count - 30) }
                    persist()
                }
            } catch is CancellationError { }
            catch { if !Task.isCancelled, network == context { self.error = error.localizedDescription } }
        }
    }

    func cancelCheck() { checkTask?.cancel(); progress = "Stopping check…" }

    func name(for device: DiscoveredDevice) -> String { currentSaved?.nicknames[device.id] ?? device.title }

    func rename(device: DiscoveredDevice, to text: String) {
        guard device.canRememberName, let index = saved.firstIndex(where: { $0.id == network?.id }) else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        saved[index].nicknames[device.id] = value.isEmpty ? nil : String(value.prefix(80))
        persist()
    }

    func renameNetwork(_ text: String) {
        guard let index = saved.firstIndex(where: { $0.id == network?.id }) else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        saved[index].name = String(value.prefix(80)); persist()
    }

    private func persist() {
        // Do not overwrite an unreadable history file with an empty replacement.
        guard storageError == nil else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(saved).write(to: file, options: .atomic)
        } catch { storageError = "Could not save network history: \(error.localizedDescription)" }
    }
}
