import Foundation

/// Long work a restart would cut short: exports and agent replies. The update popup waits while any of it runs, and
/// Install Now pressed during it waits too (UpdatePrompt); quitting during an export asks first (QuitGuard). Counted,
/// so overlapping work of one kind is fine.
enum BusyWork {
    static let export = "an export"
    static let agentReply = "an agent reply"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    static func begin(_ what: String) { lock.withLock { counts[what, default: 0] += 1 } }
    static func end(_ what: String) { lock.withLock { counts[what] = max(0, (counts[what] ?? 0) - 1) } }

    static func isRunning(_ what: String) -> Bool { lock.withLock { (counts[what] ?? 0) > 0 } }

    /// What is running now ("an export"), or nil when nothing is.
    static var current: String? { lock.withLock { counts.filter { $0.value > 0 }.keys.sorted().first } }
}
