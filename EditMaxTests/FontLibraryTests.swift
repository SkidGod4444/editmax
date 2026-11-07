import XCTest
import SwiftUI
import AppKit
import AVFoundation
import CoreText
import MCP
@testable import EditMax

/// The network the font tests see: a small Google Fonts catalogue and the fixture font (Plaster, SIL OFL; licence in
/// Fixtures/Plaster-OFL.txt) behind css2 and gstatic URLs. Nothing leaves the Mac.
final class FakeFontNetwork: @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [URLRequest] = []
    var offline = false
    let catalog: Data
    let font: Data

    init(catalog: Data, font: Data) { self.catalog = catalog; self.font = font }

    var log: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _log }
    func count(_ prefix: String) -> Int { log.filter { $0.url!.absoluteString.hasPrefix(prefix) }.count }

    func handle(_ r: URLRequest) throws -> Data {
        lock.lock(); _log.append(r); let offline = self.offline; lock.unlock()
        if offline { throw URLError(.notConnectedToInternet) }
        let u = r.url!.absoluteString
        if u.hasPrefix("https://fonts.google.com/metadata/fonts") { return catalog }
        if u.hasPrefix("https://fonts.googleapis.com/css2?family=Plaster") {
            return Data("""
            /* latin */
            @font-face {
              font-family: 'Plaster';
              font-style: normal;
              font-weight: 400;
              src: url(https://fonts.gstatic.com/s/plaster/v25/fixture.ttf) format('truetype');
            }
            """.utf8)
        }
        if u == "https://fonts.gstatic.com/s/plaster/v25/fixture.ttf" { return font }
        throw URLError(.cannotFindHost)   // every other family: as if offline
    }
}

enum FontFixtures {
    /// Four families with Google's field names, behind the `)]}'` guard line the endpoint can send. "Zed Sans" has no
    /// category (only a stroke), like 585 of the real ones.
    static let catalog = Data("""
    )]}'
    {"axisRegistry": [], "familyMetadataList": [
      {"family": "Plaster", "category": "Display", "stroke": "Sans Serif", "popularity": 900, "trending": 40, "dateAdded": "2011-12-07",
       "fonts": {"400": {"thickness": 8, "slant": 1, "width": 9}}, "subsets": ["menu", "latin", "latin-ext"]},
      {"family": "Zed Sans", "category": null, "stroke": "Sans Serif", "popularity": 5, "trending": 300, "dateAdded": "2020-01-24",
       "fonts": {"700": {}, "400i": {}, "400": {}}, "subsets": ["menu", "latin"]},
      {"family": "Brand New", "category": "Handwriting", "popularity": 1500, "trending": 1, "dateAdded": "2026-10-28",
       "fonts": {"400": {}}, "subsets": ["latin"]},
      {"family": "Old Serif", "category": "Serif", "popularity": 50, "trending": 900, "dateAdded": "2010-01-01",
       "fonts": {"400": {}, "700": {}}, "subsets": ["latin"]}
    ], "promotedScript": null}
    """.utf8)

    static func fontFile(_ test: AnyClass) -> URL { Bundle(for: test).url(forResource: "Plaster-Regular", withExtension: "ttf")! }

    /// Mean difference of two text rasters (alpha and colour, 0…1) over the area they share.
    static func difference(_ a: CGImage, _ b: CGImage) -> Double {
        let w = max(a.width, b.width), h = max(a.height, b.height)
        func pixels(_ img: CGImage) -> [UInt8] {
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: h - img.height, width: img.width, height: img.height))
            return px
        }
        let pa = pixels(a), pb = pixels(b)
        var sum = 0.0
        for i in 0..<pa.count { sum += abs(Double(pa[i]) - Double(pb[i])) }
        return sum / Double(pa.count) / 255
    }
}

