import Foundation
import Combine

/// Wraps /usr/bin/rsync as a Process, parsing --info=progress2 output into live state.
@MainActor
final class RsyncRunner: ObservableObject {
    @Published var isRunning = false
    @Published var percent: Double = 0        // 0...1
    @Published var speedText: String = ""
    @Published var etaText: String = ""
    @Published var log: [String] = []
    @Published var lastExitCode: Int32?
    @Published var recentJobs: [JobRecord] = []

    private var process: Process?
    private var startedAt: Date?
    private let defaultsKey = "SimpleFileSync.recentJobs"
    private static let modernRsync: Bool = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        p.arguments = ["--version"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return !out.lowercased().contains("openrsync")
    }()

    init() { loadRecent() }

    func start(options: SyncOptions) {
        guard !isRunning else { return }
        isRunning = true
        percent = 0
        speedText = ""
        etaText = ""
        let args = options.rsyncArgs(modernRsync: Self.modernRsync)
        log = ["$ rsync \(args.joined(separator: " "))"]
        lastExitCode = nil
        startedAt = Date()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.ingest(text) }
        }

        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.finished(proc.terminationStatus, options: options) }
        }

        do { try p.run(); process = p }
        catch {
            log.append("Failed to launch rsync: \(error.localizedDescription)")
            isRunning = false
        }
    }

    func stop() {
        process?.interrupt()
        process?.terminate()
    }

    private func ingest(_ chunk: String) {
        // progress2 rewrites one line via \r; split on both \r and \n
        for raw in chunk.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.contains("%"), line.contains("B/s") {
                parseProgress(line)
            } else {
                log.append(line)
                if log.count > 600 { log.removeFirst(log.count - 600) }
            }
        }
    }

    // e.g. "  123,456,789  45%   12.34MB/s    0:00:10 (xfr#123, ir-chk=1002/1305)"
    // or openrsync per-file lines "(xfer#2203, to-check=3239/3241)".
    // Overall percent = transferred / (transferred + remaining) from those counters.
    private func parseProgress(_ line: String) {
        let parts = line.split(separator: " ")
        if let overall = overallPercent(from: line) {
            percent = overall
        } else if let pctTok = parts.first(where: { $0.hasSuffix("%") }),
                  let pct = Double(pctTok.dropLast()) {
            percent = min(max(pct / 100.0, 0), 1)
        }
        if let speed = parts.first(where: { $0.contains("/s") }) { speedText = String(speed) }
        if let eta = parts.first(where: { isClock($0) }) { etaText = "ETA \(eta)" }
    }

    private func overallPercent(from line: String) -> Double? {
        // grab "xfer#123" / "xfr#123" and "to-check=456/789" (openrsync) or "ir-chk=…/…" (GNU)
        guard let xferRange = line.range(of: #"xfr?#\d+"#, options: .regularExpression),
              let chkRange = line.range(of: #"chk=\d+/\d+"#, options: .regularExpression) else { return nil }
        let xferStr = String(line[xferRange].split(separator: "#").last ?? "")
        let chkStr = String(line[chkRange].split(separator: "=").last ?? "")
        let chkParts = chkStr.split(separator: "/")
        guard let done = Double(xferStr), chkParts.count == 2,
              let total = Double(chkParts[1]), total > 0 else { return nil }
        return min(max(done / total, percent), 1)   // monotonic: never regress
    }

    private func isClock(_ s: Substring) -> Bool {
        s.count == 8 && s.filter { $0 == ":" }.count == 2 && s.allSatisfy { $0.isNumber || $0 == ":" }
    }

    private func finished(_ code: Int32, options: SyncOptions) {
        lastExitCode = code      // set BEFORE isRunning so observers see a consistent state
        isRunning = false
        if code == 0 { percent = 1 }
        let dur = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        log.append(code == 0 ? "✓ done in \(String(format: "%.1f", dur))s"
                            : "✗ rsync exited \(code) after \(String(format: "%.1f", dur))s")
        recentJobs.insert(JobRecord(started: startedAt ?? Date(), options: options,
                                    exitCode: code, duration: dur, bytesTransferred: nil), at: 0)
        if recentJobs.count > 20 { recentJobs.removeLast() }
        saveRecent()
        process = nil
    }

    private func loadRecent() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let jobs = try? JSONDecoder().decode([JobRecord].self, from: data) else { return }
        recentJobs = jobs
    }
    private func saveRecent() {
        if let data = try? JSONEncoder().encode(recentJobs) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}