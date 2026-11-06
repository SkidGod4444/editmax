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
        project.migrateToCurrentFormat()
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
        if record {
            // Labels may quote the user's content (a title, a phrase); the log keeps the action, not the words.
            let safe = label.replacingOccurrences(of: "\"[^\"]*\"", with: "\"…\"", options: .regularExpression)
                .replacingOccurrences(of: "'[^']*'", with: "'…'", options: .regularExpression)
            DebugLog.event("edit", ["label": safe, "origin": origin.rawValue, "project": displayName])
        }
        if record, let data = try? Self.encoder.encode(before) {
            next.history.append(HistoryEntry(label: label, origin: origin, project: data))
            if next.history.count > Self.maxHistory { next.history.removeFirst(next.history.count - Self.maxHistory) }
        }
        project = next
        revision += 1
        scheduleAutosave()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        let current = project.withoutHistory
        commit("Undo \(last.label)", origin: .user) { p in
            let history = p.history, transcripts = p.transcripts, motionPaths = p.motionPaths, faceTracks = p.faceTracks
            p = last.project; p.history = history; p.transcripts = transcripts ?? p.transcripts; p.motionPaths = motionPaths ?? p.motionPaths; p.faceTracks = faceTracks ?? p.faceTracks
        }
        redoStack.append((last.label, current))
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        let current = project.withoutHistory
        commit("Redo \(next.label)", origin: .user) { p in
            let history = p.history, transcripts = p.transcripts, motionPaths = p.motionPaths, faceTracks = p.faceTracks
            p = next.project; p.history = history; p.transcripts = transcripts ?? p.transcripts; p.motionPaths = motionPaths ?? p.motionPaths; p.faceTracks = faceTracks ?? p.faceTracks
        }
        undoStack.append((next.label, current))
    }

    /// Restore the project to the state captured by a snapshot. The current state is itself snapshotted first.
    func restore(snapshotID: UUID, origin: EditOrigin) throws {
        guard let snap = project.history.first(where: { $0.id == snapshotID }) else { throw EditError.notFound("snapshot \(snapshotID)") }
        let restored = try Self.decoder.decode(Project.self, from: snap.project)
        try apply("Restore: \(snap.label)", origin: origin) { p in
            let history = p.history, transcripts = p.transcripts, motionPaths = p.motionPaths, faceTracks = p.faceTracks
            p = restored
            p.history = history
            p.transcripts = transcripts   // a cache of the media, not part of the edit
            p.motionPaths = motionPaths
            p.faceTracks = faceTracks
        }
    }

    // MARK: Autosave
    // Edits go through this document's own undo stack, not the NSDocument's UndoManager, so AppKit never sees the
    // document as changed and never autosaves it. A file-backed project is written 2 s after the last edit instead.
    private var saveTimer: Timer?
    private func scheduleAutosave() {
        guard fileURL != nil else { return }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in Task { @MainActor in self?.autosaveNow() } }
    }
    /// Writes the project straight to its file (same encoder as a normal save) and tells the NSDocument the disk now
    /// matches, so no close/quit prompt follows. It deliberately bypasses NSDocument.save: that path renames the file to
    /// the type's "preferred" extension as LaunchServices sees it, which a stale registration can make `.editmax`.
    func autosaveNow() {
        guard let url = fileURL else { return }
        do {
            try Self.encoder.encode(project).write(to: url, options: .atomic)
            if let nsdoc = NSDocumentController.shared.documents.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
                nsdoc.fileModificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                nsdoc.updateChangeCount(.changeCleared)
            }
            DebugLog.event("autosave", ["project": displayName])
        } catch {
            DebugLog.error("autosave", error, ["project": displayName])
        }
    }

    var displayName: String { fileURL?.deletingPathExtension().lastPathComponent ?? project.name }

    // MARK: Versions

    /// History entries hold the state *before* each edit. A version is the state *after* an edit (what the user thinks of as
    /// "how it looked once I did that"), so version k = the snapshot stored by edit k+1, and the newest version is the live project.
    /// `nil` index = the original state before the first edit.
    func version(afterEditAt index: Int?) throws -> ProjectVersion {
        let h = project.history
        guard let index else {
            guard let first = h.first else { return ProjectVersion(id: "current", label: "Current", date: Date(), project: project, isCurrent: true) }
            return ProjectVersion(id: "original", label: "Original", date: first.createdAt, project: try Self.decoder.decode(Project.self, from: first.project), isCurrent: false)
        }
        guard h.indices.contains(index) else { throw EditError.notFound("version \(index)") }
        if index == h.count - 1 { return ProjectVersion(id: "current", label: h[index].label, date: h[index].createdAt, project: project, isCurrent: true) }
        return ProjectVersion(id: h[index + 1].id.short, label: h[index].label, date: h[index].createdAt, project: try Self.decoder.decode(Project.self, from: h[index + 1].project), isCurrent: false)
    }

    /// Makes a version the live project again; the current state is snapshotted first, so this is itself undoable.
    func restore(version v: ProjectVersion, origin: EditOrigin) throws {
        guard !v.isCurrent else { return }
        try apply("Restore: \(v.label)", origin: origin) { p in
            let history = p.history, transcripts = p.transcripts, motionPaths = p.motionPaths, faceTracks = p.faceTracks
            p = v.project
            p.history = history
            p.transcripts = transcripts
            p.motionPaths = motionPaths
            p.faceTracks = faceTracks
        }
    }
}

/// A point in the project's history, decoded for viewing or restoring.
struct ProjectVersion: Identifiable, Equatable {
    let id: String
    let label: String
    let date: Date
    let project: Project
    let isCurrent: Bool
    static func == (a: ProjectVersion, b: ProjectVersion) -> Bool { a.id == b.id }
}
