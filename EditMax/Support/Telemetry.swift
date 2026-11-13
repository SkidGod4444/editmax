import Foundation
import PostHog

/// Crash reports and feature counts, sent to PostHog (US cloud) once the person has agreed on the
/// first-launch card (`TelemetryPrompt`). Nothing is sent before that; the card comes back each launch until it is
/// agreed to.
///
/// What goes: crashes (caught by the SDK's crash handler and sent on the next launch), a few handled failures
/// (`failed`), and the events in `Event` with small numbers or fixed choices. The SDK adds the app version, macOS
/// version, Mac model (never its name), locale and time zone. Never footage, text, file names or anything typed:
/// handled failures go as their error domain and code only, and `Sanitizer` drops any of our property strings that
/// look like a path or run long, and blanks the user's name out of home-folder paths anywhere (crash frames too).
///
/// Off in the unit tests, on CI and in development builds; `EDITMAX_POSTHOG=1` turns it on in a development build to
/// try it, `EDITMAX_POSTHOG_DEBUG=1` adds the SDK's own log.
@MainActor
final class Telemetry: ObservableObject {
    static let shared = Telemetry()

    /// PostHog's project token is public by design: it can only send events, never read them.
    static let projectToken = "phc_BQfzCbWkCLC3JeN9bBLKcKMwLNnRfy27sEBxvcounozp"
    static let host = "https://us.i.posthog.com"
    /// Raised when what is sent changes enough to show the card again.
    static let terms = 1
    static let agreedKey = "telemetry.agreedTerms"

    /// Whether this build may send anything at all.
    nonisolated static func isAvailable(environment: [String: String] = ProcessInfo.processInfo.environment, debugBuild: Bool = isDebugBuild,
                                        testHost: Bool = NSClassFromString("XCTestCase") != nil) -> Bool {
        if testHost || environment["XCTestConfigurationFilePath"] != nil { return false }
        if environment["CI"] != nil { return false }
        return !debugBuild || environment["EDITMAX_POSTHOG"] == "1"
    }
    nonisolated static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    var defaults: UserDefaults = .standard
    @Published private(set) var started = false
    var agreed: Bool { defaults.integer(forKey: Self.agreedKey) >= Self.terms }

    /// At launch: starts sending if the person has agreed.
    func start() {
        guard Self.isAvailable(), agreed, !started else { return }
        let env = ProcessInfo.processInfo.environment
        let config = PostHogConfig(projectToken: Self.projectToken, host: Self.host)
        config.errorTrackingConfig.autoCapture = true
        config.captureApplicationLifecycleEvents = false   // fires on every activation on macOS: `appLaunched` instead
        config.captureScreenViews = false
        config.enableSwizzling = false   // EditMax swizzles NSMenu itself (MenuCapture); no second swizzler on AppKit
        config.disableGeoIp = true
        config.personProfiles = .never   // no person profiles: nothing is ever identified
        let debugBuild = Self.isDebugBuild
        config.setBeforeSend { event in
            event.properties = Sanitizer.clean(event.properties)
            if debugBuild { event.properties["debug_build"] = true }   // the project's test-account filter leaves these out of charts
            return event
        }
        config.debug = env["EDITMAX_POSTHOG_DEBUG"] == "1"
        PostHogSDK.shared.setup(config)
        PostHogSDK.shared.optIn()
        started = true
        DebugLog.event("telemetry-started", [:])
        capture(.appLaunched)
    }

    /// The card's Agree.
    func agree() {
        defaults.set(Self.terms, forKey: Self.agreedKey)
        DebugLog.event("telemetry-agreed", ["terms": Self.terms])
        start()
    }

    // MARK: Events

    enum Event: String {
        case appLaunched = "app_launched"
        case projectOpened = "project_opened"
        case exportFinished = "export_finished"
        case exportFailed = "export_failed"
        case transcribeFinished = "transcribe_finished"
        case agentTurn = "agent_turn"
        /// A plugin was installed: where from (hub or file) and how many skills and servers, never its name.
        case pluginInstalled = "plugin_installed"
    }

