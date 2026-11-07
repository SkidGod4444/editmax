import XCTest
import SwiftUI
import AppKit
@testable import EditMax

/// Looks of the Assets section, the editor's Library list, the notch drawer and the new settings, rendered off screen
/// (a window that is never shown) and written as PNGs to $EDITMAX_PREVIEW_DIR (TEST_RUNNER_EDITMAX_PREVIEW_DIR).
@MainActor
final class LibraryPreviewTests: LibraryTestCase {
    private var out: URL {
        get throws {
            guard let d = ProcessInfo.processInfo.environment["EDITMAX_PREVIEW_DIR"], !d.isEmpty else { throw XCTSkip("set TEST_RUNNER_EDITMAX_PREVIEW_DIR to write previews") }
            let u = URL(fileURLWithPath: d).appendingPathComponent("library", isDirectory: true)
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
        }
    }

    /// Renders `view` at a fixed size in an offscreen window (AppKit-backed controls draw too) and writes it.
    private func save<V: View>(_ view: V, _ name: String, size: CGSize, dark: Bool) throws {
        let dir = try out
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = appearance
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        // Let onAppear, thumbnails and fonts settle.
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }

    /// A library like a user's: a video, two pictures, a sound, a font, one item on a drive that is not connected, used
    /// in projects. (A file that is simply gone leaves the list.)
    private func populate() async throws {
        let lib = AssetLibrary.shared
        let video = try LibraryFixtures.video(dir, "Beach day.mp4")
        let photo = try LibraryFixtures.png(dir, "Sunset.png", hue: 0.05)
        let poster = try LibraryFixtures.png(dir, "Poster.png", hue: 0.62)
        let tone = try LibraryFixtures.wav(dir, "Theme music.wav", seconds: 2)
        let font = try? LibraryFixtures.font(dir)
        _ = await lib.add(urls: [tone], source: .project, copy: false)
        _ = await lib.add(urls: [poster], source: .drawer, copy: true)
        if let font { _ = await lib.add(urls: [font], source: .upload, copy: false) }
        _ = await lib.add(urls: [photo, video], source: .project, copy: false)
        let trip = UUID(), demo = UUID()
        lib.noteUsed([Asset(name: "Beach day.mp4", path: video.path, kind: .video, duration: 2, width: 1920, height: 1080)], projectID: trip, projectName: "Goa trip")
        lib.noteUsed([Asset(name: "Beach day.mp4", path: video.path, kind: .video, duration: 2, width: 1920, height: 1080),
                      Asset(name: "Theme music.wav", path: tone.path, kind: .audio, duration: 2)], projectID: demo, projectName: "Launch video")
        lib.noteUsed([Asset(name: "Old interview.mov", path: "/Volumes/Archive Drive \(UUID().uuidString.prefix(6))/Old interview.mov", kind: .video, duration: 95, width: 3840, height: 2160)], projectID: demo, projectName: "Launch video")
        // Thumbnails as the Assets grid would make them (deterministic here).
        for it in lib.all {
            switch it.name {
            case "Beach day.mp4": LibraryThumbnails.shared.set(LibraryFixtures.image(hue: 0.52), for: it.id)
            case "Sunset.png": LibraryThumbnails.shared.set(LibraryFixtures.image(hue: 0.05), for: it.id)
            case let n where n.hasPrefix("Poster"): LibraryThumbnails.shared.set(LibraryFixtures.image(hue: 0.62), for: it.id)
            default: LibraryThumbnails.shared.request(it)
            }
        }
    }

