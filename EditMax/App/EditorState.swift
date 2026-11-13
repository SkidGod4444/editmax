import Foundation
import Combine
import AppKit

/// Per-window UI state that is not part of the document.
@MainActor
final class EditorState: ObservableObject {
    @Published var selectedClipIDs: Set<UUID> = []
    @Published var selectedTextID: UUID?
    @Published var pixelsPerSecond: Double = 60
    @Published var inspectorTab: InspectorTab = .inspector
    @Published var exportStatus: String?
    /// A short line at the top of the window that goes by itself (a drive plugged in or removed).
    @Published var notice: String?

    func notify(_ line: String) {
        notice = line
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            if notice == line { notice = nil }
        }
    }
    @Published var isExporting = false
    /// Range marked with I and O; "Delete range" ripples it out of every track.
    @Published var inPoint: Double?
    @Published var outPoint: Double?
    enum InspectorTab: String, CaseIterable { case inspector = "Inspector", chat = "Chat", agents = "Agents", history = "History" }
    @Published var chat: ChatSession?
    /// Focus layout: only the player and the chat (no media list, inspector or timeline).
    @Published var focusMode = false
    /// File ▸ Import Media… (⌘I): the media list opens its file picker when this changes.
    @Published var importRequest = 0
    /// History tab: the version being shown in the preview instead of the live project (nil = current). Not an edit.
    @Published var viewingVersion: ProjectVersion?
    /// Timeline edit tool: select (move/trim), roll, slip or slide (TrimTools.swift).
    @Published var editTool: EditTool = .select
    /// Follow the agent (AgentFollow.swift): where in the inspector an agent edit lands.
    let reveal = RevealState()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let launchedAt = Date()
    /// The splash floats above every window, so it only shows for a launch the user made: Launch Services activates the
    /// app right after launch; a background launch (`open -g`, the agent's test relaunches) never does, and gets none.
    func applicationDidBecomeActive(_ notification: Notification) {
        if Date().timeIntervalSince(launchedAt) < 2, AppSettings.bool(AppSettings.Key.showSplash, default: true) { SplashScreen.shared.show(); SplashScreen.shared.dismissWhenReady() }
        // Just updated? "EditMax x.y is installed", once, after the splash (at once when there is none).
        // Not agreed yet to crash reports and usage? The card, after the splash (and after the installed note).
        // A first launch: Home, then the welcome demo on a scratch project, then the card. Help ▸ Welcome Tour plays it again.
        if !Self.isTesting {
            SplashScreen.shared.afterDismiss {
                UpdatePrompt.shared.showInstalledNoteIfUpdated()
                WelcomeTour.shared.startFirstRun { TelemetryPrompt.shared.askIfNeeded() }
            }
        }
    }
    /// True when the app is the host of the unit tests: no splash, no Home, no untitled document handling.
    static let isTesting = NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// A test run hosts its tests inside a copy of the app: keep that copy out of the Dock and the app switcher, so a
    /// test run never looks like a second EditMax.
    func applicationWillFinishLaunching(_ notification: Notification) {
        if Self.isTesting { NSApp.setActivationPolicy(.accessory) }
        OverlayScrollers.install()   // slim scroll bars that show only while scrolling, before any window exists
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.isTesting { return }
        InteractionLog.install()
        WelcomeTour.cleanLeftovers()   // a scratch demo project a quit left behind
        // Debug check: `-EditMaxTourDemo YES` plays the demo in a background launch too, which never gets the splash.
        if WelcomeTour.shared.forced { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { WelcomeTour.shared.startFirstRun { TelemetryPrompt.shared.askIfNeeded() } } }
        DriveWatcher.shared.start()   // footage on drives goes offline and comes back with them
        PushToTalk.shared.install()   // hold right ⌥ to speak to the agent
        AppSettings.shared.applyAppearance()
        SplashScreen.renderIfRequested()
        if ProcessInfo.processInfo.arguments.contains("-splash-preview") { SplashScreen.shared.show(); SplashScreen.shared.dismissWhenReady() }
        // No NSApp.activate here: a normal launch is activated by Launch Services, and a background launch (`open -g`)
        // must stay in the background.
        // Home (the project library) is the launch screen. On a plain launch it is put up right away so the document
        // machinery never sees an app without windows (that is what makes it present an Open panel). A launch that opens
        // or restores a project waits for that project instead, and shows Home only if none arrives (no flash of Home).
        let isDefault = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        let plan = HomeWindow.launchPlan(isDefaultLaunch: isDefault, projectOpen: HomeWindow.projectOpen,   // an empty untitled one is no project
                                         projectInArguments: ProcessInfo.processInfo.arguments.contains(where: { $0.hasSuffix(".emx") || $0.hasSuffix(".editmax") }))
        DebugLog.event("launch-plan", ["default": isDefault, "plan": "\(plan)"])
        switch plan {
        case .showNow: SplashScreen.shared.afterDismiss { if NSDocumentController.shared.documents.isEmpty { HomeWindow.shared.show() } }
        case .waitForProject: Task { await HomeWindow.shared.waitForLaunchProject() }
        case .nothing: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // DocumentGroup opens an empty untitled document on its own (the delegate is not asked); close it and show
            // Home instead. An untitled document with edits (restored from a crash) stays.
            let docs = NSDocumentController.shared.documents
            DebugLog.event("launch-docs", ["count": docs.count, "untitled": docs.filter { $0.fileURL == nil }.count, "edited": docs.filter(\.isDocumentEdited).count])
            for d in docs where d.fileURL == nil {
                if !d.isDocumentEdited { d.close(); continue }
                for w in d.windowControllers.compactMap(\.window) { w.alphaValue = 1; w.animationBehavior = .documentWindow }   // kept: shown after all
            }
            Self.launchSettled = true
            // With a splash up, Home waits until it has faded: the splash plays, then the app opens. (A launch waiting for
            // its project leaves this to the wait.)
            guard plan == .showNow else { return }
            SplashScreen.shared.afterDismiss { if NSDocumentController.shared.documents.isEmpty { HomeWindow.shared.show() } }
        }
        // The notch drawer comes up once the splash has gone. The splash starts within 2 s of launch or not at all
        // (applicationDidBecomeActive), so by then either it is up and the drawer waits for it, or it never comes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { SplashScreen.shared.afterDismiss { NotchDrawer.shared.start() } }
        // Deleted files older than the Settings period are erased now, then about every hour in the background.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { AppArchive.shared.startWatching() }
    }
    /// Launch (and Dock reopen) with nothing to restore: Home, never an untitled document and never AppKit's Open panel.
    /// AppKit asks this first (`-[NSApplication _doOpenUntitled]`); when a document-based app does not answer, it may put
    /// up the Open panel instead of an untitled document, which is what happened after every clean quit.
    @objc func applicationShowsOpenPanelInsteadOfUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if Self.isTesting { return true }
        if SplashScreen.shared.isShowing {
            SplashScreen.shared.afterDismiss { if NSDocumentController.shared.documents.isEmpty { HomeWindow.shared.show() } }
        } else if NSDocumentController.shared.documents.isEmpty {
            HomeWindow.shared.show()
        }
        return true
    }
    /// A click on the Dock icon always ends with a window in front of the person. AppKit's `hasVisibleWindows` cannot
    /// decide that: it is true while the notch drawer's panel is up (which is always), so with Home closed, a project
    /// minimized, or the windows on another Space, the click used to do nothing at all. The app's own windows are
    /// counted here instead (`reopenPlan`) and the chosen one is brought to this Space (`bringToThisSpace`).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if Self.isTesting { return false }
        // A hidden app (⌘H) is shown again by the click itself; its windows only count once they are back.
        MainActor.assumeIsolated {
            if sender.isHidden { sender.unhide(nil); DispatchQueue.main.async { Self.reopen(systemSaysVisible: flag) } }
            else { Self.reopen(systemSaysVisible: flag) }
        }
        return false
    }

    /// What a Dock click does, from the windows a person would call EditMax's windows.
    enum ReopenPlan: Equatable {
        /// One is on screen: it comes to the front (and to this Space).
        case front
        /// None on screen, one in the Dock: it comes back out.
        case unminimize
        /// None at all: Home.
        case home
    }
    nonisolated static func reopenPlan(visible: Int, minimized: Int) -> ReopenPlan { visible > 0 ? .front : minimized > 0 ? .unminimize : .home }

    /// A project, Home, Settings: a titled window that is not see-through. Not a panel (the
    /// notch drawer, the update and crash-report cards), the splash, a tour overlay, or the empty untitled project
    /// kept transparent during launch.
    @MainActor static func isAppWindow(_ w: NSWindow) -> Bool {
        !(w is NSPanel) && w.styleMask.contains(.titled) && w.alphaValue > 0.01 && w.parent == nil   // not canBecomeMain: false while a window is out
    }

    /// The window comes to the person, on the Space they are on. macOS does not switch Spaces for the click: the notch
    /// drawer's panel is on every Space, so to the system EditMax already has a window here. With Home on the desktop
    /// and the person in a full-screen app, the click showed nothing. A window that is itself full screen keeps its
    /// own Space and is only ordered front (the system goes to it); a project window gets its Space and full-screen
    /// behaviour back once it has moved, so it can still go full screen.
    @MainActor static func bringToThisSpace(_ w: NSWindow) {
        if w.isMiniaturized { w.deminiaturize(nil) }
        if w.isOnActiveSpace || w.styleMask.contains(.fullScreen) { BringForward.app(); w.makeKeyAndOrderFront(nil); return }
        let before = w.collectionBehavior
        BringForward.show(w)
        if w.windowController?.document != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { w.collectionBehavior = before } }
    }

    @MainActor static func reopen(systemSaysVisible: Bool, windows: [NSWindow] = NSApp.windows) {
        let own = windows.filter(isAppWindow)
        let shown = own.filter { $0.isVisible && !$0.isMiniaturized }, minimized = own.filter(\.isMiniaturized)
        let plan = reopenPlan(visible: shown.count, minimized: minimized.count)
        let here = shown.filter(\.isOnActiveSpace)   // one already on this Space before one that has to be fetched
        let chosen: NSWindow? = plan == .front ? ((here.isEmpty ? shown : here).first { $0.isMainWindow || $0.isKeyWindow } ?? here.first ?? shown[0])
            : plan == .unminimize ? (minimized.first { $0.windowController?.document != nil } ?? minimized[0]) : nil   // a project before Home
        DebugLog.event("dock-reopen", ["plan": "\(plan)", "systemSaysVisible": systemSaysVisible, "windows": windows.count, "own": own.count,
                                       "window": chosen.map { "\(type(of: $0)) \($0.title)" } ?? "Home", "onThisSpace": chosen?.isOnActiveSpace ?? false])
        if let chosen { bringToThisSpace(chosen) } else { HomeWindow.shared.show(); HomeWindow.shared.bringForward() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    /// Quitting while an export renders asks first (QuitGuard); otherwise quits as before.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { QuitGuard.shared.shouldTerminate() }
    }
    /// Set once the app is quitting, so windows closing on the way out do not bring Home back up.
    static var quitting = false
    /// False until the launch has closed the empty untitled project DocumentGroup opens by itself (0.3 s in); until then
    /// an untitled project's window is kept transparent (`LaunchUntitledHider`), so it never flashes open.
    static var launchSettled = false
    func applicationWillTerminate(_ notification: Notification) { Self.quitting = true }
}
