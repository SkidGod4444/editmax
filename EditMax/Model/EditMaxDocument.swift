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
        let wrapper = FileWrapper(regularFileWithContents: try Self.encoder.encode(snapshot))
        Task { @MainActor [weak self] in self?.noteLibraryUse() }   // a save (⌘S): the Assets library's "Used in" follows
        return wrapper
    }

    // MARK: Assets library

    /// This project's key in the Assets library's "Used in": from its file, so it is the same on every open. Nil for a
    /// project that has no file yet (nothing to point back to).
    var libraryProjectID: UUID? { fileURL.map(AssetLibrary.projectID(for:)) }
    /// The welcome demo's scratch project: its clips are EditMax's own and stay out of the Assets library.
    var isDemo: Bool { fileURL.map { $0.standardizedFileURL.path.hasPrefix(WelcomeTour.demoRoot.standardizedFileURL.path) } ?? false }

    /// Tells the Assets library what this project uses (on open, on save, after an import). With `assets`, only those
    /// are recorded (an import); without, the whole asset list is synced, which also drops assets the project no
    /// longer has. A project without a file only registers what it imports. Nested-sequence renders are not library items.
    func noteLibraryUse(_ assets: [Asset]? = nil) {
        guard !isDemo else { return }
        guard let pid = libraryProjectID else { if let assets { AssetLibrary.shared.register(assets) }; return }
        if let assets { AssetLibrary.shared.noteUsed(assets, projectID: pid, projectName: displayName, explicit: true) }   // an import
        else { AssetLibrary.shared.syncUse(project.assets, projectID: pid, projectName: displayName) }
    }

    // MARK: Mutations with history

    static let maxHistory = 200
    static let maxUndo = 100
    /// Set by `AgentFollowDriver` around an agent call the window is following.
    @MainActor static var animateAgentEdits = false

    /// ⌘Z / ⇧⌘Z stacks: the state before each edit, and the states undone. Undo and redo are themselves recorded in
    /// History, so the History tab stays a complete log.
    @Published private(set) var undoStack: [(label: String, project: Project)] = []
    @Published private(set) var redoStack: [(label: String, project: Project)] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoLabel: String? { undoStack.last?.label }
    var redoLabel: String? { redoStack.last?.label }

    /// The coalescing run the newest undo step belongs to (a slider drag in progress), nil when the next edit starts a new step.
    struct CoalesceRun {
        var key: String
        var origin: EditOrigin
        var at: Date
        /// Everything the run has changed so far (`ProjectDiff.changedPaths`).
        var paths: Set<String>
        /// The mouse press (down, drags, up) the run's newest edit came in on, if any (`NSEvent.eventNumber`).
        var press: Int? = nil
    }
    private var run: CoalesceRun?
    static let coalesceWindow: TimeInterval = 1.5

    /// Apply a change. A snapshot of the pre-change state is stored with `label` so it can be restored.
    /// An edit that leaves the project exactly as it was records nothing: no History entry, no undo step, and redo survives
    /// (a text field writing back the name it shows, closing gaps where there are none, the same transition twice).
    /// `coalesce` folds a run of edits to the same control within 1.5 s (a slider drag) into one undo step and one History
    /// entry; `key` names the kind of edit for that when the label carries a value ("Opacity 80%"), and the step takes the
    /// newest label.
    func apply(_ label: String, origin: EditOrigin, coalesce: Bool = false, key: String? = nil, _ body: (inout Project) throws -> Void) rethrows {
        var next = project
        try body(&next)
        guard next != project else { return }
        let before = project.withoutHistory
        let key = key ?? label
        var merge = false, paths: Set<String> = []
        let press = coalesce ? Self.currentPress : nil
        if coalesce {
            let after = next.withoutHistory
            paths = ProjectDiff.changedPaths(from: before, to: after)
            if let top = undoStack.last {
                merge = Self.continues(run, key: key, origin: origin, paths: paths, now: Date(), backToStart: after == top.project,
                                       clickRelease: press?.release == true && press?.number != run?.press)
            }
        }
        if merge {
            // One step for the whole drag, named after where it ended.
            undoStack[undoStack.count - 1].label = label
            if let i = next.history.indices.last { next.history[i].label = label }
            run!.at = Date(); run!.paths.formUnion(paths); run!.press = press?.number
        }
        commit(label, origin: origin, record: !merge, next: next, before: before)
        if !merge {
            undoStack.append((label, before))
            if undoStack.count > Self.maxUndo { undoStack.removeFirst(undoStack.count - Self.maxUndo) }
            run = coalesce ? CoalesceRun(key: key, origin: origin, at: Date(), paths: paths, press: press?.number) : nil
        }
        redoStack.removeAll()
    }

    /// Whether a coalescing edit continues the run before it (one undo step) or starts its own. It continues only when it
    /// is the same kind of edit from the same origin within the window, changes the same control (its changed paths sit
    /// inside the run's, or the run's inside its own: a dot dragged first sideways and then diagonally), does not bring the
    /// project back to where the run began (a double-click reset after a drag is a step of its own, so ⌘Z brings the
    /// dragged value back), and is not the release of a click of its own (a button or a double-click, `currentPress`).
    static func continues(_ run: CoalesceRun?, key: String, origin: EditOrigin, paths: Set<String>, now: Date, backToStart: Bool, clickRelease: Bool) -> Bool {
        guard let run, run.key == key, run.origin == origin, now.timeIntervalSince(run.at) < coalesceWindow,
              !backToStart, !clickRelease, !paths.isEmpty, !run.paths.isEmpty else { return false }
        func related(_ a: String, _ b: String) -> Bool { a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") }
        let inside = paths.allSatisfy { p in run.paths.contains { related(p, $0) } }
        let around = run.paths.allSatisfy { p in paths.contains { related(p, $0) } }
        return inside || around
    }

    /// The mouse press AppKit is handling, and whether this is its release. A release starts a step of its own (a button
    /// press, a double-click on a value) unless it ends the press the run came in on: a slider sends its last value on the
    /// mouse-up of its own drag. A stale event (an agent's call long after the last click) says nothing about the edit, so
    /// only a fresh one counts. Only mouse events are read, because `eventNumber` is not defined for the others.
    private static var currentPress: (number: Int, release: Bool)? {
        guard let app = NSApp, let e = app.currentEvent, ProcessInfo.processInfo.systemUptime - e.timestamp < 0.5 else { return nil }
        switch e.type {
        case .leftMouseDown, .leftMouseDragged, .rightMouseDown, .rightMouseDragged, .otherMouseDown, .otherMouseDragged: return (e.eventNumber, false)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: return (e.eventNumber, true)
        default: return nil
        }
    }

    private func commit(_ label: String, origin: EditOrigin, record: Bool = true, _ body: (inout Project) throws -> Void) rethrows {
        var next = project
        try body(&next)
        commit(label, origin: origin, record: record, next: next, before: project.withoutHistory)
    }

    private func commit(_ label: String, origin: EditOrigin, record: Bool, next: Project, before: Project) {
        var next = next
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
        // Follow the agent: an agent's edit animates into place (wheel dots, faders, clips sliding) when the window is
        // following it. Never the user's own edits: a slider drag must track the pointer.
        if origin == .agent && Self.animateAgentEdits {
            withAnimation(.easeInOut(duration: 0.35)) { project = next }
        } else {
            project = next
        }
        revision += 1
        scheduleAutosave()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        run = nil   // a drag after ⌘Z is a new step, never part of the one just undone
        let current = project.withoutHistory
        commit("Undo \(last.label)", origin: .user) { p in
            let history = p.history, transcripts = p.transcripts, motionPaths = p.motionPaths, faceTracks = p.faceTracks
            p = last.project; p.history = history; p.transcripts = transcripts ?? p.transcripts; p.motionPaths = motionPaths ?? p.motionPaths; p.faceTracks = faceTracks ?? p.faceTracks
        }
        redoStack.append((last.label, current))
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        run = nil
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
            noteLibraryUse()
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
