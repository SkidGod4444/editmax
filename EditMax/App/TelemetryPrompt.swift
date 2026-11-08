import AppKit
import SwiftUI

/// The first-launch card: crash reports and anonymous feature counts are part of using EditMax, and this says so once,
/// with Agree. Nothing is sent before Agree (`Telemetry`); until then the card comes back at each launch, after the
/// splash and after the "is installed" card. It holds the whole app until Agree: an app-modal session, as an alert's,
/// so clicks on every other window beep and the menus are off. It never takes the keyboard, and it waits while EditMax
/// is in the background (a modal card nobody can see would hold the app for nothing).
@MainActor
final class TelemetryPrompt {
    static let shared = TelemetryPrompt()

    /// The README's section on what is sent.
    static let detailsURL = URL(string: "https://github.com/SkidGod4444/editmax#privacy")!

    var offscreen = false
    var window: NSPanel? { panel }
    var isShowing: Bool { panel?.isVisible == true }
    private var panel: UpdatePromptPanel?
    private var waitingForFront: NSObjectProtocol?

    func askIfNeeded() {
        guard Telemetry.isAvailable(), !Telemetry.shared.agreed, !isShowing else { return }
        // One card at a time: the update card first.
        if UpdatePrompt.shared.isShowing {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.askIfNeeded() }
            return
        }
        guard NSApp.isActive else { waitForFront(); return }
        DispatchQueue.main.async { [weak self] in self?.show() }   // after the caller (the splash closing) has finished
    }

    /// Shows the card and returns only once Agree is pressed.
    func show() {
        guard !isShowing else { return }
        let host = NSHostingView(rootView: TelemetryPromptView(agree: { [weak self] in self?.agree() }))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let panel = self.panel ?? UpdatePromptPanel()
        panel.contentView = host
        panel.setFrame(frame(for: host.frame.size), display: true)
        self.panel = panel
        panel.orderFront(nil)   // never key (a borderless panel cannot be): nothing typed lands on Agree
        DebugLog.event("telemetry-card-shown", [:])
        NSApp.runModal(for: panel)
    }

    func agree() {
        if let panel, NSApp.modalWindow === panel {
            NSApp.stopModal()
            // stopModal ends the session at its next event; an Agree from outside one (the in-process ui tap) brings it.
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(wake, atStart: false)
            }
        }
        panel?.orderOut(nil)
        Telemetry.shared.agree()
    }

    private func waitForFront() {
        guard waitingForFront == nil else { return }
        waitingForFront = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let o = self.waitingForFront { NotificationCenter.default.removeObserver(o) }
                self.waitingForFront = nil
                self.askIfNeeded()
            }
        }
    }

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
}

/// The card, in the update card's Liquid Glass.
struct TelemetryPromptView: View {
    let agree: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Crash reports and usage").font(.title3.weight(.semibold))
                    Text("EditMax sends a report when it crashes, and anonymous counts of the features you use, so problems get found and fixed. It never sends your footage, your words, file names or anything you type.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Button("What is sent") { NSWorkspace.shared.open(TelemetryPrompt.detailsURL) }
                    .buttonStyle(.link).font(.callout)
                    .pointer().help(TelemetryPrompt.detailsURL.absoluteString).uiFrame("telemetry.details")
                Spacer(minLength: 12)
                GlassGroup(spacing: 10) {
                    // No Return shortcut: Agree is only ever a click on it.
                    Button("Agree", action: agree)
                        .glassButtonStyle(prominent: true).controlSize(.large)
                        .pointer().uiFrame("telemetry.agree").uiTap("telemetry.agree", agree)
                }
            }
        }
        .padding(22)
        .frame(width: 480)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .environment(\.controlActiveState, .key)   // the panel is never key; Agree still draws blue, not grey
        .padding(24)   // room for the window shadow
    }
}