    func capture(_ event: Event, _ properties: [String: Any] = [:]) {
        guard started else { return }
        PostHogSDK.shared.capture(event.rawValue, properties: properties)
    }

    /// A handled failure worth fixing (an export, a render, the agent runtime), as its error domain and code only: an
    /// error's text can carry a file name.
    func failed(_ error: Error, at place: String) {
        guard started else { return }
        let e = error as NSError
        let plain = NSError(domain: e.domain, code: e.code, userInfo: [NSLocalizedDescriptionKey: "\(e.domain) \(e.code)"])
        PostHogSDK.shared.captureException(plain, properties: ["where": place])
    }

    /// The agent runtime's failure, by its kind ("protocol", "crashed", "quota"…) and the harness's own error kind
    /// (`incomplete_tool_call`), never its message. The detail names the issue in PostHog: "EditMax.Agent.protocol 0"
    /// said nothing.
    func agentFailed(kind: String, backend: String, detail: String? = nil) {
        guard started else { return }
        let k = Self.slug(kind) ?? "other"
        var props: [String: Any] = ["backend": backend, "failed": k]
        let d = detail.flatMap(Self.slug)
        if let d { props["detail"] = d }
        capture(.agentTurn, props)
        if k == "protocol" || k == "crashed" { failed(NSError(domain: "EditMax.Agent.\(k)" + (d.map { ".\($0)" } ?? ""), code: 0), at: "agent") }
    }

    /// `{"errorKind":"incomplete_tool_call"}` in a harness error: the kind alone, which carries no user text.
    nonisolated static func errorKind(in message: String) -> String? {
        guard let r = message.range(of: #""errorKind"\s*:\s*"([a-z_]{1,32})""#, options: .regularExpression) else { return nil }
        let quoted = message[r].split(separator: "\"")
        return quoted.count >= 3 ? String(quoted[quoted.count - 1]) : nil
    }

    nonisolated private static func slug(_ s: String) -> String? { s.range(of: #"^[a-z_-]{1,32}$"#, options: .regularExpression) != nil ? s : nil }

    /// A count as a coarse bucket, so no event carries an exact length that could tell projects apart.
    nonisolated static func bucket(_ n: Double, _ edges: [Double]) -> String {
        guard let i = edges.firstIndex(where: { n < $0 }) else { return "\(Self.short(edges.last ?? 0))+" }
        return i == 0 ? "<\(Self.short(edges[0]))" : "\(Self.short(edges[i - 1]))-\(Self.short(edges[i]))"
    }
    nonisolated private static func short(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(x) }
    /// Seconds of video: under a minute, 1–10 min, 10–60 min, 1–3 h, 3 h and longer.
    nonisolated static func lengthBucket(_ seconds: Double) -> String {
        switch seconds {
        case ..<60: "<1m"
        case ..<600: "1-10m"
        case ..<3600: "10-60m"
        case ..<10_800: "1-3h"
        default: "3h+"
        }
    }

    // MARK: Sanitizer

    /// Runs on every event before it is stored or sent (the SDK's `beforeSend`).
    enum Sanitizer {
        nonisolated static func clean(_ properties: [String: Any]) -> [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in properties {
                if !k.hasPrefix("$"), let s = v as? String, s.contains("/") || s.count > 64 { continue }   // ours: no paths, no text
                out[k] = scrub(v)
            }
            return out
        }

        /// The user's name out of home-folder paths, at any depth (crash frames carry image paths).
        nonisolated static func scrub(_ v: Any) -> Any {
            switch v {
            case let s as String: return scrubHome(s)
            case let d as [String: Any]: return d.mapValues(scrub)
            case let a as [Any]: return a.map(scrub)
            default: return v
            }
        }

        nonisolated static func scrubHome(_ s: String) -> String {
            guard s.contains("/Users/") else { return s }
            return s.replacingOccurrences(of: #"/Users/[^/\s"']+"#, with: "/Users/~", options: .regularExpression)
        }
    }
}
