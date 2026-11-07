import AppKit
import SwiftUI
import Sparkle

/// "EditMax x.y is ready": the popup that offers a downloaded update. Install Now saves every open project and lets
/// Sparkle install and relaunch; Remind Me Later closes it and asks again a day later. Either way Sparkle still
/// installs the update when EditMax quits, so Later never loses it.
///
/// When: Sparkle downloads updates in the background (`SUAutomaticallyUpdate`) and, once one is ready, hands it to
/// `AppUpdaterDelegate`, which brings it here. Before this popup it was installed silently at the next quit, and the
/// user never heard about it. With background downloads turned off in Settings, Sparkle's own window asks instead.
///
/// It never pulls EditMax over another app: when EditMax is in the background, the popup waits until it comes to the
/// front. EditMax ▸ Check for Updates… shows it again while an update is waiting.
@MainActor
final class UpdatePrompt: ObservableObject {
    static let shared = UpdatePrompt()

    struct Offer: Equatable {
        let version: String
        let notes: URL?
    }

    @Published private(set) var offer: Offer?
    var isShowing: Bool { panel?.isVisible == true }

    /// Seams for the tests: whether EditMax is in front, how long Later waits, where the popup goes.
    var appIsActive: () -> Bool = { NSApp.isActive }
    var remindAfter: TimeInterval = 24 * 3600
    var offscreen = false

    private var install: (() -> Void)?
    private var panel: UpdatePromptPanel?
    private var reminder: Timer?
    private var waitingForFront: NSObjectProtocol?

    init() {}

    /// A downloaded, verified update. `install` installs it and relaunches EditMax (Sparkle's immediate install).
    func offer(version: String, notes: URL?, install: @escaping () -> Void) {
        offer = Offer(version: version, notes: notes)
        self.install = install
        DebugLog.event("app-update-ready", ["version": version])
        present()
    }

    /// Shows the popup now if EditMax is in front, otherwise the next time it is.
    func present() {
        guard offer != nil else { return }
        reminder?.invalidate(); reminder = nil
        guard appIsActive() else { waitForFront(); return }
        show()
    }

    func installNow() {
        guard let install else { return }
        DebugLog.event("app-update-install-now", ["version": offer?.version ?? "", "projects": DocumentRegistry.shared.documents.count])
        for doc in DocumentRegistry.shared.documents { doc.autosaveNow() }
        close()
        install()   // Sparkle quits, installs and relaunches; if the quit is cancelled the update still waits
    }

    func later() {
        DebugLog.event("app-update-later", ["version": offer?.version ?? "", "remind-in-s": Int(remindAfter)])
        close()
        reminder = Timer.scheduledTimer(withTimeInterval: remindAfter, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.present() }
        }
    }

    // MARK: The window

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

    private func show() {
        guard let offer else { return }
        let view = UpdatePromptView(offer: offer, install: { [weak self] in self?.installNow() }, later: { [weak self] in self?.later() })
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let panel = self.panel ?? UpdatePromptPanel()
        panel.contentView = host
        panel.setFrame(frame(for: host.frame.size), display: true)
        self.panel = panel
        if offscreen { panel.orderFront(nil) } else { panel.makeKeyAndOrderFront(nil) }
        DebugLog.event("app-update-shown", ["version": offer.version])
    }

    private func close() {
        panel?.orderOut(nil)
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
    /// checked without a release. Install Now and Later only close it.
    func startDemoIfAsked() {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "EditMaxUpdatePromptDemo") else { return }
        offer(version: "0.1.2", notes: URL(string: "https://github.com/SkidGod4444/editmax/releases/latest")) { [weak self] in
            DebugLog.event("app-update-demo-install"); self?.offer = nil
        }
        #endif
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

/// The popup's window: borderless and clear (the card draws its own glass), floats over EditMax's windows only while
/// EditMax is in front, and takes the keyboard (Return installs, Esc is Remind Me Later).
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
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct UpdatePromptView: View {
    let offer: UpdatePrompt.Offer
    let install: () -> Void
    let later: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text("EditMax \(offer.version) is ready")
                        .font(.title3.weight(.semibold))
                    Text("Install Now saves your projects and restarts EditMax. Not now? It installs by itself the next time you quit.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                if let notes = offer.notes {
                    Button("What's new") { NSWorkspace.shared.open(notes) }
                        .buttonStyle(.link).font(.callout)
                        .pointer().help(notes.absoluteString).uiFrame("update.whatsNew")
                }
                Spacer(minLength: 12)
                Button("Remind Me Later", action: later)
                    .keyboardShortcut(.cancelAction).glassButtonStyle().controlSize(.large)
                    .pointer().help("Asks again tomorrow. It still installs when you quit EditMax.")
                    .uiFrame("update.later").uiTap("update.later", later)
                Button("Install Now", action: install)
                    .keyboardShortcut(.defaultAction).glassButtonStyle(prominent: true).controlSize(.large)
                    .pointer().uiFrame("update.install").uiTap("update.install", install)
            }
        }
        .padding(22)
        .frame(width: 480)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(24)   // room for the window shadow
    }
}
