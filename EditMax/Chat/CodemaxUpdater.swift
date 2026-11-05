import Foundation
import CryptoKit
import Combine

/// Keeps the codemax EditMax runs on the newest release, without asking, and backs out when that release does not work.
///
/// Where it looks: the latest GitHub release of codemax (EDITMAX_UPDATE_URL overrides the JSON URL for tests), asset
/// `codemax-darwin-<arch>` with its `.sha256`. When it is newer than what runs now and not on the bad list, it is downloaded
/// next to the installed copy (`~/Library/Application Support/EditMax/bin/`), its checksum checked, and it must pass a
/// health check (`--version` prints the release's version, `serve` answers `agents`) before it replaces `codemax`; the
/// copy it replaces stays as `codemax.prev`. A release that fails the check is deleted and put on the bad list.
///
/// Rollback at run time: when an updated codemax crashes twice in ten minutes (`noteFailure`), it is put on the bad list and
/// `codemax.prev` (or the bundled copy, the floor every build ships with) takes over. Every step is in editmax.log.
@MainActor
final class CodemaxUpdater: ObservableObject {
    static let shared = CodemaxUpdater()

    struct Status {
        var activeVersion: String?
        /// "bundled" or "updated".
        var activeSource = "bundled"
        var latest: String?
        var lastCheck: Date?
        var nextCheck: Date?
        var busy = false
        var message = "Not checked yet."
    }
    @Published private(set) var status = Status()

    /// What is written next to the binaries: which copy is active, the bad releases, the last check.
    struct State: Codable {
        var active = "bundled"
        var updatedVersion: String?
        var badVersions: [String] = []
        var lastCheck: Date?
        var latest: String?
        var failures: [Date] = []
    }

    static let checkEvery: TimeInterval = 12 * 60 * 60
    static let releasesURL = URL(string: "https://api.github.com/repos/SkidGod4444/codemax-cli/releases/latest")!
    nonisolated static var binDirectory: URL { CodemaxInstaller.supportDirectory.appendingPathComponent("bin", isDirectory: true) }
    nonisolated static var installedBinary: URL { binDirectory.appendingPathComponent("codemax") }
    nonisolated static var previousBinary: URL { binDirectory.appendingPathComponent("codemax.prev") }
    nonisolated static var stateFile: URL { binDirectory.appendingPathComponent("update-state.json") }
    nonisolated static var assetName: String {
        #if arch(arm64)
        return "codemax-darwin-arm64"
        #else
        return "codemax-darwin-x64"
        #endif
    }

    private var timer: Timer?
    private var checking = false

