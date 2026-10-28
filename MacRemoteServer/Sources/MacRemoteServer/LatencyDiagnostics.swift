import Foundation

// Only timing and transport metadata is written: never pairing secrets, typed
// text, or Accessibility values. RemoteServer owns calls into this type, while
// JSONL disk I/O happens on a utility queue so measurement cannot block input.
final class LatencyDiagnostics {
    struct RunningStats {
        private(set) var count = 0
        private(set) var total = 0.0
        private(set) var minimum = Double.infinity
        private(set) var maximum = 0.0

        mutating func add(_ value: Double) {
            guard value.isFinite, value >= 0 else { return }
            count += 1; total += value
            minimum = min(minimum, value); maximum = max(maximum, value)
        }

        var average: Double? { count > 0 ? total / Double(count) : nil }
    }

    struct Summary {
        let session: String
        let rawDataURL: URL
        let duration: Double
        let eventCount: Int
        let motionSamples: Int
        let probeRoundTrip: RunningStats
        let macProcessing: RunningStats
        let serverQueueWait: RunningStats
        let healthChecks: [String: String]
    }

    private let writer = DispatchQueue(label: "MacRemote.diagnostics.writer", qos: .utility)
    private var handle: FileHandle?
    private var buffer = Data()
    private(set) var active = false
    private(set) var session = ""
    private var rawDataURL: URL?
    private var startedAt = 0.0
    private var eventCount = 0
    private var motionSamples = 0
    private var probeRoundTrip = RunningStats()
    private var macProcessing = RunningStats()
    private var serverQueueWait = RunningStats()
    private var healthChecks: [String: String] = [:]

    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacRemote/Diagnostics", isDirectory: true)
    }

    @discardableResult func start(duration: Double) -> URL? {
        _ = stop()
        let id = UUID().uuidString
        let url = Self.directoryURL.appendingPathComponent("measurement-\(id).jsonl")
        do {
            try FileManager.default.createDirectory(at: Self.directoryURL, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
            let file = try FileHandle(forWritingTo: url)
            writer.sync { handle = file; buffer.removeAll(keepingCapacity: true) }
        } catch {
            NSLog("Diagnostics could not start: %@", error.localizedDescription)
            return nil
        }
        session = id; rawDataURL = url; startedAt = Self.now(); active = true
        eventCount = 0; motionSamples = 0; probeRoundTrip = .init(); macProcessing = .init(); serverQueueWait = .init(); healthChecks = [:]
        record("session_start", ["version": 2, "duration_s": duration,
                                 "clock": "monotonic seconds; iPhone and Mac clocks have independent origins"])
        return url
    }

    func recordHealth(_ values: [String: String]) {
        healthChecks.merge(values) { _, latest in latest }
        record("connection_health", values)
    }

    func record(_ event: String, _ values: [String: Any] = [:]) {
        guard active else { return }
        eventCount += 1
        updateSummary(event: event, values: values)
        var row = values
        row["event"] = event; row["session"] = session; row["mac_record_s"] = Self.now()
        let captured = row
        writer.async {
            guard let data = try? JSONSerialization.data(withJSONObject: captured, options: [.sortedKeys]) else { return }
            self.buffer.append(data); self.buffer.append(0x0A)
            if self.buffer.count >= 16_384 { self.flush() }
        }
    }

    func stop() -> Summary? {
        guard active, let rawDataURL else { return nil }
        record("session_end")
        let summary = Summary(session: session, rawDataURL: rawDataURL,
                              duration: max(0, Self.now() - startedAt), eventCount: eventCount,
                              motionSamples: motionSamples, probeRoundTrip: probeRoundTrip,
                              macProcessing: macProcessing, serverQueueWait: serverQueueWait,
                              healthChecks: healthChecks)
        active = false
        writer.sync {
            self.flush()
            try? self.handle?.close(); self.handle = nil
        }
        return summary
    }

    private func updateSummary(event: String, values: [String: Any]) {
        switch event {
        case "clock_probe":
            if let sent = values["client_send_s"] as? Double,
               let received = values["client_receive_s"] as? Double {
                probeRoundTrip.add((received - sent) * 1_000)
            }
        case "motion":
            motionSamples += 1
            if let received = values["receive_s"] as? Double,
               let finished = values["injection_end_s"] as? Double {
                macProcessing.add((finished - received) * 1_000)
            }
        case "server_queue":
            if let wait = values["wait_ms"] as? Double { serverQueueWait.add(wait) }
        default:
            break
        }
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        do { try handle?.write(contentsOf: buffer) }
        catch { NSLog("Diagnostics trace write failed: %@", error.localizedDescription) }
        buffer.removeAll(keepingCapacity: true)
    }
}
