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
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No NSApp.activate here: a normal launch is activated by Launch Services, and a background launch (`open -g`)
        // must stay in the background.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if NSDocumentController.shared.documents.isEmpty { NSDocumentController.shared.newDocument(nil) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
