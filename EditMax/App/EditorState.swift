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
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let launchedAt = Date()
    /// The splash floats above every window, so it only shows for a launch the user made: Launch Services activates the
    /// app right after launch; a background launch (`open -g`, the agent's test relaunches) never does, and gets none.
    func applicationDidBecomeActive(_ notification: Notification) {
        if Date().timeIntervalSince(launchedAt) < 2, AppSettings.bool(AppSettings.Key.showSplash, default: true) { SplashScreen.shared.show(); SplashScreen.shared.dismissWhenReady() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        InteractionLog.install()
        AppSettings.shared.applyAppearance()
        SplashScreen.renderIfRequested()
        if ProcessInfo.processInfo.arguments.contains("-splash-preview") { SplashScreen.shared.show(); SplashScreen.shared.dismissWhenReady() }
        // No NSApp.activate here: a normal launch is activated by Launch Services, and a background launch (`open -g`)
        // must stay in the background.
        // Home (the project library) is the launch screen. It is put up right away so the document machinery never sees
        // an app without windows (that is what makes it present an Open panel); opening a file at launch skips it.
        if NSDocumentController.shared.documents.isEmpty && !ProcessInfo.processInfo.arguments.contains(where: { $0.hasSuffix(".emx") || $0.hasSuffix(".editmax") }) {
            SplashScreen.shared.afterDismiss { if NSDocumentController.shared.documents.isEmpty { HomeWindow.shared.show() } }
            if !SplashScreen.shared.isShowing { HomeWindow.shared.show() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // DocumentGroup opens an empty untitled document on its own (the delegate is not asked); close it and show
            // Home instead. An untitled document with edits (restored from a crash) stays.
            let docs = NSDocumentController.shared.documents
            DebugLog.event("launch-docs", ["count": docs.count, "untitled": docs.filter { $0.fileURL == nil }.count, "edited": docs.filter(\.isDocumentEdited).count])
            for d in docs where d.fileURL == nil && !d.isDocumentEdited { d.close() }
            // With a splash up, Home waits until it has faded: the splash plays, then the app opens.
            SplashScreen.shared.afterDismiss { if NSDocumentController.shared.documents.isEmpty { HomeWindow.shared.show() } }
        }
    }
    /// Launch (and Dock reopen) with nothing to restore: Home, never an untitled document and never AppKit's Open panel.
    /// AppKit asks this first (`-[NSApplication _doOpenUntitled]`); when a document-based app does not answer, it may put
    /// up the Open panel instead of an untitled document, which is what happened after every clean quit.
    @objc func applicationShowsOpenPanelInsteadOfUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
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
}
