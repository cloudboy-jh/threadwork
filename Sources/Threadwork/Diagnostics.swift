import Foundation
import CoreFoundation
import Darwin

enum Diagnostics {
    static func run(
        on context: NetworkContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> DiagnosticResult {
        let date = Date()
        progress("Checking internet, router, and DNS response times…")
        async let internet = ping("1.1.1.1", interface: context.interface, label: "Internet")
        async let router = routerPing(context)
        async let dns = checkDNS()
        let (internetResult, routerResult, dnsResult) = try await (internet, router, dns)
        try Task.checkCancellation()

        // Finish unloaded measurements before generating any speed-test traffic.
        progress("Measuring download and upload speed — this consumes internet data…")
        let speed = try await checkSpeed(interface: context.interface)
        try Task.checkCancellation()
        return DiagnosticResult(
            date: date,
            downloadMbps: speed.download,
            uploadMbps: speed.upload,
            latencyMs: internetResult.latency,
            packetLoss: internetResult.loss,
            dnsMs: dnsResult.latency,
            routerLatencyMs: routerResult.latency,
            notes: internetResult.notes + routerResult.notes + dnsResult.notes + speed.notes
        )
    }

    private struct PingResult: Sendable {
        var latency: Double?
        var loss: Double?
        var notes: [String] = []
    }

    private struct DNSResult: Sendable {
        var latency: Double?
        var notes: [String] = []
    }

    private struct SpeedResult: Sendable {
        var download: Double?
        var upload: Double?
        var notes: [String] = []
    }

    private static func routerPing(_ context: NetworkContext) async throws -> PingResult {
        guard let gateway = context.gateway, !gateway.isEmpty else {
            return PingResult(notes: ["Router latency unavailable: no gateway was found."])
        }
        return try await ping(gateway, interface: context.interface, label: "Router")
    }

    private static func ping(_ target: String, interface: String, label: String) async throws -> PingResult {
        do {
            let output = try await command(
                "/sbin/ping",
                ["-n", "-q", "-b", interface, "-c", "5", "-W", "1000", "-t", "10", target],
                timeout: 12
            )
            var result = PingResult()
            let counts = captures(#"(\d+) packets transmitted,\s*(\d+) packets received"#, in: output.stdout)
            if counts.count == 2, let sent = Double(counts[0]), let received = Double(counts[1]),
               sent > 0, received >= 0, received <= sent {
                result.loss = 100 * (sent - received) / sent
                if sent != 5 {
                    result.notes.append("\(label) ping completed only \(Int(sent)) of 5 probes.")
                }
                if received == 0 {
                    result.notes.append("\(label) did not answer ICMP probes; ICMP may be blocked or the destination unreachable. This alone does not prove an internet outage.")
                }
            }
            if let average = captures(#"(?:round-trip|rtt)[^=]*=\s*[\d.]+/([\d.]+)/"#, in: output.stdout).first,
               let value = Double(average), value.isFinite, value >= 0 {
                result.latency = value
            }
            if output.timedOut {
                result.notes.append("\(label) ping exceeded its time limit.")
            }
            if result.loss == nil || (result.latency == nil && result.loss != 100) {
                result.notes.append("\(label) ping did not return valid measurements.\(output.detail)")
            } else if output.status != 0, result.loss != 100 {
                result.notes.append("\(label) ping exited with status \(output.status).\(output.detail)")
            } else if !output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.notes.append("\(label) ping reported:\(output.detail)")
            }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return PingResult(notes: ["\(label) ping failed: \(error.localizedDescription)"])
        }
    }

    private static func checkDNS() async throws -> DNSResult {
        do {
            // No @server override: use dig's configured default resolver.
            let output = try await command(
                "/usr/bin/dig", ["apple.com", "A", "+stats", "+time=3", "+tries=1"], timeout: 6
            )
            let answerSection = output.stdout.components(separatedBy: ";; ANSWER SECTION:").dropFirst().first?
                .components(separatedBy: ";;").first ?? ""
            let addresses = captures(#"(?m)^\S+\s+\d+\s+IN\s+A\s+(\d{1,3}(?:\.\d{1,3}){3})\s*$"#, in: answerSection)
            let hasAddress = addresses.first.map { address in
                address.split(separator: ".").allSatisfy { UInt8($0) != nil }
            } ?? false
            let timing = captures(#";; Query time:\s*([\d.]+)\s+msec"#, in: output.stdout).first.flatMap(Double.init)
            guard output.status == 0, !output.timedOut,
                  !captures(#"status:\s*(NOERROR),"#, in: output.stdout).isEmpty,
                  hasAddress, let timing, timing.isFinite, timing >= 0 else {
                let status = captures(#"status:\s*([A-Z]+),"#, in: output.stdout).first
                let reason = output.timedOut ? "timed out" : status.map { "DNS status \($0)" } ?? "exit status \(output.status)"
                return DNSResult(notes: ["DNS lookup did not return a valid A answer for apple.com (\(reason)).\(output.detail)"])
            }
            var result = DNSResult(latency: timing)
            if !output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.notes.append("DNS lookup reported:\(output.detail)")
            }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return DNSResult(notes: ["DNS lookup failed: \(error.localizedDescription)"])
        }
    }

    private static func checkSpeed(interface: String) async throws -> SpeedResult {
        do {
            let output = try await command(
                "/usr/bin/networkQuality", ["-c", "-I", interface, "-M", "20"], timeout: 35
            )
            guard output.status == 0, !output.timedOut else {
                let reason = output.timedOut ? "exceeded its time limit" : "exited with status \(output.status)"
                return SpeedResult(notes: ["Speed check \(reason).\(output.detail)"])
            }
            guard let data = output.stdout.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return SpeedResult(notes: ["Speed check returned invalid JSON.\(output.detail)"])
            }
            // networkQuality documents error fields only for an incomplete test.
            if json["error_code"] != nil || json["error_domain"] != nil {
                let domain = json["error_domain"].map { String(describing: $0) } ?? "unknown domain"
                let code = json["error_code"].map { String(describing: $0) } ?? "unknown code"
                return SpeedResult(notes: ["Speed check failed: \(domain) (\(code)).\(output.detail)"])
            }
            var result = SpeedResult(
                download: megabits(json["dl_throughput"]),
                upload: megabits(json["ul_throughput"])
            )
            if result.download == nil {
                result.notes.append("Speed check did not return a valid download throughput.")
            }
            if result.upload == nil {
                result.notes.append("Speed check did not return a valid upload throughput.")
            }
            if !output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.notes.append("Speed check reported:\(output.detail)")
            }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return SpeedResult(notes: ["Speed check failed: \(error.localizedDescription)"])
        }
    }

    private static func megabits(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let bits = number.doubleValue
        guard bits.isFinite, bits > 0 else { return nil }
        return bits / 1_000_000
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [] }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    private struct CommandOutput: Sendable {
        let stdout: String
        let stderr: String
        let status: Int32
        let timedOut: Bool

        var detail: String {
            let error = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            // Some tools put their error response on stdout instead of stderr.
            let message = error.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : error
            return message.isEmpty ? "" : " " + String(message.prefix(1_000))
        }
    }

    private static func command(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        let runner = CommandRunner()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try runner.run(executable, arguments, timeout: timeout))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            runner.cancel()
        }
    }

    // All blocking launch/wait/read work runs on utility queues. Both pipes are
    // drained concurrently, so either output stream can fill without deadlock.
    private final class CommandRunner: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        private var timedOut = false

        func cancel() {
            lock.lock()
            cancelled = true
            stopLocked()
            lock.unlock()
        }

        private func stopLocked() {
            guard let process, process.isRunning else { return }
            process.terminate()
            // Some tools do not promptly honor SIGTERM. Never leave a speed test running.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
                lock.lock()
                if self.process === process, process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
                lock.unlock()
            }
        }