    nonisolated static func loadState() -> State {
        guard let d = try? Data(contentsOf: stateFile), let s = try? JSONDecoder().decode(State.self, from: d) else { return State() }
        return s
    }
    nonisolated static func saveState(_ s: State) {
        try? FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: stateFile, options: .atomic) }
    }

    /// The codemax EditMax runs now: the updated copy when one is active, else the bundled one.
    nonisolated static func activeBinary() -> URL? {
        let s = loadState()
        if s.active == "updated", FileManager.default.isExecutableFile(atPath: installedBinary.path) { return installedBinary }
        return CodemaxRunner.bundledBinary(.codemax)
    }

    /// a > b for x.y.z versions.
    nonisolated static func isNewer(_ a: String, _ b: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.replacingOccurrences(of: "^v", with: "", options: .regularExpression).split(separator: "-")[0].split(separator: ".").map { Int($0) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<3 { let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0; if p != q { return p > q } }
        return false
    }

    /// Launch: check soon (EDITMAX_UPDATE_NOW=1: at once), then every 12 hours.
    func start() {
        refreshStatus()
        let now = ProcessInfo.processInfo.environment["EDITMAX_UPDATE_NOW"] == "1"
        let s = Self.loadState()
        let due = now || (s.lastCheck.map { Date().timeIntervalSince($0) >= Self.checkEvery } ?? true)
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0.5 : 20)) { [weak self] in if due { self?.check(reason: now ? "env" : "launch") } }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if Self.loadState().lastCheck.map({ Date().timeIntervalSince($0) >= Self.checkEvery }) ?? true { self.check(reason: "timer") }
            }
        }
    }

    func refreshStatus() {
        let s = Self.loadState()
        status.activeSource = s.active == "updated" ? "updated" : "bundled"
        status.activeVersion = s.active == "updated" ? s.updatedVersion : CodemaxInstaller.shared.status.bundledVersion
        status.latest = s.latest
        status.lastCheck = s.lastCheck
        status.nextCheck = s.lastCheck.map { $0.addingTimeInterval(Self.checkEvery) }
        if status.message == "Not checked yet.", let l = s.lastCheck { status.message = "Last checked \(Self.ago(l))." }
    }

    private static func ago(_ d: Date) -> String {
        let m = Int(Date().timeIntervalSince(d) / 60)
        return m < 1 ? "just now" : m < 60 ? "\(m) min ago" : m < 60 * 48 ? "\(m / 60) h ago" : "\(m / 1440) days ago"
    }

    /// "Check now" and the schedule. Never two at once.
    func check(reason: String) {
        guard !checking else { return }
        checking = true
        status.busy = true
        status.message = "Checking for a codemax update…"
        let bundledVersion = CodemaxInstaller.shared.status.bundledVersion ?? CodemaxInstaller.version(of: CodemaxRunner.bundledBinary(.codemax) ?? URL(fileURLWithPath: "/nonexistent"))
        Task.detached(priority: .utility) {
            let message = await Self.runCheck(reason: reason, bundledVersion: bundledVersion)
            await MainActor.run {
                self.checking = false
                self.status.busy = false
                self.refreshStatus()
                self.status.message = message
            }
        }
    }

    /// A release: `asset` is nil when it has no binary for this Mac.
    struct Release { let version: String; let asset: URL?; let sha: URL? }

    nonisolated private static func latestRelease() async throws -> Release? {
        let url = ProcessInfo.processInfo.environment["EDITMAX_UPDATE_URL"].flatMap(URL.init(string:)) ?? releasesURL
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("EditMax", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CodemaxRunner.Failure(message: "no HTTP response") }
        guard http.statusCode == 200 else { throw CodemaxRunner.Failure(message: "GitHub answered \(http.statusCode)") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = obj["tag_name"] as? String else { throw CodemaxRunner.Failure(message: "no tag_name in the release") }
        let version = tag.replacingOccurrences(of: "^v", with: "", options: .regularExpression)
        let assets = obj["assets"] as? [[String: Any]] ?? []
        func asset(_ name: String) -> URL? { assets.first { ($0["name"] as? String) == name }.flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) } }
        return Release(version: version, asset: asset(assetName), sha: asset(assetName + ".sha256"))
    }

    /// The whole check, off the main actor. Returns the line for the Agents tab.
    nonisolated private static func runCheck(reason: String, bundledVersion: String?) async -> String {
        var s = loadState()
        let current = s.active == "updated" ? (s.updatedVersion ?? "0.0.0") : (bundledVersion ?? "0.0.0")
        DebugLog.event("update-check", ["reason": reason, "current": current, "source": s.active])
        let rel: Release?
        do { rel = try await latestRelease() } catch {
            DebugLog.error("update-check-failed", error)
            s.lastCheck = Date(); saveState(s)
            return "Could not check for updates: \(error.localizedDescription)"
        }
        s.lastCheck = Date()
        guard let rel else { s.latest = nil; saveState(s); return "No release found." }
        s.latest = rel.version
        saveState(s)
        guard isNewer(rel.version, current) else { return "codemax \(current) is current (latest release \(rel.version))." }
        guard !s.badVersions.contains(rel.version) else { return "codemax \(rel.version) is available but failed here before; staying on \(current)." }
        guard let assetURL = rel.asset else {
            DebugLog.event("update-no-asset", ["version": rel.version, "asset": assetName])
            return "codemax \(rel.version) is released without a \(assetName) binary; staying on \(current)."
        }
        // Download next to the binaries, check the checksum, then make sure it runs before it takes over.
        let tmp = binDirectory.appendingPathComponent("codemax-\(rel.version).download")
        do {
            try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
            DebugLog.event("update-download", ["version": rel.version, "url": assetURL.absoluteString])
            let (file, resp) = try await URLSession.shared.download(for: URLRequest(url: assetURL, timeoutInterval: 300))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw CodemaxRunner.Failure(message: "download answered \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
            if FileManager.default.fileExists(atPath: tmp.path) { try FileManager.default.removeItem(at: tmp) }
            try FileManager.default.moveItem(at: file, to: tmp)
            if let shaURL = rel.sha {
                let (shaData, _) = try await URLSession.shared.data(from: shaURL)
                let want = String(decoding: shaData, as: UTF8.self).split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? ""
                let got = digest(of: tmp)
                guard want.lowercased() == got else { throw CodemaxRunner.Failure(message: "checksum mismatch (expected \(want.prefix(12))…, got \(got.prefix(12))…)") }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
            removeQuarantine(tmp)
            try healthCheck(tmp, expectVersion: rel.version)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            s.badVersions.append(rel.version); saveState(s)
            DebugLog.error("update-rejected", error, ["version": rel.version])
            return "codemax \(rel.version) was downloaded but failed its check (\(error.localizedDescription)); staying on \(current). It will not be tried again."
        }
        // Swap: the running copy becomes .prev (the way back), the new one takes its name.
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: previousBinary.path) { try fm.removeItem(at: previousBinary) }
            if fm.fileExists(atPath: installedBinary.path) { try fm.moveItem(at: installedBinary, to: previousBinary) }
            try fm.moveItem(at: tmp, to: installedBinary)
            s.active = "updated"; s.updatedVersion = rel.version; s.failures = []
            saveState(s)
            DebugLog.event("update-installed", ["version": rel.version, "from": current])
            return "codemax updated to \(rel.version) (was \(current)). The next chat session uses it."
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            DebugLog.error("update-swap-failed", error, ["version": rel.version])
            return "codemax \(rel.version) passed its check but could not be put in place: \(error.localizedDescription)"
        }
    }

    /// `--version` must print the release's version; `serve` must say ready and answer `agents` within 20 s.
    nonisolated static func healthCheck(_ bin: URL, expectVersion: String) throws {
        guard let v = CodemaxInstaller.version(of: bin) else { throw CodemaxRunner.Failure(message: "--version printed nothing") }
        guard v == expectVersion || v == "v" + expectVersion else { throw CodemaxRunner.Failure(message: "--version printed \(v), expected \(expectVersion)") }
        let p = Process(); p.executableURL = bin; p.arguments = ["serve"]
        var env = ProcessInfo.processInfo.environment; env["PATH"] = CodemaxRunner.spawnPATH; p.environment = env
        let work = CodemaxInstaller.supportDirectory.appendingPathComponent("agent")
        p.currentDirectoryURL = work
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = FileHandle.nullDevice
        try p.run()
        inPipe.fileHandleForWriting.write(Data("{\"id\":1,\"method\":\"agents\"}\n".utf8))
        let deadline = Date().addingTimeInterval(20)
        var buf = Data(); var ready = false; var answered = false
        let reader = outPipe.fileHandleForReading
        while Date() < deadline, !(ready && answered) {
            let chunk = reader.availableData
            if chunk.isEmpty { if !p.isRunning { break }; Thread.sleep(forTimeInterval: 0.05); continue }
            buf.append(chunk)
            let text = String(decoding: buf, as: UTF8.self)
            if text.contains("\"event\":\"ready\"") { ready = true }
            if text.contains("\"id\":1,\"result\"") || text.contains("\"id\":1,\"error\"") { answered = true }
        }
        inPipe.fileHandleForWriting.write(Data("{\"method\":\"close\"}\n".utf8))
        try? inPipe.fileHandleForWriting.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
        DebugLog.event("update-health", ["binary": bin.lastPathComponent, "version": v, "ready": ready, "answered": answered])
        guard ready else { throw CodemaxRunner.Failure(message: "serve never said ready") }
        guard answered else { throw CodemaxRunner.Failure(message: "serve did not answer `agents` within 20 s") }
    }

    nonisolated static func digest(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func removeQuarantine(_ url: URL) {
        _ = url.withUnsafeFileSystemRepresentation { path in removexattr(path, "com.apple.quarantine", 0) }
    }

    /// An updated codemax exited with an error (the runner reports it). One that never said ready, or two failures within
    /// ten minutes, put it on the bad list and bring the previous copy back.
    func noteFailure(binary: URL, status exitStatus: Int32, startedOK: Bool, detail: String) {
        guard binary == Self.installedBinary else { return }
        recordFailure(weight: startedOK ? 1 : 2, fields: ["status": Int(exitStatus), "startedOK": startedOK, "detail": String(detail.suffix(300))])
    }

    /// The updated codemax runs but cannot do its job: listing agents, configuring one that is installed, or a turn that
    /// ended in a protocol error. Counted like a crash (two within ten minutes roll back). Returns true when it rolled back.
    @discardableResult
    func noteAgentFailure(_ what: String, detail: String) -> Bool {
        recordFailure(weight: 1, fields: ["what": what, "detail": String(detail.suffix(300))])
    }

    @discardableResult
    private func recordFailure(weight: Int, fields: [String: Any]) -> Bool {
        var s = Self.loadState()
        guard s.active == "updated", let v = s.updatedVersion else { return false }
        s.failures = s.failures.filter { Date().timeIntervalSince($0) < 600 } + Array(repeating: Date(), count: weight)
        var f = fields; f["version"] = v; f["count"] = s.failures.count
        DebugLog.event("update-failure", f)
        guard s.failures.count >= 2 else { Self.saveState(s); return false }
        let fm = FileManager.default
        let bad = Self.binDirectory.appendingPathComponent("codemax.bad")
        try? fm.removeItem(at: bad)
        try? fm.moveItem(at: Self.installedBinary, to: bad)
        var restored = "the bundled copy"
        if fm.fileExists(atPath: Self.previousBinary.path), (try? fm.moveItem(at: Self.previousBinary, to: Self.installedBinary)) != nil,
           let pv = CodemaxInstaller.version(of: Self.installedBinary), !s.badVersions.contains(pv),
           let bundled = CodemaxInstaller.shared.status.bundledVersion, Self.isNewer(pv, bundled) {
            s.active = "updated"; s.updatedVersion = pv; restored = "codemax \(pv)"
        } else {
            s.active = "bundled"; s.updatedVersion = nil
            // The installed copy (what ~/.local/bin/codemax points at) goes back to the bundled build.
            if let b = CodemaxRunner.bundledBinary(.codemax) { try? fm.removeItem(at: Self.installedBinary); try? fm.copyItem(at: b, to: Self.installedBinary) }
        }
        s.badVersions.append(v); s.failures = []
        Self.saveState(s)
        try? fm.removeItem(at: bad)
        DebugLog.event("update-rollback", ["from": v, "to": s.updatedVersion ?? "bundled"])
        self.status.message = "codemax \(v) kept failing and was rolled back to \(restored)."
        refreshStatus()
        return true
    }
}
