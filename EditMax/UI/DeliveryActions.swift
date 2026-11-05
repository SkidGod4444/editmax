import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let editmaxExportChapters = Notification.Name("io.openhorizon.editmax.exportChapters")
    static let editmaxBatchExport = Notification.Name("io.openhorizon.editmax.batchExport")
}

/// File > Export Chapters… and File > Batch Export… for one window: the panels, then the work through `ToolExecutor`.
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
        panel.message = "Choose a folder: every built-in template is rendered into it, named \(document.displayName)-<template>.mp4."
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

    private func flash(_ text: String) {
        state.exportStatus = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            if state.exportStatus == text { state.exportStatus = nil }
        }
    }
}
