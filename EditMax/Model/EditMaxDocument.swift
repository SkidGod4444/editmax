import SwiftUI
import UniformTypeIdentifiers
import Combine

extension UTType {
    static let editmaxProject = UTType(exportedAs: "io.openhorizon.editmax.project", conformingTo: .json)
}

/// Reference document: one open window = one project. Every mutation goes through `apply`,
/// which records a labeled snapshot so any user or agent edit can be restored in one call.
@MainActor
final class EditMaxDocument: ReferenceFileDocument, ObservableObject {
    typealias Snapshot = Project

    static var readableContentTypes: [UTType] { [.editmaxProject] }
    static var writableContentTypes: [UTType] { [.editmaxProject] }

    @Published var project: Project
    /// Bumped on every apply; the engine rebuilds the composition when it changes.
    @Published private(set) var revision: Int = 0
    let id = UUID()
    var fileURL: URL?
    /// Set by tools to move the playhead of this document's window; the PlayerController observes it.
    @Published var seekRequest: (time: Double, play: Bool)? = nil

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    init() { project = Project() }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        project = try Self.decoder.decode(Project.self, from: data)
    }

    func snapshot(contentType: UTType) throws -> Project { project }

    func fileWrapper(snapshot: Project, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try Self.encoder.encode(snapshot))
    }

    // MARK: Mutations with history

    static let maxHistory = 200
    static let maxUndo = 100

    /// ⌘Z / ⇧⌘Z stacks: the state before each edit, and the states undone. Undo and redo are themselves recorded in
    /// History, so the History tab stays a complete log.
    @Published private(set) var undoStack: [(label: String, project: Project)] = []
    @Published private(set) var redoStack: [(label: String, project: Project)] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoLabel: String? { undoStack.last?.label }
    var redoLabel: String? { redoStack.last?.label }

    private var lastApply: (label: String, at: Date)?

    /// Apply a change. A snapshot of the pre-change state is stored with `label` so it can be restored.
    /// `coalesce` folds a run of same-labeled edits within 1.5 s (a slider drag) into one undo step and one History entry.
    func apply(_ label: String, origin: EditOrigin, coalesce: Bool = false, _ body: (inout Project) throws -> Void) rethrows {
        let before = project.withoutHistory
        let merge = coalesce && lastApply?.label == label && undoStack.last?.label == label && Date().timeIntervalSince(lastApply!.at) < 1.5
        try commit(label, origin: origin, record: !merge, body)
        if !merge {
            undoStack.append((label, before))
            if undoStack.count > Self.maxUndo { undoStack.removeFirst(undoStack.count - Self.maxUndo) }
        }
        redoStack.removeAll()
        lastApply = (label, Date())
    }

    private func commit(_ label: String, origin: EditOrigin, record: Bool = true, _ body: (inout Project) throws -> Void) rethrows {
        let before = project.withoutHistory
        var next = project
        try body(&next)
        if record, let data = try? Self.encoder.encode(before) {
            next.history.append(HistoryEntry(label: label, origin: origin, project: data))
            if next.history.count > Self.maxHistory { next.history.removeFirst(next.history.count - Self.maxHistory) }
        }
        project = next
        revision += 1
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        let current = project.withoutHistory
        commit("Undo \(last.label)", origin: .user) { p in
            let history = p.history, transcripts = p.transcripts
            p = last.project; p.history = history; p.transcripts = transcripts ?? p.transcripts
        }
        redoStack.append((last.label, current))
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        let current = project.withoutHistory
        commit("Redo \(next.label)", origin: .user) { p in
            let history = p.history, transcripts = p.transcripts
            p = next.project; p.history = history; p.transcripts = transcripts ?? p.transcripts
        }
        undoStack.append((next.label, current))
    }

    /// Restore the project to the state captured by a snapshot. The current state is itself snapshotted first.
    func restore(snapshotID: UUID, origin: EditOrigin) throws {
        guard let snap = project.history.first(where: { $0.id == snapshotID }) else { throw EditError.notFound("snapshot \(snapshotID)") }
        let restored = try Self.decoder.decode(Project.self, from: snap.project)
        try apply("Restore: \(snap.label)", origin: origin) { p in
            let history = p.history, transcripts = p.transcripts
            p = restored
            p.history = history
            p.transcripts = transcripts   // a cache of the media, not part of the edit
        }
    }

    var displayName: String { fileURL?.deletingPathExtension().lastPathComponent ?? project.name }
}