    func testPreviewHomeAssets() async throws {
        try await populate()
        let model = HomeModel()
        model.place = .assets
        for dark in [true, false] {
            try save(LibraryAssetsPane(model: model).background(Color(nsColor: .windowBackgroundColor)), "assets-home", size: CGSize(width: 760, height: 560), dark: dark)
        }
        model.assetFilter = .fonts
        try save(LibraryAssetsPane(model: model).background(Color(nsColor: .windowBackgroundColor)), "assets-home-fonts", size: CGSize(width: 900, height: 620), dark: true)
        model.assetFilter = .all
        model.assetMessage = "Added 2 files to Assets"
        try save(LibraryAssetsPane(model: model).background(Color(nsColor: .windowBackgroundColor)), "assets-home-added", size: CGSize(width: 760, height: 560), dark: true)
        XCTAssertEqual(AssetLibrary.shared.items(kind: .video).count, 2)
    }

    /// The Video filter with pictures of every shape (16:9, portrait, ultra-wide): each stays inside its card.
    func testPreviewHomeAssetsVideoShapes() async throws {
        try await populate()
        for (name, w, h, hue) in [("Wide 16x9.mp4", 1920, 1080, 0.3), ("Phone reel.mp4", 1080, 1920, 0.8), ("Ultra wide.mp4", 3840, 1600, 0.12)] {
            let v = try LibraryFixtures.video(dir, name)
            if let it = await AssetLibrary.shared.add(urls: [v], source: .project, copy: false).items.first {
                LibraryThumbnails.shared.set(LibraryFixtures.image(hue: hue, width: w, height: h), for: it.id)
            }
        }
        let model = HomeModel()
        model.place = .assets
        model.assetFilter = .video
        try save(LibraryAssetsPane(model: model).background(Color(nsColor: .windowBackgroundColor)), "assets-home-videos", size: CGSize(width: 760, height: 560), dark: true)
    }

    func testPreviewHomeAssetsEmptyAndSidebarPlaces() throws {
        let model = HomeModel()
        model.place = .assets
        try save(LibraryAssetsPane(model: model).background(Color(nsColor: .windowBackgroundColor)), "assets-home-empty", size: CGSize(width: 760, height: 420), dark: true)
        let places = VStack(alignment: .leading, spacing: 2) {
            HomePlaceRow(place: .projects, title: "Projects", symbol: "film.stack", count: 7, model: model)
            HomePlaceRow(place: .assets, title: "Assets", symbol: "photo.on.rectangle.angled", count: 12, model: model)
        }
        .padding(16).background(Color(nsColor: .windowBackgroundColor))
        for dark in [true, false] { try save(places, "assets-sidebar-places", size: CGSize(width: 250, height: 96), dark: dark) }
    }

    func testPreviewEditorLibraryList() async throws {
        try await populate()
        let doc = EditMaxDocument()
        let video = AssetLibrary.shared.all.first { $0.name == "Beach day.mp4" }!
        doc.project.assets = [Asset(name: video.name, path: video.path, kind: .video, duration: 2, width: 1920, height: 1080)]
        for dark in [true, false] {
            try save(AssetsSidebar(document: doc, mode: .library).environmentObject(EditorState()), "assets-editor-library", size: CGSize(width: 260, height: 400), dark: dark)
        }
        try save(AssetsSidebar(document: doc, mode: .project).environmentObject(EditorState()), "assets-editor-project", size: CGSize(width: 260, height: 160), dark: true)
    }

