import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let editmaxExportChapters = Notification.Name("io.openhorizon.editmax.exportChapters")
    static let editmaxBatchExport = Notification.Name("io.openhorizon.editmax.batchExport")
    static let editmaxExportTimeline = Notification.Name("io.openhorizon.editmax.exportTimeline")
}

/// Before an export: a track whose sound would be left out (muted, silent because another track is soloed, in a muted
/// bus) is easy to miss in the timeline, so say so and offer to turn it back on. True to go on with the export.
@MainActor
enum SoundCheck {
    /// Projects (by library ID) whose silent tracks the user chose not to be asked about again, with the list they saw.
    static let quietKey = "soundCheck.quiet"

    /// The silent tracks as one string: the same tracks for the same reasons give the same signature.
    static func signature(_ list: [Mixer.Silenced]) -> String {
        list.map { "\($0.track)|\($0.reason.rawValue)|\($0.bus ?? "")" }.sorted().joined(separator: "\n")
    }
    /// True when the user ticked "Don't ask again" for exactly these silent tracks in this project. A track muted or
    /// unmuted since then changes the list, so the question comes back.
    static func isQuiet(_ list: [Mixer.Silenced], project: UUID?, defaults: UserDefaults = .standard) -> Bool {
        guard let project else { return false }
        return (defaults.dictionary(forKey: quietKey)?[project.uuidString] as? String) == signature(list)
    }
    static func remember(_ list: [Mixer.Silenced], project: UUID, defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: quietKey) ?? [:]
        all[project.uuidString] = signature(list)
        defaults.set(all, forKey: quietKey)
    }

    static func confirm(_ document: EditMaxDocument) async -> Bool {
        let list = await Mixer.silencedTracks(in: document.project)
        let project = document.libraryProjectID
        guard !list.isEmpty, !isQuiet(list, project: project) else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = list.count == 1 ? list[0].text : "\(list.count) tracks are silent"
        alert.informativeText = (list.count == 1 ? "Its sound" : list.map { "• " + $0.text }.joined(separator: "\n") + "\n\nTheir sound") + " will be left out of the exported file."
        // Return exports as the project is: a mute is often on purpose (camera sound under a music bed), so the default
        // never changes the project. Turning the sound on is a click away; Escape cancels.
        alert.addButton(withTitle: "Export Anyway")
        alert.addButton(withTitle: "Turn Sound On")
        alert.addButton(withTitle: "Cancel")
        if project != nil {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = list.count == 1 ? "Don't ask again about this track in this project" : "Don't ask again about these tracks in this project"
        }
        let choice = alert.runModal()
        switch choice {
        case .alertFirstButtonReturn:
            if let project, alert.suppressionButton?.state == .on { remember(list, project: project) }
            return true
        case .alertSecondButtonReturn:
            document.apply("Turn sound on for export", origin: .user) { p in Mixer.turnSoundOn(list, in: &p) }
            return true
        default:
            return false
        }
    }
}

/// File > Export Chapters…, Batch Export… and Export Timeline… for one window: the panels, then the work through `ToolExecutor`.
/// Progress and results show in the same export status banner as Export Video.
@MainActor
struct DeliveryActions {
    let document: EditMaxDocument
    let state: EditorState