        func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandOutput {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "C"
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            defer {
                try? stdout.fileHandleForReading.close()
                try? stderr.fileHandleForReading.close()
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
            }

            lock.lock()
            if cancelled {
                lock.unlock()
                throw CancellationError()
            }
            self.process = process
            do {
                try process.run()
            } catch {
                self.process = nil
                let wasCancelled = cancelled
                lock.unlock()
                if wasCancelled { throw CancellationError() }
                throw error
            }
            lock.unlock()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()

            let group = DispatchGroup()
            let capturedOut = Capture()
            let capturedError = Capture()
            for (handle, capture) in [(stdout.fileHandleForReading, capturedOut), (stderr.fileHandleForReading, capturedError)] {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    capture.read(handle)
                    group.leave()
                }
            }
            let deadline = DispatchWorkItem { [self] in
                lock.lock()
                if self.process === process, process.isRunning {
                    timedOut = true
                    stopLocked()
                }
                lock.unlock()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
            process.waitUntilExit()
            deadline.cancel()
            lock.lock()
            self.process = nil
            let wasCancelled = cancelled
            let didTimeOut = timedOut
            lock.unlock()
            capturedOut.finish()
            capturedError.finish()
            group.wait()
            if wasCancelled { throw CancellationError() }
            if let error = capturedOut.error ?? capturedError.error { throw error }
            return CommandOutput(
                stdout: String(decoding: capturedOut.data, as: UTF8.self),
                stderr: String(decoding: capturedError.data, as: UTF8.self),
                status: process.terminationStatus,
                timedOut: didTimeOut
            )
        }
    }

    // Each capture is written by one reader and consumed only after its group completes.
    private final class Capture: @unchecked Sendable {
        private(set) var data = Data()
        private(set) var error: Error?
        private let lock = NSLock()
        private var drainDeadline: UInt64?

        func finish() {
            lock.lock()
            drainDeadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
            lock.unlock()
        }

        private var deadline: UInt64? {
            lock.lock()
            defer { lock.unlock() }
            return drainDeadline
        }

        func read(_ handle: FileHandle) {
            let fd = handle.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                return
            }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            while true {
                if let deadline, DispatchTime.now().uptimeNanoseconds >= deadline {
                    // A descendant must not keep our pipe readers alive indefinitely.
                    error = NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
                    return
                }
                let ready = Darwin.poll(&descriptor, 1, 100)
                if ready < 0 {
                    if errno == EINTR { continue }
                    error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    return
                }
                if ready == 0 {
                    if deadline != nil { return }
                    continue
                }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
                if count > 0 {
                    data.append(contentsOf: buffer.prefix(count))
                } else if count == 0 {
                    return
                } else if errno != EAGAIN && errno != EINTR {
                    error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    return
                } else if deadline != nil {
                    return
                }
            }
        }
    }
}
