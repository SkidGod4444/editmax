import Foundation
import Combine
import Sparkle

/// EditMax's own updates, through Sparkle (the agent runtime has its own updater, `CodemaxUpdater`).
///
/// Where it looks: `SUFeedURL`, the `appcast.xml` that `scripts/release.sh` attaches to every GitHub release, read
/// through `releases/latest/download/`. An update is the release's notarized zip, checked against `SUPublicEDKey` (the
/// matching private key is in the login keychain under the account `editmax`) and against the app's Developer ID
/// signature before it is installed. By default it checks once a day and downloads in the background, then installs
/// the next time EditMax quits; with automatic installs off it asks first. Check for Updates… asks right away.
///
/// Off in Debug builds and in the unit tests: a Debug build would offer to "update" itself to the published release.
/// `EDITMAX_UPDATES=1` turns it on in a Debug build to try the flow.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    nonisolated static var isEnabled: Bool {
        if AppDelegate.isTesting { return false }
        #if DEBUG
        return ProcessInfo.processInfo.environment["EDITMAX_UPDATES"] == "1"
        #else
        return true
        #endif
    }

    private let controller: SPUStandardUpdaterController
    private var bag = Set<AnyCancellable>()
    var updater: SPUUpdater { controller.updater }

    /// False while a check is running and whenever the updater is off.
    @Published private(set) var canCheck = false
    @Published private(set) var lastCheck: Date?
    @Published var checksAutomatically: Bool { didSet { updater.automaticallyChecksForUpdates = checksAutomatically } }
    @Published var installsAutomatically: Bool { didSet { updater.automaticallyDownloadsUpdates = installsAutomatically } }

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: Self.isEnabled, updaterDelegate: nil, userDriverDelegate: nil)
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        installsAutomatically = controller.updater.automaticallyDownloadsUpdates
        lastCheck = controller.updater.lastUpdateCheckDate
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 && Self.isEnabled }.store(in: &bag)
        controller.updater.publisher(for: \.lastUpdateCheckDate).receive(on: RunLoop.main)
            .sink { [weak self] in self?.lastCheck = $0 }.store(in: &bag)
        DebugLog.event("app-updater", ["enabled": Self.isEnabled, "feed": controller.updater.feedURL?.absoluteString ?? "",
                                       "auto-check": checksAutomatically, "auto-install": installsAutomatically])
    }

    /// Starts the updater (called once at launch); the checks then run on Sparkle's schedule.
    func start() {}

    /// Check now and show the result, whatever the automatic settings say.
    func checkForUpdates() {
        guard Self.isEnabled else { return }
        DebugLog.event("app-update-check", ["by": "user"])
        controller.checkForUpdates(nil)
    }
}