    /// Save panel for `<project>.chapters.txt`; a brief alert instead when the project has no markers.
    func exportChapters() {
        let project = document.project
        guard !project.markers.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No markers to export"
            alert.informativeText = "Chapters come from the timeline's markers. Press M at each chapter start (or ask the agent to add markers), then export again."
            alert.runModal()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = document.displayName + ".chapters.txt"
        panel.title = "Export Chapters"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let written = try Chapters.write(project, nextTo: url)
            let n = Chapters.entries(project).count
            flash("Saved \(n) chapter\(n == 1 ? "" : "s") to \(written.lastPathComponent)")
        } catch {
            flash("Chapters failed: \(error.localizedDescription)")
        }
    }

    /// Directory chooser (with the format picker), then every built-in template through `ToolExecutor.exportBatch`.
    func batchExport() {
        guard !state.isExporting else { return }
        guard document.project.duration > 0 else {
            let alert = NSAlert()
            alert.messageText = "Nothing to export"
            alert.informativeText = "The timeline is empty."
            alert.runModal()
            return
        }
        Task { if await SoundCheck.confirm(document) { chooseBatchFolder() } }
    }

    private func chooseBatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Batch Export"
        panel.message = "Choose a folder: every built-in template is rendered into it, named \(document.displayName)-<template>.mp4 (.mov for ProRes)."
        panel.prompt = "Export Here"
        let format = ExportFormatBox()
        panel.accessoryView = PanelAccessory.popUp(label: "Format:", items: ExportFormatBox.items, selected: format.preset) { format.preset = $0 }
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let hasMarkers = !document.project.markers.isEmpty
        state.isExporting = true
        state.exportStatus = "Batch export…"
        let preset = format.preset
        Task { await runBatch(into: dir, preset: preset, chapters: hasMarkers, ignoreDiskEstimate: false) }
    }

    /// When a file's size estimate does not fit the disk, asks before going past it, as File → Export does.
    private func runBatch(into dir: URL, preset: ExportService.Preset, chapters: Bool, ignoreDiskEstimate: Bool) async {
        do {
            let items = try await ToolExecutor(document: document, origin: .user).exportBatch(directory: dir.path, templates: [], preset: preset, chapters: chapters,
                                                                                               ignoreDiskEstimate: ignoreDiskEstimate) { label, p in
                Task { @MainActor in state.exportStatus = "Batch export \(label)… \(Int(p * 100))%" }
            }
            let total = items.reduce(0) { $0 + $1.seconds }
            state.exportStatus = "Exported \(items.count) file\(items.count == 1 ? "" : "s") to \(dir.lastPathComponent) in \(Int(total.rounded())) s"
            NSWorkspace.shared.activateFileViewerSelecting(items.map { URL(fileURLWithPath: $0.path) })
        } catch let e as ExportService.DiskTooSmall {
            let alert = NSAlert()
            alert.messageText = "This batch may not fit on the disk"
            alert.informativeText = e.localizedDescription + " Export Anyway renders every file of the batch again."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Export Anyway")
            if alert.runModal() == .alertSecondButtonReturn {
                state.exportStatus = "Batch export…"
                return await runBatch(into: dir, preset: preset, chapters: chapters, ignoreDiskEstimate: true)
            }
            state.exportStatus = "Batch export cancelled: the disk may be too small."
        } catch {
            state.exportStatus = "Batch export failed: \(error.localizedDescription)"
        }
        state.isExporting = false
        try? await Task.sleep(for: .seconds(6))
        state.exportStatus = nil
    }

    /// Save panel with the format picker (FCPXML or EDL), then a sheet that says exactly what went into the file and
    /// what stays in EditMax, so nobody opens it in Resolve expecting the grade.
    func exportTimeline() {
        guard document.project.duration > 0 else {
            let alert = NSAlert()
            alert.messageText = "Nothing to export"
            alert.informativeText = "The timeline is empty."
            alert.runModal()
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Timeline"
        panel.message = "An edit list for DaVinci Resolve or Final Cut Pro that points at your original media. Nothing is rendered."
        let fcpxml = UTType(filenameExtension: "fcpxml") ?? .xml, edl = UTType(filenameExtension: "edl") ?? .plainText
        panel.allowedContentTypes = [fcpxml]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = document.displayName + ".fcpxml"
        let box = TimelineFormatBox()
        box.onChange = { f in
            panel.allowedContentTypes = [f == .edl ? edl : fcpxml]
            let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = (name.isEmpty ? document.displayName : name) + "." + f.fileExtension
        }
        panel.accessoryView = PanelAccessory.popUp(label: "Format:", items: Interchange.Format.allCases.map { .init(title: $0.title, value: $0) },
                                                   selected: box.format) { box.format = $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.isExporting = true
        state.exportStatus = "Exporting timeline…"
        Task {
            do {
                let r = try await ToolExecutor(document: document, origin: .user).exportTimeline(to: url.path, format: box.format)
                state.isExporting = false
                flash("Exported \(r.clips) \(box.format == .edl ? "event" : "clip")\(r.clips == 1 ? "" : "s") to \(URL(fileURLWithPath: r.path).lastPathComponent)")
                let alert = NSAlert()
                alert.messageText = "Timeline exported to \(URL(fileURLWithPath: r.path).lastPathComponent)"
                var text = "Carried over:\n" + r.transferred.map { "• " + $0 }.joined(separator: "\n")
                if !r.notTransferred.isEmpty {
                    text += "\n\nStays in EditMax:\n" + r.notTransferred.map { "• " + $0 }.joined(separator: "\n")
                    text += "\n\nTo keep the grade and sound as they are, also export a ProRes master (File > Export Video…)."
                }
                alert.informativeText = text
                alert.addButton(withTitle: "Show in Finder")
                alert.addButton(withTitle: "Done")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting(([r.path] + r.sidecars).map { URL(fileURLWithPath: $0) })
                }
            } catch {
                state.isExporting = false
                flash("Timeline export failed: \(error.localizedDescription)")
            }
        }
    }

    private func flash(_ text: String) {
        state.exportStatus = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            if state.exportStatus == text { state.exportStatus = nil }
        }
    }
}

/// The timeline format chosen in the Save panel (`PanelAccessory`); the panel's name field follows it.
final class TimelineFormatBox {
    var format: Interchange.Format = .fcpxml { didSet { onChange?(format) } }
    var onChange: ((Interchange.Format) -> Void)?
}
