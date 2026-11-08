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
        AppSettings.shared.applyAppearance()
        SplashScreen.renderIfRequested()
        if ProcessInfo.processInfo.arguments.contains("-splash-preview") { SplashScreen.shared.show(); SplashScreen.shared.dismissWhenReady() }
        // No NSApp.activate here: a normal launch is activated by Launch Services, and a background launch (`open -g`)
        // must stay in the background.
        // Home (the project library) is the launch screen. On a plain launch it is put up right away so the document
        // machinery never sees an app without windows (that is what makes it present an Open panel). A launch that opens
        // or restores a project waits for that project instead, and shows Home only if none arrives (no flash of Home).
        let isDefault = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        let plan = HomeWindow.launchPlan(isDefaultLaunch: isDefault, projectOpen: !NSDocumentController.shared.documents.isEmpty,
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
            for d in docs where d.fileURL == nil && !d.isDocumentEdited { d.close() }
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
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { HomeWindow.shared.show() }
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    /// Quitting while an export renders asks first (QuitGuard); otherwise quits as before.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { QuitGuard.shared.shouldTerminate() }
    }
    /// Set once the app is quitting, so windows closing on the way out do not bring Home back up.
    static var quitting = false
    func applicationWillTerminate(_ notification: Notification) { Self.quitting = true }
}
