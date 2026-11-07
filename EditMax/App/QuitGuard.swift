import AppKit
import SwiftUI

/// ⌘Q (or any quit) while an export renders asks first, instead of killing the export:
/// - **Quit When Done** (Return): EditMax stays open and quits by itself once the last export ends. The export pill
///   says so and offers Don't Quit.
/// - **Keep Working** (Esc): nothing happens.
/// - **Quit Now**: quits, and the export stops unfinished.
/// No export running: quits at once, as before. Exports from the agent count too (`BusyWork`).
@MainActor
final class QuitGuard: ObservableObject {
    static let shared = QuitGuard()

    enum Choice { case quitWhenDone, keepWorking, quitNow }

    /// True after Quit When Done, until EditMax quits or the user takes it back.
    @Published private(set) var quitWhenDone = false

    /// Seams for the tests.
    var exporting: () -> Bool = { BusyWork.isRunning(BusyWork.export) }
    var ask: () -> Choice = { QuitGuard.alert().choice }
    var terminate: () -> Void = { NSApp.terminate(nil) }
    var pollEvery: TimeInterval = 0.5

    private var poll: Timer?

    init() {}

    /// The app delegate's `applicationShouldTerminate`.
    func shouldTerminate() -> NSApplication.TerminateReply {
        guard exporting() else { return .terminateNow }
        let choice = ask()
        DebugLog.event("quit-during-export", ["choice": "\(choice)"])
        switch choice {
        case .quitNow: stopWaiting(); return .terminateNow
        case .keepWorking: stopWaiting(); return .terminateCancel
        case .quitWhenDone: waitForExports(); return .terminateCancel
        }
    }

    /// Don't Quit on the export pill.
    func dontQuit() {
        DebugLog.event("quit-when-done-cancelled")
        stopWaiting()
    }

    private func waitForExports() {
        quitWhenDone = true
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: pollEvery, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.quitWhenDone, !self.exporting() else { return }
                self.stopWaiting()
                DebugLog.event("quit-when-done")
                self.terminate()
            }
        }
    }

    private func stopWaiting() {
        poll?.invalidate(); poll = nil
        quitWhenDone = false
    }

    /// The question, built apart from running it so the tests can draw it.
    static func alert() -> (alert: NSAlert, choice: Choice) {
        let a = makeAlert()
        switch a.runModal() {
        case .alertFirstButtonReturn: return (a, .quitWhenDone)
        case .alertSecondButtonReturn: return (a, .keepWorking)
        default: return (a, .quitNow)
        }
    }

    static func makeAlert() -> NSAlert {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "An export is still running"
        a.informativeText = "EditMax can quit by itself as soon as it's done. Quit Now stops the export, and the file won't be finished."
        a.addButton(withTitle: "Quit When Done")                              // Return
        a.addButton(withTitle: "Keep Working").keyEquivalent = "\u{1b}"     // Esc
        a.addButton(withTitle: "Quit Now")
        return a
    }
}

/// The export progress pill at the top of the editor; after Quit When Done it says EditMax will quit and offers to
/// take that back.
struct ExportStatusPill: View {
    let status: String
    @ObservedObject private var quit = QuitGuard.shared

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(status).font(.caption.monospacedDigit()).lineLimit(1)
            if quit.quitWhenDone {
                Text("EditMax quits when it's done").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button("Don't Quit") { quit.dontQuit() }
                    .buttonStyle(.link).font(.caption)
                    .pointer().uiFrame("export.dontQuit").uiTap("export.dontQuit") { quit.dontQuit() }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .liquidGlass()
    }
}
