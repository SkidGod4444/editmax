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
    }
    func unregister(_ doc: EditMaxDocument) {
        documents.removeAll { $0.id == doc.id }
        if activeID == doc.id { activeID = documents.last?.id }
    }
    func activate(_ doc: EditMaxDocument) { activeID = doc.id }

    var active: EditMaxDocument? { documents.first { $0.id == activeID } ?? documents.last }

    func document(for text: String?) -> EditMaxDocument? {
        guard let text, !text.isEmpty else { return active }
        if let id = Project.resolve(text, in: documents.map(\.id)) { return documents.first { $0.id == id } }
        return documents.first { $0.displayName.lowercased() == text.lowercased() }
    }
}