/// Fonts: the model field, the one helper every renderer uses, the library (catalogue, Google downloads, added files),
/// the MCP tools and the missing-font warning. No test needs the network.
@MainActor
final class FontLibraryTests: XCTestCase {
    private var dir: URL!
    private var savedDirectory: URL!
    private var savedIndex: URL!
    private var savedFetch: (@Sendable (URLRequest) async throws -> Data)!
    private var net: FakeFontNetwork!
    private var lib: FontLibrary { FontLibrary.shared }
    private var fixture: URL { FontFixtures.fontFile(Self.self) }
    private let canvas = CGSize(width: 960, height: 540)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("fonts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedDirectory = FontLibrary.directory
        FontLibrary.directory = dir.appendingPathComponent("Fonts", isDirectory: true)
        savedIndex = AssetLibrary.indexURL
        AssetLibrary.indexURL = dir.appendingPathComponent("library.json")
        AssetLibrary.shared.load()
        savedFetch = FontLibrary.fetch
        let net = FakeFontNetwork(catalog: FontFixtures.catalog, font: try Data(contentsOf: fixture))
        self.net = net
        FontLibrary.fetch = { req in try net.handle(req) }
        lib.reset()
    }

    override func tearDown() async throws {
        for f in FontLibrary.fontFiles(in: FontLibrary.directory) { FontLibrary.unregister(f) }
        FontLibrary.fetch = savedFetch
        FontLibrary.directory = savedDirectory
        AssetLibrary.indexURL = savedIndex
        AssetLibrary.shared.load()
        lib.reset()
        try? FileManager.default.removeItem(at: dir)
    }

    private func render(_ t: TextOverlay) -> CGImage { OverlayLayerBuilder.renderText(t, canvas: canvas)!.0 }

    // MARK: Model

    func testOldProjectsDecodeWithoutAFontAndDrawAsBefore() throws {
        let json = """
        {"formatVersion": 2, "name": "Old", "texts": [
          {"id": "6F1E2B3C-0000-4000-8000-000000000001", "text": "Hello", "start": 0, "duration": 2, "fontSize": 64, "colorHex": "#FFFFFF", "x": 0.5, "y": 0.85, "preset": "bold"},
          {"id": "6F1E2B3C-0000-4000-8000-000000000002", "text": "Asha Rao", "start": 0, "duration": 4, "fontSize": 52, "colorHex": "#FFFFFF", "x": 0.3, "y": 0.8,
           "lowerThird": {"template": "bar", "role": "Engineer", "accentHex": "#FF9F0A"}}
        ]}
        """
        let p = try EditMaxDocument.decoder.decode(Project.self, from: Data(json.utf8))
        XCTAssertNil(p.texts[0].fontName); XCTAssertNil(p.texts[0].fontFamily); XCTAssertFalse(p.texts[0].hasChosenFont)
        XCTAssertFalse(p.texts[0].fontIsMissing)
        // Exactly the fonts the renderers always used.
        XCTAssertEqual(p.texts[0].font(style: CaptionPresets.style("bold"), size: 72).fontName, "HelveticaNeue-CondensedBlack")
        XCTAssertEqual(p.texts[0].font(style: CaptionPresets.title, size: 72).fontName, "HelveticaNeue-Bold")
        let lt = p.texts[1].lowerThirdFonts(nameSize: 52, roleSize: 52 * 0.55)
        XCTAssertEqual(lt.name.fontName, "HelveticaNeue-Bold"); XCTAssertEqual(lt.role.fontName, "HelveticaNeue-Medium")
        // No font: nothing new is written, so an older build reads the file unchanged.
        XCTAssertFalse(String(decoding: try EditMaxDocument.encoder.encode(p), as: UTF8.self).contains("fontName"))
        // A chosen font survives a save and reopen.
        var q = p; q.texts[0].fontName = "Plaster-Regular"; q.texts[0].fontFamily = "Plaster"
        let back = try EditMaxDocument.decoder.decode(Project.self, from: EditMaxDocument.encoder.encode(q))
        XCTAssertEqual(back.texts[0].fontName, "Plaster-Regular"); XCTAssertEqual(back.texts[0].fontFamily, "Plaster")
    }

