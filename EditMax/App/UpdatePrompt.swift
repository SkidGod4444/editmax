import AppKit
import SwiftUI
import Sparkle
import UserNotifications

/// "EditMax x.y is ready": the Liquid Glass popup that offers a downloaded update.
/// - **Install Now** saves every open project and lets Sparkle install and relaunch.
/// - **Remind Me Later** closes it. While EditMax is in front it comes back every 2 hours; while EditMax runs in the
///   background a Mac notification reminds every 6 hours instead (its Install Now button installs straight away, a
///   click on it brings the popup). Sparkle still installs the update when EditMax quits, so Later never loses it.
/// - After the relaunch onto the new version (Install Now, or a quit and reopen) a card says it is installed, once,
///   after the splash.
///
/// When: Sparkle downloads updates in the background (`SUAutomaticallyUpdate`) and, once one is ready, hands it to
/// `AppUpdaterDelegate`, which brings it here. With background downloads turned off in Settings, Sparkle's own window
/// asks instead.
///
/// It never interrupts: it never pulls EditMax over another app (it waits until EditMax is in front), never takes the
/// keyboard from what you are typing in (the panel does not become key; Return does not mean Install Now), and waits
/// while an export or an agent reply is running (`BusyWork`). Install Now pressed while one starts waits for it too.
/// EditMax ▸ Check for Updates… shows it again while an update is waiting.
@MainActor
final class UpdatePrompt: ObservableObject {
    static let shared = UpdatePrompt()

    struct Offer: Equatable, Codable {
        let version: String
        let notes: URL?
    }

    @Published private(set) var offer: Offer?
    /// The card on screen: the waiting update, or the one just installed.
    private(set) var showing: UpdatePromptView.Mode?
    var isShowing: Bool { panel?.isVisible == true }

