import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let editmaxExportChapters = Notification.Name("io.openhorizon.editmax.exportChapters")
    static let editmaxBatchExport = Notification.Name("io.openhorizon.editmax.batchExport")
    static let editmaxExportTimeline = Notification.Name("io.openhorizon.editmax.exportTimeline")
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
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Batch Export"
        panel.message = "Choose a folder: every built-in template is rendered into it, named \(document.displayName)-<template>.mp4 (.mov for ProRes)."
        panel.prompt = "Export Here"
        let format = ExportFormatBox()
        let host = NSHostingView(rootView: ExportFormatPicker(box: format))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 48)
        panel.accessoryView = host
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let hasMarkers = !document.project.markers.isEmpty
        state.isExporting = true
        state.exportStatus = "Batch export…"
        Task {
            do {
                let items = try await ToolExecutor(document: document, origin: .user).exportBatch(directory: dir.path, templates: [], preset: format.preset, chapters: hasMarkers) { label, p in
                    Task { @MainActor in state.exportStatus = "Batch export \(label)… \(Int(p * 100))%" }
                }
                let total = items.reduce(0) { $0 + $1.seconds }
                state.exportStatus = "Exported \(items.count) file\(items.count == 1 ? "" : "s") to \(dir.lastPathComponent) in \(Int(total.rounded())) s"
                NSWorkspace.shared.activateFileViewerSelecting(items.map { URL(fileURLWithPath: $0.path) })
            } catch {
                state.exportStatus = "Batch export failed: \(error.localizedDescription)"
            }
            state.isExporting = false
            try? await Task.sleep(for: .seconds(6))
            state.exportStatus = nil
        }
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
        let host = NSHostingView(rootView: TimelineFormatPicker(box: box))
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 48)
        panel.accessoryView = host
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

/// The format choice in the Export Timeline panel.
final class TimelineFormatBox: ObservableObject {
    @Published var format: Interchange.Format = .fcpxml { didSet { onChange?(format) } }
    var onChange: ((Interchange.Format) -> Void)?
}
struct TimelineFormatPicker: View {
    @ObservedObject var box: TimelineFormatBox
    var body: some View {
        Picker("Format", selection: $box.format) {
            ForEach(Interchange.Format.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu).pointer().uiFrame("export.timelineFormat")
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}