    func testFamilyFacesAndTheLowerThirdRole() {
        // A family alone (a PostScript name this Mac lacks): the face nearest the preset's weight.
        var t = TextOverlay(text: "Title", start: 0, duration: 2, fontSize: 40)
        t.fontFamily = "Helvetica Neue"
        XCTAssertEqual(t.font(style: CaptionPresets.title, size: 40).fontName, "HelveticaNeue-Bold")
        XCTAssertEqual(t.font(style: CaptionPresets.style("minimal"), size: 40).fontName, "HelveticaNeue")
        t.fontName = "HelveticaNeue-NotHere-Light"   // the style in the name wins when the family has it
        XCTAssertEqual(t.font(style: CaptionPresets.title, size: 40).fontName, "HelveticaNeue-Light")
        // The role line is a lighter weight of the name's family.
        var lt = TextOverlay(text: "Asha Rao", start: 0, duration: 4, fontSize: 52)
        lt.lowerThird = LowerThird(role: "Engineer"); lt.fontFamily = "Avenir Next"; lt.fontName = "AvenirNext-Bold"
        let f = lt.lowerThirdFonts(nameSize: 52, roleSize: 28)
        XCTAssertEqual(f.name.fontName, "AvenirNext-Bold")
        XCTAssertEqual(f.role.familyName, "Avenir Next")
        XCTAssertLessThan(TextFont.face(of: f.role)!.weight, TextFont.face(of: f.name)!.weight)
        let faces = TextFont.faces(family: "Avenir Next")
        XCTAssertGreaterThan(faces.count, 4)
        XCTAssertFalse(faces.first!.italic, "upright faces first")
    }

    // MARK: Catalogue

    func testCatalogueParsesSortsAndWorksOffline() async throws {
        await lib.refreshCatalog()
        XCTAssertEqual(lib.catalogState, .ready)
        XCTAssertEqual(lib.catalog.count, 4)
        let zed = try XCTUnwrap(lib.googleFamily(named: "zed sans"))
        XCTAssertEqual(zed.category, .sansSerif, "no category: the stroke decides")
        XCTAssertEqual(zed.styles, ["400", "700", "400i"])
        XCTAssertEqual(zed.subsets, ["latin"], "the menu subset is not a script")
        let order = { (s: FontLibrary.Sort) in self.lib.families(sort: s, sources: [.google]).map(\.name) }
        XCTAssertEqual(order(.trending), ["Brand New", "Plaster", "Zed Sans", "Old Serif"])
        XCTAssertEqual(order(.popular), ["Zed Sans", "Old Serif", "Plaster", "Brand New"])
        XCTAssertEqual(order(.newest), ["Brand New", "Zed Sans", "Plaster", "Old Serif"])
        XCTAssertEqual(order(.name), ["Brand New", "Old Serif", "Plaster", "Zed Sans"])
        XCTAssertEqual(lib.families(category: .serif, sources: [.google]).map(\.name), ["Old Serif"])
        XCTAssertEqual(lib.families(search: "SANS", sources: [.google]).map(\.name), ["Zed Sans"])
        // Every list ends with the Mac's own families, which have no Google rank.
        let all = lib.families(sort: .trending)
        XCTAssertEqual(all.first?.name, "Brand New")
        XCTAssertTrue(all.contains { $0.source == .system && $0.name == "Helvetica Neue" })
        XCTAssertFalse(all.contains { $0.name.hasPrefix(".") })

        // Cached for a day: no second fetch.
        let fetches = net.count("https://fonts.google.com")
        await lib.refreshCatalog()
        XCTAssertEqual(net.count("https://fonts.google.com"), fetches)
        // Offline with a cache: kept, marked stale.
        net.offline = true
        await lib.refreshCatalog(force: true)
        XCTAssertEqual(lib.catalogState, .stale); XCTAssertEqual(lib.catalog.count, 4)
        // A fresh start reads the cache from disk.
        lib.reset()
        XCTAssertEqual(lib.catalog.count, 4)
        // No cache and no network: unavailable, and the Mac's fonts still list.
        try FileManager.default.removeItem(at: FontLibrary.catalogURL)
        lib.reset()
        await lib.refreshCatalog()
        XCTAssertEqual(lib.catalogState, .unavailable)
        XCTAssertTrue(lib.families(sources: [.google]).isEmpty)
        XCTAssertFalse(lib.families(sources: [.system]).isEmpty)
    }

