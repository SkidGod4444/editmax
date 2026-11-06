import Foundation
import Combine

/// Tracks open documents so the MCP server can address them by id and default to the active one.
@MainActor
final class DocumentRegistry: ObservableObject {
    static let shared = DocumentRegistry()
    @Published private(set) var documents: [EditMaxDocument] = []
    @Published private(set) var activeID: UUID?

    func register(_ doc: EditMaxDocument) {
        if !documents.contains(where: { $0.id == doc.id }) { documents.append(doc) }
        activeID = doc.id
        // Home is the launcher: it steps aside once a project is open (also when a file is opened from the Finder at
        // launch, where it used to stay up behind the editor). ⇧⌘P or the toolbar's Home button bring it back.
        if doc.fileURL != nil { HomeWindow.shared.hide() }   // not for the untitled one AppKit opens at launch (closed 0.3 s later)
    }
    func unregister(_ doc: EditMaxDocument) {
        documents.removeAll { $0.id == doc.id }
        if activeID == doc.id { activeID = documents.last?.id }
        // The last project window closed: back to Home, unless the app is on its way out.
        if documents.isEmpty, !AppDelegate.isTesting {   // tests register documents too; Home never shows for them
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                // Not while a launch is still waiting for the project it opens: that wait shows Home itself if none comes.
                if self.documents.isEmpty, !AppDelegate.quitting, !HomeWindow.shared.isVisible, !HomeWindow.shared.waitingForLaunchProject { HomeWindow.shared.show() }
            }
        }
    }
    func activate(_ doc: EditMaxDocument) { activeID = doc.id }

    var active: EditMaxDocument? { documents.first { $0.id == activeID } ?? documents.last }

    func document(for text: String?) -> EditMaxDocument? {
        guard let text, !text.isEmpty else { return active }
        if let id = Project.resolve(text, in: documents.map(\.id)) { return documents.first { $0.id == id } }
        return documents.first { $0.displayName.lowercased() == text.lowercased() }
    }
}