    /// The drawer over a menu bar and wallpaper, in each state, at the MacBook's notch.
    func testPreviewNotchDrawer() throws {
        let g = NotchDrawerTests.macBook
        let drawer = NotchDrawer.shared
        let size = g.frame(around: g.openBody).size
        func scene() -> some View {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.32, green: 0.45, blue: 0.62), Color(red: 0.74, green: 0.55, blue: 0.48)], startPoint: .top, endPoint: .bottom)
                Rectangle().fill(Color.white.opacity(0.22)).frame(height: g.notch.height)   // the menu bar
                NotchDrawerView(drawer: drawer)
            }
        }
        let downloads = [try LibraryFixtures.png(dir, "IMG_2041.png", hue: 0.3), try LibraryFixtures.video(dir, "screen-recording.mov"), try LibraryFixtures.wav(dir, "voiceover.wav")]
        drawer.preview(mode: .collapsed, geometry: g)
        try save(scene(), "drawer-collapsed", size: size, dark: true)
        drawer.preview(mode: .open, geometry: g)
        try save(scene(), "drawer-open-empty", size: size, dark: true)
        drawer.preview(mode: .open, geometry: g, downloads: downloads, dragging: true)
        try save(scene(), "drawer-open-dragging", size: size, dark: true)
        drawer.preview(mode: .open, geometry: g, downloads: downloads, message: "Added 2 files to Assets")
        try save(scene(), "drawer-open-added", size: size, dark: true)
        drawer.preview(mode: .peek, geometry: g, downloads: downloads, peeking: downloads[1])
        try save(scene(), "drawer-peek", size: size, dark: true)
        let pill = NotchGeometry.pill(on: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        drawer.preview(mode: .collapsed, geometry: pill)
        try save(scene(), "drawer-pill-collapsed", size: CGSize(width: 300, height: 60), dark: true)
        drawer.preview(mode: .open, geometry: pill, downloads: downloads)
        try save(scene(), "drawer-pill-open", size: pill.frame(around: pill.openBody).size, dark: true)
    }

    /// Settings' four tabs at the window's own width (each scrolls inside 580 pt; shown full height here).
    func testPreviewSettingsTabs() throws {
        let size = CGSize(width: 560, height: 820)
        for dark in [true, false] {
            try save(GeneralSettings(), "settings-general", size: size, dark: dark)
            try save(FilesSettings(), "settings-files", size: size, dark: dark)
            try save(AssistantSettings(), "settings-assistant", size: size, dark: dark)
            try save(AdvancedSettings(), "settings-advanced", size: size, dark: dark)
            // The API-key branch's keys: one saved, one from the environment, two empty (no keychain read).
            KeychainStore.sourceOverride = ["anthropic": "keychain", "openai": "environment", "google": "", "xai": ""]
            defer { KeychainStore.sourceOverride = nil }
            try save(Form { APIKeysSection(inUse: "anthropic") }.formStyle(.grouped), "settings-assistant-keys", size: CGSize(width: 560, height: 420), dark: dark)
        }
    }

    /// Each tab has one job: nothing that belongs elsewhere (the old cross options) is on it.
    func testSettingsOptionsLiveOnTheirTab() throws {
        let tabs: [(String, AnyView, [String], [String])] = [
            ("general", AnyView(GeneralSettings()), ["settings.general.appearance", "settings.general.menuBarIcon", "settings.general.updates.checkNow"],
             ["settings.files.archiveDays", "settings.runtime.auto", "settings.assistant.followAgent"]),
            ("files", AnyView(FilesSettings()), ["settings.files.library.change", "settings.files.notchDrawer", "settings.files.archiveDays"],
             ["settings.general.updates.check"]),
            ("assistant", AnyView(AssistantSettings()), ["settings.assistant.backend", "settings.assistant.followAgent"], ["settings.advanced.port"]),
            ("advanced", AnyView(AdvancedSettings()), ["settings.advanced.port", "settings.runtime.check", "settings.runtime.auto", "settings.advanced.logs"],
             ["settings.assistant.followAgent", "settings.general.updates.check"]),
        ]
        for (name, view, has, hasNot) in tabs {
            let h = OffscreenHost(view, size: CGSize(width: 560, height: 1400), dark: true)
            for id in has { XCTAssertNotNil(h.frame(id), "\(name) has \(id)") }
            for id in hasNot { XCTAssertNil(h.frame(id), "\(name) does not have \(id)") }
            h.close()
        }
        XCTAssertEqual(SettingsView.Pane.allCases.map(\.rawValue), ["general", "files", "assistant", "advanced"])
        XCTAssertEqual(KeychainStore.slot(forProvider: "claude-agent"), "anthropic")
        XCTAssertEqual(KeychainStore.slot(forProvider: "openai"), "openai")
        XCTAssertNil(KeychainStore.slot(forProvider: "someone-new"))
    }
}