    func testCSSQueriesAndAnswers() throws {
        XCTAssertEqual(FontLibrary.cssQuery(family: "Lobster", styles: ["400"]), "family=Lobster")
        XCTAssertEqual(FontLibrary.cssQuery(family: "Playfair Display", styles: ["700", "400"]), "family=Playfair+Display:wght@400;700")
        XCTAssertEqual(FontLibrary.cssQuery(family: "Inter", styles: ["400i", "700", "400"]), "family=Inter:ital,wght@0,400;0,700;1,400")
        let css = """
        @font-face {
          font-family: 'Inter';
          font-style: italic;
          font-weight: 700;
          src: url(https://fonts.gstatic.com/s/inter/v20/b.ttf) format('truetype');
        }
        @font-face {
          font-family: 'Inter';
          font-style: normal;
          font-weight: 400;
          src: url(https://fonts.gstatic.com/s/inter/v20/a.ttf) format('truetype');
        }
        """
        let faces = FontLibrary.parseCSS(css)
        XCTAssertEqual(faces.map(\.style), ["700i", "400"])
        XCTAssertEqual(faces.last?.url.absoluteString, "https://fonts.gstatic.com/s/inter/v20/a.ttf")
        let zed = FontLibrary.GoogleFamily(family: "Zed Sans", category: .sansSerif, popularity: 5, trending: 3, dateAdded: "", styles: ["400", "700", "400i"], subsets: [])
        XCTAssertEqual(try FontLibrary.resolveStyles(["bold", "Italic", "400"], of: zed), ["700", "400i", "400"])
        XCTAssertThrowsError(try FontLibrary.resolveStyles(["300"], of: zed)) { XCTAssertTrue($0.localizedDescription.contains("400, 700, 400i"), $0.localizedDescription) }
    }

    // MARK: Google downloads