    /// Seams for the tests.
    var appIsActive: () -> Bool = { NSApp.isActive }
    /// What the update card waits for; the crash-report card holds the app until Agree, so the update card comes after.
    var busy: () -> String? = { TelemetryPrompt.shared.isShowing ? "crash-report card" : BusyWork.current }
    var clock: () -> Date = { Date() }
    var activeEvery: TimeInterval = 2 * 3600       // the popup again, while EditMax is in front
    var backgroundEvery: TimeInterval = 6 * 3600   // a notification, while EditMax runs in the background
    var tickEvery: TimeInterval = 60
    var idleCheck: TimeInterval = 5
    var installedNoteFor: TimeInterval = 15
    var notify: (Offer) -> Void = { UpdateNotifications.post($0) }
    var askNotificationPermission: () -> Void = { UpdateNotifications.requestPermission() }
    var defaults: UserDefaults = .standard
    var currentVersion: () -> String = { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    /// Asks Sparkle again (when the last quit did not install the offered version).
    var checkAgain: () -> Void = { AppUpdater.shared.checkQuietly() }
    var offscreen = false
    var window: NSPanel? { panel }

    private var install: (() -> Void)?
    private var panel: UpdatePromptPanel?
    private var waitingForFront: NSObjectProtocol?
    private var waitingForIdle: Timer?
    private var ticker: Timer?
    private var reminding = false
    private var lastPopup = Date.distantPast
    private var lastNotice = Date.distantPast
    private var noteTimer: Timer?

    /// The update the user was offered, so the relaunch onto it can say "installed".
    static let offeredKey = "EditMaxUpdateOffered"

    init() {}

    /// A downloaded, verified update. `install` installs it and relaunches EditMax (Sparkle's immediate install).
    func offer(version: String, notes: URL?, remember: Bool = true, install: @escaping () -> Void) {
        let o = Offer(version: version, notes: notes)
        offer = o
        self.install = install
        if remember, let data = try? JSONEncoder().encode(o) { defaults.set(data, forKey: Self.offeredKey) }
        DebugLog.event("app-update-ready", ["version": version])
        present()
    }

    /// Shows the popup now if EditMax is in front and nothing long is running, otherwise once both hold.
    func present() {
        guard let offer else { return }
        if let what = busy() { waitForIdle(what); return }
        guard appIsActive() else { waitForFront(); return }
        show(.ready(offer))
    }

    func installNow() {
        guard let install else { return }
        if let what = busy() {   // an export or agent reply started while the popup was up: never cut it short
            DebugLog.event("app-update-install-waits", ["for": what])
            close(); waitForIdle(what); return
        }
        DebugLog.event("app-update-install-now", ["version": offer?.version ?? "", "projects": DocumentRegistry.shared.documents.count])
        for doc in DocumentRegistry.shared.documents { doc.autosaveNow() }
        close()
        install()   // Sparkle quits, installs and relaunches; if the quit is cancelled the update still waits
    }

    /// Remind Me Later: every 2 h while EditMax is in front, a notification every 6 h while it is in the background.
    func later() {
        DebugLog.event("app-update-later", ["version": offer?.version ?? "", "popup-every-s": Int(activeEvery), "notify-every-s": Int(backgroundEvery)])
        close()
        let now = clock()
        lastPopup = now; lastNotice = now
        if !reminding { askNotificationPermission() }
        reminding = true
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: tickEvery, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// One look at the reminder clock (every `tickEvery`).
    func tick() {
        guard reminding, let offer, !isShowing, waitingForIdle == nil else { return }
        let now = clock()
        if appIsActive() {
            guard now.timeIntervalSince(lastPopup) >= activeEvery else { return }
            DebugLog.event("app-update-remind", ["how": "popup", "version": offer.version])
            present()
        } else if now.timeIntervalSince(lastNotice) >= backgroundEvery {
            lastNotice = now
            DebugLog.event("app-update-remind", ["how": "notification", "version": offer.version])
            notify(offer)
        }
    }

    /// Called after the splash, when an update was offered before the last quit. On that version now: "EditMax x.y
    /// is installed", once. Still on the older one (the quit did not install it: the installer failed, or EditMax
    /// closed before Sparkle had it ready): Sparkle is asked again, picks the downloaded update back up and the popup
    /// returns. Already past it: the record goes.
    func showInstalledNoteIfUpdated() {
        guard let data = defaults.data(forKey: Self.offeredKey), let o = try? JSONDecoder().decode(Offer.self, from: data) else { return }
        switch o.version.compare(currentVersion(), options: .numeric) {
        case .orderedDescending:
            DebugLog.event("app-update-not-installed", ["offered": o.version, "running": currentVersion()])
            checkAgain()
            return
        case .orderedAscending:
            defaults.removeObject(forKey: Self.offeredKey)
            return
        case .orderedSame: break
        }
        defaults.removeObject(forKey: Self.offeredKey)
        DebugLog.event("app-update-installed", ["version": o.version])
        show(.installed(o))
        noteTimer?.invalidate()
        noteTimer = Timer.scheduledTimer(withTimeInterval: installedNoteFor, repeats: false) { [weak self] _ in
            Task { @MainActor in if case .installed = self?.showing { self?.close() } }
        }
    }

    // MARK: The window

    private func waitForIdle(_ what: String) {
        guard waitingForIdle == nil else { return }
        DebugLog.event("app-update-waits", ["for": what])
        waitingForIdle = Timer.scheduledTimer(withTimeInterval: idleCheck, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self, self.busy() == nil else { return }
                t.invalidate(); self.waitingForIdle = nil
                self.present()
            }
        }
    }

    private func waitForFront() {
        guard waitingForFront == nil else { return }
        waitingForFront = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let o = self.waitingForFront { NotificationCenter.default.removeObserver(o) }
                self.waitingForFront = nil
                self.present()
            }
        }
    }

    private func show(_ mode: UpdatePromptView.Mode) {
        let view = UpdatePromptView(mode: mode, install: { [weak self] in self?.installNow() }, later: { [weak self] in self?.later() },
                                    dismiss: { [weak self] in self?.close() })
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let panel = self.panel ?? UpdatePromptPanel()
        panel.contentView = host
        panel.setFrame(frame(for: host.frame.size), display: true)
        self.panel = panel
        showing = mode
        if case .ready = mode { lastPopup = clock() }
        panel.orderFront(nil)   // not key: whatever the user is typing in keeps the keyboard
        DebugLog.event("app-update-shown", ["card": mode.name])
    }

    private func close() {
        panel?.orderOut(nil)
        showing = nil
        if let o = waitingForFront { NotificationCenter.default.removeObserver(o) }
        waitingForFront = nil
    }

    /// Over the upper third of the window in front (a project or Home), else the middle of the screen.
    private func frame(for size: CGSize) -> CGRect {
        if offscreen { return CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size) }
        let anchor = (NSApp.keyWindow ?? NSApp.mainWindow).flatMap { $0 is NSPanel ? nil : $0 }
            ?? NSApp.orderedWindows.first { $0.isVisible && !($0 is NSPanel) }
        if let a = anchor?.frame {
            return CGRect(x: a.midX - size.width / 2, y: a.maxY - a.height / 3 - size.height / 2, width: size.width, height: size.height)
        }
        let s = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return CGRect(x: s.midX - size.width / 2, y: s.midY - size.height / 2 + s.height / 8, width: size.width, height: size.height)
    }

    /// Debug builds only: `-EditMaxUpdatePromptDemo YES` shows the popup with a made-up version, so its look can be
    /// checked without a release. Install Now and Later only close it (Later still starts the reminders).
    func startDemoIfAsked() {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "EditMaxUpdatePromptDemo") else { return }
        offer(version: "0.1.2", notes: URL(string: "https://github.com/SkidGod4444/editmax/releases/latest"), remember: false) { [weak self] in
            DebugLog.event("app-update-demo-install"); self?.offer = nil
        }
        #endif
    }
}