    func testGoogleFamilyDownloadsOnceRegistersAndJoinsTheAssetsLibrary() async throws {
        let v0 = lib.version
        // Two requests at once (a pick and a project opening) fetch the file once.
        async let first = lib.installGoogle("plaster")
        async let second = lib.installGoogle("PLASTER")
        let (a, b) = try await (first, second)
        XCTAssertEqual(net.count("https://fonts.gstatic.com"), 1)
        XCTAssertEqual(a.family, "Plaster"); XCTAssertEqual(a.faces, ["Plaster-Regular"])
        XCTAssertTrue(a.alreadyInstalled != b.alreadyInstalled, "one downloaded, the other found it on disk")
        let file = FontLibrary.googleDirectory.appendingPathComponent("Plaster/Plaster-400.ttf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNotNil(NSFont(name: "Plaster-Regular", size: 20))
        XCTAssertTrue(lib.isInstalled(google: "Plaster"))
        XCTAssertGreaterThan(lib.version, v0, "open projects redraw")
        XCTAssertEqual(AssetLibrary.shared.items(kind: .font).first { $0.path == file.path }?.source, .download)
        // Google is asked as EditMax (a non-browser agent gets whole TTF files).
        for r in net.log { XCTAssertEqual(r.value(forHTTPHeaderField: "User-Agent"), FontLibrary.userAgent) }
        XCTAssertFalse(FontLibrary.userAgent.contains("Mozilla"))
        XCTAssertTrue(net.log.contains { $0.url!.absoluteString == "https://fonts.googleapis.com/css2?family=Plaster" })
        // Again: nothing fetched.
        let n = net.log.count
        let again = try await lib.installGoogle("Plaster")
        XCTAssertTrue(again.alreadyInstalled); XCTAssertEqual(net.log.count, n)
        // Unknown and unreachable families.
        do { try await lib.installGoogle("Nope Sans"); XCTFail("installed a family that does not exist") }
        catch { XCTAssertTrue(error.localizedDescription.contains("No Google font named 'Nope Sans'"), error.localizedDescription) }
        do { try await lib.installGoogle("Zed Sans"); XCTFail("downloaded without a network") }
        catch { XCTAssertNotNil(lib.installErrors["Zed Sans"]); XCTAssertFalse(lib.isInstalled(google: "Zed Sans")) }
    }

    // MARK: Fonts the user adds

    func testAddedFontRegistersAndRendersInEveryTitleRenderer() async throws {
        let upload = dir.appendingPathComponent("Brand Display.ttf")
        try FileManager.default.copyItem(at: fixture, to: upload)
        let notes = dir.appendingPathComponent("notes.txt"); try Data("x".utf8).write(to: notes)
        let fake = dir.appendingPathComponent("fake.ttf"); try Data("not a font".utf8).write(to: fake)
        let r = await lib.addFontFiles([upload, notes, fake])
        XCTAssertEqual(r.families, ["Plaster"]); XCTAssertEqual(r.faces, ["Plaster-Regular"])
        XCTAssertEqual(r.failures.count, 2, r.failures.joined(separator: "; "))
        XCTAssertTrue(r.failures.contains { $0.contains("cannot read") })
        let copy = FontLibrary.customDirectory.appendingPathComponent("Brand Display.ttf")
        XCTAssertEqual(r.files, [copy.path])
        XCTAssertEqual(AssetLibrary.shared.items(kind: .font).first { $0.path == copy.path }?.source, .upload)
        XCTAssertEqual(lib.families(sources: [.custom]).map(\.name), ["Plaster"])
        // The same file again is kept once.
        let again = await lib.addFontFiles([upload])
        XCTAssertEqual(again.files, r.files); XCTAssertEqual(lib.customFiles.count, 1)

        // Every renderer draws it: plain titles, the measured box, animated titles, lower thirds.
        let plain = TextOverlay(text: "Brand title", start: 0, duration: 2, fontSize: 72, x: 0.5, y: 0.5)
        var styled = plain; styled.fontName = "Plaster-Regular"; styled.fontFamily = "Plaster"
        XCTAssertEqual(styled.font(style: CaptionPresets.title, size: 72).fontName, "Plaster-Regular")
        XCTAssertGreaterThan(FontFixtures.difference(render(plain), render(styled)), 0.01, "the added font draws, not the preset's")
        XCTAssertNotEqual(TextLayout.box(plain, canvas: canvas), TextLayout.box(styled, canvas: canvas))
        XCTAssertNotEqual(TitleRasterizer.title(styled, canvas: canvas)!.size, TitleRasterizer.title(plain, canvas: canvas)!.size, "animated titles draw it too")
        var lt = styled; lt.lowerThird = LowerThird(role: "Brand team")
        let ltFonts = lt.lowerThirdFonts(nameSize: 50, roleSize: 27)
        XCTAssertEqual(ltFonts.name.fontName, "Plaster-Regular"); XCTAssertEqual(ltFonts.role.fontName, "Plaster-Regular", "one weight: the role uses it too")
        if let dir = ColorFixtures.previewDir {
            ColorFixtures.savePNG(render(plain), dir.appendingPathComponent("fonts-title-preset.png"))
            ColorFixtures.savePNG(render(styled), dir.appendingPathComponent("fonts-title-added-font.png"))
        }

        // Through the real renderer (the preview's and capture_frame's compositor).
        if ProcessInfo.processInfo.environment["CI"] == nil {
            let doc = EditMaxDocument(), x = ToolExecutor(document: doc, origin: .user)
            let t = try x.addText("Brand title", start: 0, duration: 2, fontSize: 96, colorHex: "#FFD60A", x: 0.5, y: 0.5, font: .family("Plaster", face: nil))
            XCTAssertEqual(t.fontName, "Plaster-Regular")
            let withFont = try await renderRetrying(x, 1)
            try x.setTextStyle(t.id.short, font: .preset, fontSize: nil, color: nil)
            let without = try await renderRetrying(x, 1)
            XCTAssertGreaterThan(FontFixtures.difference(withFont, without), 0.002)
            if let dir = ColorFixtures.previewDir { ColorFixtures.savePNG(withFont, dir.appendingPathComponent("fonts-frame-added-font.png")) }
        }

        // Removed: the file goes, the text falls back to its preset and says the font is missing.
        lib.remove(family: "Plaster", source: .custom)
        XCTAssertTrue(lib.customFiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertNil(AssetLibrary.shared.items(kind: .font).first { $0.path == copy.path })
        XCTAssertTrue(styled.fontIsMissing)
        XCTAssertEqual(FontFixtures.difference(render(plain), render(styled)), 0, accuracy: 0.0001, "drawn in the preset's font meanwhile")
    }

    // MARK: Missing fonts

    func testMissingFontFallsBackAndTheTitleCardSaysSo() async throws {
        await lib.refreshCatalog()
        let plain = TextOverlay(text: "Moved project", start: 0, duration: 2, fontSize: 64, x: 0.5, y: 0.5)
        var custom = plain; custom.fontName = "NowhereSans-Bold"; custom.fontFamily = "Nowhere Sans"
        XCTAssertTrue(custom.fontIsMissing)
        XCTAssertEqual(lib.status(of: custom), .missingCustom(family: "Nowhere Sans"))
        XCTAssertEqual(FontFixtures.difference(render(plain), render(custom)), 0, accuracy: 0.0001, "drawn in the preset's font meanwhile")
        var google = plain; google.fontName = "ZedSans-Bold"; google.fontFamily = "Zed Sans"
        XCTAssertEqual(lib.status(of: google), .missingGoogle(family: "Zed Sans", error: nil))

        // Opening a project fetches its Google fonts (this fake network refuses Zed Sans) and leaves the others alone.
        var p = Project(); p.texts = [custom, google]
        lib.ensureFonts(for: p)
        for _ in 0..<100 where lib.installErrors["Zed Sans"] == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        guard case .missingGoogle(_, let error?) = lib.status(of: google) else { return XCTFail("no download error recorded: \(lib.status(of: google))") }
        XCTAssertTrue(error.contains("Zed Sans"), error)
        XCTAssertFalse(net.log.contains { $0.url!.absoluteString.contains("Nowhere") }, "a font the user added elsewhere is not looked up online")

        // A Google font that does download: the project redraws with it, no edit recorded.
        var plaster = plain; plaster.fontName = "Plaster-Regular"; plaster.fontFamily = "Plaster"
        XCTAssertTrue(plaster.fontIsMissing)
        let doc = EditMaxDocument(); doc.project.texts = [plaster]
        let v0 = lib.version
        lib.ensureFonts(for: doc.project)
        for _ in 0..<100 where lib.version == v0 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(plaster.fontIsMissing)
        XCTAssertTrue(doc.project.history.isEmpty)

        // The Title card: the sentence and its button (PNG with EDITMAX_PREVIEW_DIR).
        let missingDoc = EditMaxDocument(); missingDoc.project.texts = [custom]
        let card = TextInspector(document: missingDoc, text: custom).environmentObject(EditorState()).environmentObject(PlayerController()).frame(height: 420)
        XCTAssertNotNil(UIPreview.render(card, width: 320, dark: true))
        UIPreview.save(card, "fonts-title-card-missing", width: 320)
        let fontDoc = EditMaxDocument(); fontDoc.project.texts = [plaster]
        UIPreview.save(TextInspector(document: fontDoc, text: plaster).environmentObject(EditorState()).environmentObject(PlayerController()).frame(height: 420), "fonts-title-card", width: 320)
    }

    // MARK: MCP

    func testFontToolsOverMCP() async throws {
        let doc = EditMaxDocument()
        DocumentRegistry.shared.register(doc)
        defer { DocumentRegistry.shared.unregister(doc) }
        // Every call names this test's project: the test host's own editor window can become key (when a test's window
        // closes) and make its untitled project the active one in the middle of the test.
        func call(_ name: String, _ a: [String: Value]) async throws -> String {
            var a = a; if EditMaxTools.argumentNames(of: name)?.contains("project") == true { a["project"] = .string(doc.id.uuidString) }
            return try await EditMaxTools.call(name, a).text
        }

        let listed = try await call("list_fonts", ["source": .string("google"), "search": .string("pla"), "sort": .string("popular")])
        XCTAssertTrue(listed.contains("\"family\" : \"Plaster\""), listed)
        XCTAssertTrue(listed.contains("\"catalog\" : \"ready\""), listed)
        let installed = try await call("list_fonts", ["source": .string("installed"), "search": .string("helvetica neue"), "limit": .int(3)])
        XCTAssertTrue(installed.contains("HelveticaNeue-Bold"), "installed families list their faces")
        do { _ = try await call("list_fonts", ["category": .string("gothic")]); XCTFail("bad category accepted") }
        catch { XCTAssertTrue("\(error.localizedDescription)".contains("category"), error.localizedDescription) }

        // add_text with a Google family that is not here yet: downloaded on use, any case.
        _ = try await call("add_text", ["text": .string("Hi"), "start": .int(0), "duration": .int(2), "font": .string("PLASTER")])
        XCTAssertEqual(doc.project.texts[0].fontName, "Plaster-Regular"); XCTAssertEqual(doc.project.texts[0].fontFamily, "Plaster")
        let id = doc.project.texts[0].id.short

        // set_text_style: back to the preset, then font, size and color as one edit.
        _ = try await call("set_text_style", ["text": .string(id), "font": .string("default")])
        XCTAssertNil(doc.project.texts[0].fontName)
        let undoBefore = doc.undoStack.count
        let styled = try await call("set_text_style", ["text": .string(id), "font": .string("Plaster-Regular"), "font_size": .int(90), "color": .string("#ff9900")])
        XCTAssertTrue(styled.contains("\"face\" : \"Plaster-Regular\""), styled)
        XCTAssertEqual(doc.project.texts[0].fontSize, 90); XCTAssertEqual(doc.project.texts[0].colorHex, "#FF9900")
        XCTAssertEqual(doc.undoStack.count, undoBefore + 1, "one undo step")
        doc.undo()
        XCTAssertNil(doc.project.texts[0].fontName); XCTAssertEqual(doc.project.texts[0].fontSize, 64)
        // A Mac family by name, any case: a Title takes its bold face.
        _ = try await call("set_text_style", ["text": .string(id), "font": .string("helvetica neue")])
        XCTAssertEqual(doc.project.texts[0].fontName, "HelveticaNeue-Bold")
        XCTAssertEqual(ToolExecutor(document: doc, origin: .agent).inspectTimeline().texts[0].font, "Helvetica Neue")
        for bad: [String: Value] in [["text": .string(id), "font": .string("Comic Nonsense")], ["text": .string(id), "color": .string("orange")], ["text": .string(id)], ["text": .string(id), "font_size": .int(2)]] {
            do { _ = try await call("set_text_style", bad); XCTFail("accepted \(bad)") } catch {}
        }

        // install_font and add_font_files.
        let inst = try await call("install_font", ["family": .string("plaster"), "weights": .array([.int(400)])])
        XCTAssertTrue(inst.contains("\"alreadyInstalled\" : true"), inst)
        do { _ = try await call("install_font", ["family": .string("Plaster"), "weights": .array([.string("700")])]); XCTFail("a style Plaster lacks") }
        catch { XCTAssertTrue(error.localizedDescription.contains("has no style"), error.localizedDescription) }
        let upload = dir.appendingPathComponent("Mine.ttf"); try FileManager.default.copyItem(at: fixture, to: upload)
        let added = try await call("add_font_files", ["paths": .array([.string(upload.path)])])
        XCTAssertTrue(added.contains("Plaster"), added)
        do { _ = try await call("add_font_files", ["paths": .array([.string(dir.appendingPathComponent("none.otf").path)])]); XCTFail("a missing file was added") } catch {}
    }

    func testFCPXMLNamesTheChosenFamilyAndFace() async throws {
        let doc = EditMaxDocument(), x = ToolExecutor(document: doc, origin: .agent)
        _ = try await x.importMedia(paths: [Bundle(for: Self.self).url(forResource: "base", withExtension: "mp4")!.path])
        _ = try x.insertClip(asset: "base.mp4")
        _ = try x.addText("Chosen", start: 0.2, duration: 1, fontSize: nil, colorHex: nil, x: nil, y: nil, font: .family("Avenir Next", face: "AvenirNext-DemiBold"))
        _ = try x.addText("Preset", start: 0.2, duration: 1, fontSize: nil, colorHex: nil, x: nil, y: 0.2)
        let r = try await x.exportTimeline(to: dir.appendingPathComponent("cut.fcpxml").path, format: .fcpxml)
        let xml = try String(contentsOfFile: r.path, encoding: .utf8)
        XCTAssertTrue(xml.contains("font=\"Avenir Next\" fontFace=\"Demi Bold\""), xml)
        XCTAssertTrue(xml.contains("font=\"HelveticaNeue-Bold\""), "a title without a font is written as before")
        XCTAssertTrue(r.transferred.contains { $0.contains("Avenir Next") }, r.transferred.joined(separator: "; "))
    }

    // MARK: Looks

    /// The browser in the Title popover and the full pane (PNG with EDITMAX_PREVIEW_DIR). Plaster is downloaded; a
    /// preview subset on disk draws "Brand New" before it is (the fixture stands in for Google's few-kB file).
    func testPreviewFontBrowserAndPane() async throws {
        await lib.refreshCatalog()
        try await lib.installGoogle("Plaster")
        try FileManager.default.createDirectory(at: FontLibrary.previewDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: FontLibrary.previewDirectory.appendingPathComponent("Brand New.ttf"))
        XCTAssertNotNil(lib.previewFont("Brand New", size: 16))
        XCTAssertNil(NSFont(name: "Plaster-Regular", size: 12).flatMap { _ in lib.installedFamily(named: "Brand New") }, "a preview is never registered")
        lib.noteUsed("Plaster")
        let upload = dir.appendingPathComponent("Studio Mark.ttf"); try FileManager.default.copyItem(at: fixture, to: upload)
        _ = await lib.addFontFiles([upload])
        let pick = FontBrowser(mode: .pick, current: "Plaster", projectFamilies: ["Plaster"]).frame(width: 340, height: 520)
        XCTAssertNotNil(UIPreview.render(pick, width: 340, dark: true))
        UIPreview.save(pick, "fonts-browser-pick", width: 340)
        UIPreview.save(FontsPane().frame(width: 620, height: 600), "fonts-pane", width: 620)
    }

    private func renderRetrying(_ x: ToolExecutor, _ t: Double) async throws -> CGImage {
        var last: Error?
        for _ in 0..<60 {
            do { return try await x.renderFrame(at: t).0 } catch { last = error; guard "\(error)".contains("-12780") else { throw error }; try await Task.sleep(nanoseconds: 50_000_000) }
        }
        throw last!
    }
}

/// Opt-in, needs the internet (`TEST_RUNNER_EDITMAX_NETWORK_TESTS=1`): the real Google Fonts catalogue and a real
/// family, drawn by the real renderer and in an exported movie.
@MainActor
final class GoogleFontsNetworkTests: XCTestCase {
    func testRealGoogleFontInPreviewAndExport() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EDITMAX_NETWORK_TESTS"] == "1", "set TEST_RUNNER_EDITMAX_NETWORK_TESTS=1 to run")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fonts-net-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let savedDir = FontLibrary.directory, savedIndex = AssetLibrary.indexURL
        FontLibrary.directory = dir.appendingPathComponent("Fonts"); AssetLibrary.indexURL = dir.appendingPathComponent("library.json"); AssetLibrary.shared.load()
        FontLibrary.shared.reset()
        defer {
            for f in FontLibrary.fontFiles(in: FontLibrary.directory) { FontLibrary.unregister(f) }
            FontLibrary.directory = savedDir; AssetLibrary.indexURL = savedIndex; AssetLibrary.shared.load(); FontLibrary.shared.reset()
            try? FileManager.default.removeItem(at: dir)
        }
        await FontLibrary.shared.refreshCatalog()
        XCTAssertEqual(FontLibrary.shared.catalogState, .ready)
        XCTAssertGreaterThan(FontLibrary.shared.catalog.count, 1500)
        let top = FontLibrary.shared.families(sort: .trending, sources: [.google]).prefix(5).map(\.name)
        print("FONTS-NOTE: catalogue \(FontLibrary.shared.catalog.count) families; trending top 5: \(top.joined(separator: ", "))")
        let r = try await FontLibrary.shared.installGoogle("Playfair Display", styles: ["400", "700", "700i"])
        print("FONTS-NOTE: installed \(r.faces.joined(separator: ", "))")
        XCTAssertTrue(r.faces.contains("PlayfairDisplay-Bold"))

        let doc = EditMaxDocument(), x = ToolExecutor(document: doc, origin: .user)
        doc.project.settings.width = 1280; doc.project.settings.height = 720
        let t = try x.addText("Playfair Display, from Google Fonts", start: 0, duration: 2, fontSize: 72, colorHex: "#FFFFFF", x: 0.5, y: 0.5, font: .family("Playfair Display", face: nil))
        XCTAssertEqual(t.fontName, "PlayfairDisplay-Bold")
        let withFont = try await x.renderFrame(at: 1).0
        let out = dir.appendingPathComponent("export.mp4")
        _ = try await x.exportVideo(to: out.path, preset: .high)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: out)); gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let exported = try await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        try x.setTextStyle(t.id.short, font: .preset, fontSize: nil, color: nil)
        let preset = try await x.renderFrame(at: 1).0
        let previewVsExport = FontFixtures.difference(withFont, exported), previewVsPreset = FontFixtures.difference(withFont, preset)
        print("FONTS-NOTE: preview vs export \(previewVsExport), preview vs preset font \(previewVsPreset)")
        XCTAssertLessThan(previewVsExport, previewVsPreset / 3, "the export draws the same font as the preview")
        if let p = ColorFixtures.previewDir {
            ColorFixtures.savePNG(withFont, p.appendingPathComponent("fonts-google-preview-frame.png"))
            ColorFixtures.savePNG(exported, p.appendingPathComponent("fonts-google-export-frame.png"))
            ColorFixtures.savePNG(preset, p.appendingPathComponent("fonts-google-preset-frame.png"))
        }
    }
}