/// The reminder notification while EditMax runs in the background: Install Now installs straight away (after any
/// export), a click on the notification brings EditMax forward with the popup.
enum UpdateNotifications {
    static let category = "editmax.update"
    static let installAction = "editmax.update.install"
    private static let handler = Handler()

    /// At launch, so a click on a reminder reaches EditMax.
    static func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = handler
        let install = UNNotificationAction(identifier: installAction, title: "Install Now", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: category, actions: [install], intentIdentifiers: [])])
    }

    /// Asked once, when the user first picks Remind Me Later (they are there to answer).
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DebugLog.event("app-update-notify-permission", ["granted": granted])
        }
    }

    static func post(_ o: UpdatePrompt.Offer) {
        let content = UNMutableNotificationContent()
        content.title = "EditMax \(o.version) is ready"
        content.body = "Install it now, or it installs by itself the next time you quit EditMax."
        content.categoryIdentifier = category
        // One identifier: a new reminder replaces the last one instead of piling up.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "editmax.update", content: content, trigger: nil)) { error in
            if let error { DebugLog.event("app-update-notify-failed", ["error": error.localizedDescription]) }
        }
    }

    private final class Handler: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
            let action = response.actionIdentifier
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    DebugLog.event("app-update-notification-clicked", ["action": action])
                    NSApp.activate()
                    if action == UpdateNotifications.installAction { UpdatePrompt.shared.installNow() }
                    else if action == UNNotificationDefaultActionIdentifier { UpdatePrompt.shared.present() }
                }
                done()
            }
        }
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
            done([.banner, .list])
        }
    }
}

/// Sparkle's callbacks, kept apart from `AppUpdater` because Sparkle holds its delegate weakly and wants an NSObject.
final class AppUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private let prompt: () -> UpdatePrompt
    init(prompt: @escaping () -> UpdatePrompt = { MainActor.assumeIsolated { UpdatePrompt.shared } }) { self.prompt = prompt }

    /// A background download is ready and would install silently on quit: offer it now instead. Returning true tells
    /// Sparkle the app shows it (it still installs on quit if the user never says yes).
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString, notes = item.fullReleaseNotesURL ?? item.releaseNotesURL
        MainActor.assumeIsolated { prompt().offer(version: version, notes: notes, install: immediateInstallHandler) }
        return true
    }
}

/// The popup's window: borderless and clear (the card is the glass), floats over EditMax's windows only while
/// EditMax is in front, and never takes the keyboard.
final class UpdatePromptPanel: NSPanel {
    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 460, height: 200), styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .alertPanel
        isExcludedFromWindowsMenu = true
        becomesKeyOnlyIfNeeded = true   // clicking its buttons leaves the keyboard where it was
    }
    override var canBecomeMain: Bool { false }
}

/// The card: Liquid Glass (`glassEffect`, macOS 26; a material before it) with glass buttons grouped so they blend.
struct UpdatePromptView: View {
    enum Mode: Equatable {
        case ready(UpdatePrompt.Offer), installed(UpdatePrompt.Offer)
        var offer: UpdatePrompt.Offer { switch self { case .ready(let o), .installed(let o): o } }
        var name: String { if case .ready = self { "ready" } else { "installed" } }
    }

    let mode: Mode
    let install: () -> Void
    let later: () -> Void
    let dismiss: () -> Void

    private var title: String {
        switch mode {
        case .ready(let o): "EditMax \(o.version) is ready"
        case .installed(let o): "EditMax \(o.version) is installed"
        }
    }
    private var message: String {
        switch mode {
        case .ready: "Install Now saves your projects and restarts EditMax. Not now? It installs by itself the next time you quit."
        case .installed: "You're on the newest version. What's new lists everything that changed."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                if let notes = mode.offer.notes {
                    Button("What's new") { NSWorkspace.shared.open(notes) }
                        .buttonStyle(.link).font(.callout)
                        .pointer().help(notes.absoluteString).uiFrame("update.whatsNew")
                }
                Spacer(minLength: 12)
                GlassGroup(spacing: 10) {
                    HStack(spacing: 10) {
                        switch mode {
                        case .ready:
                            Button("Remind Me Later", action: later)
                                .glassButtonStyle().controlSize(.large)
                                .pointer().help("Reminds you every 2 hours while you use EditMax, or with a notification every 6 hours while it runs in the background. It still installs when you quit EditMax.")
                                .uiFrame("update.later").uiTap("update.later", later)
                            // No Return shortcut: a stray Return typed into a title must never restart EditMax.
                            Button("Install Now", action: install)
                                .glassButtonStyle(prominent: true).controlSize(.large)
                                .pointer().uiFrame("update.install").uiTap("update.install", install)
                        case .installed:
                            Button("OK", action: dismiss)
                                .glassButtonStyle(prominent: true).controlSize(.large)
                                .pointer().uiFrame("update.ok").uiTap("update.ok", dismiss)
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 480)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .environment(\.controlActiveState, .key)   // the panel is never key; Install Now still draws blue, not grey
        .padding(24)   // room for the window shadow
    }
}
