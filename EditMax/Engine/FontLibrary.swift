import Foundation
import AppKit
import CoreText

// Fonts for titles: every family on this Mac, the Google Fonts catalogue (downloaded on demand) and fonts the user adds.
//
// Files live under `~/Library/Application Support/EditMax/Fonts/`: `google/<Family>/` (TTF files from Google's css2 API),
// `custom/` (copies of what the user added), `previews/` (few-kB subsets that draw a family's name before it is
// downloaded) and `google-catalog.json` (the catalogue, refreshed at most once a day). Every downloaded and added file is
// registered with Core Text for this process at launch (`registerInstalledFonts`, called from `EditMaxApp.init` before
// any window opens), so the preview, exports and capture_frame all draw with it. See docs/internals-fonts.md.

@MainActor
final class FontLibrary: ObservableObject {
    static let shared = FontLibrary()

    // MARK: Types

    enum Source: String, Codable, CaseIterable, Identifiable {
        case system, google, custom
        var id: String { rawValue }
        var title: String { switch self { case .system: "On this Mac"; case .google: "Google Fonts"; case .custom: "My fonts" } }
    }

    enum Category: String, Codable, CaseIterable, Identifiable {
        case sansSerif = "sans-serif", serif, display, handwriting, monospace
        var id: String { rawValue }
        var title: String {
            switch self { case .sansSerif: "Sans serif"; case .serif: "Serif"; case .display: "Display"; case .handwriting: "Handwriting"; case .monospace: "Monospace" }
        }
        /// "Sans Serif", "sans-serif", "sans", "Slab Serif", "script"… (Google's names and the tools' arguments).
        static func parse(_ s: String?) -> Category? {
            guard let s else { return nil }
            switch s.lowercased().replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces) {
            case "sans serif", "sans", "sansserif": return .sansSerif
            case "serif", "slab serif", "slab": return .serif
            case "display", "decorative": return .display
            case "handwriting", "script": return .handwriting
            case "monospace", "mono", "monospaced": return .monospace
            default: return nil
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case trending, popular, newest, name
        var id: String { rawValue }
        var title: String { switch self { case .trending: "Trending"; case .popular: "Popular"; case .newest: "Newest"; case .name: "A–Z" } }
        static func parse(_ s: String?) -> Sort? {
            guard let s else { return nil }
            switch s.lowercased() { case "trending": return .trending; case "popular", "popularity": return .popular; case "newest", "new", "date": return .newest
            case "name", "a-z", "a–z", "alphabetical": return .name; default: return nil }
        }
    }

    /// One family of the Google Fonts catalogue (the fields EditMax uses from fonts.google.com/metadata/fonts).
    struct GoogleFamily: Codable, Equatable {
        var family: String
        var category: Category?
        /// Google's rank by use, 1 = most used.
        var popularity: Int
        /// Google's trending rank, 1 = fastest growing (favours recent additions).
        var trending: Int
        /// yyyy-MM-dd
        var dateAdded: String
        /// "400", "400i", "700"…: weight, i = italic.
        var styles: [String]
        var subsets: [String]
    }

    /// One row of the font browser.
    struct Family: Identifiable, Equatable {
        var name: String
        var source: Source
        var category: Category?
        var installed: Bool
        /// Faces on this Mac, or the styles Google offers when not downloaded.
        var styles: Int
        var google: GoogleFamily? = nil
        var id: String { "\(source.rawValue):\(name)" }
    }

    /// A font file the user added (in `custom/`).
    struct CustomFile: Equatable {
        var url: URL
        var faces: [TextFont.Face]
        var families: [String] { Array(Set(faces.map(\.family))).sorted() }
    }

    enum CatalogState: Equatable {
        /// Never loaded yet, or loading with nothing cached.
        case loading
        /// Fetched within a day.
        case ready
        /// From the cache; the refresh failed (offline).
        case stale
        /// No cache and no network: only system and added fonts.
        case unavailable
    }

    /// How a text's chosen font stands on this Mac (the Title card shows it).
    enum FontStatus: Equatable {
        case ok
        case downloading(family: String, progress: Double)
        /// A Google family that is not downloaded (offline, or the download failed).
        case missingGoogle(family: String, error: String?)
        /// A font the user added on another Mac.
        case missingCustom(family: String)
    }

    enum FontError: LocalizedError {
        case notFound(String)
        case download(String)
        var errorDescription: String? { switch self { case .notFound(let s), .download(let s): s } }
    }

    // MARK: Locations

    static let defaultDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("EditMax/Fonts", isDirectory: true)
    /// Tests point it at a temporary folder.
    static var directory = defaultDirectory
    static var googleDirectory: URL { directory.appendingPathComponent("google", isDirectory: true) }
    static var customDirectory: URL { directory.appendingPathComponent("custom", isDirectory: true) }
    static var previewDirectory: URL { directory.appendingPathComponent("previews", isDirectory: true) }
    static var catalogURL: URL { directory.appendingPathComponent("google-catalog.json") }

    static let metadataURL = URL(string: "https://fonts.google.com/metadata/fonts")!
    static let cssURL = "https://fonts.googleapis.com/css2"
    /// Google's css2 API picks the file format from the User-Agent: a browser gets WOFF2 split by script, anything else
    /// one complete TTF per style. EditMax asks as itself.
    nonisolated static let userAgent = "EditMax/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1")"
    static let fontExtensions = AssetLibrary.fontExtensions   // ttf otf ttc otc woff woff2: Core Text reads them all
    static let catalogMaxAge: TimeInterval = 24 * 3600

    /// Fetches a URL; tests swap in local data so they never need the network.
    nonisolated(unsafe) static var fetch: @Sendable (URLRequest) async throws -> Data = { req in
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FontError.download("\(req.url?.host ?? "server") answered \(http.statusCode)")
        }
        return data
    }

    // MARK: State

    /// Bumped whenever fonts are registered or removed: open projects redraw their titles (`PlayerController.bind`).
    @Published private(set) var version = 0
    @Published private(set) var catalog: [GoogleFamily] = []
    @Published private(set) var catalogState: CatalogState = .loading
    @Published private(set) var catalogDate: Date?
    /// Google families downloading now, 0…1.
    @Published private(set) var progress: [String: Double] = [:]
    /// The last download error per Google family.
    @Published private(set) var installErrors: [String: String] = [:]
    @Published private(set) var customFiles: [CustomFile] = []
    /// Downloaded Google families → their files.
    @Published private(set) var googleInstalled: [String: [URL]] = [:]
    /// Families picked lately, newest first.
    @Published private(set) var recent: [String] = []
    /// Bumped when a preview arrives (rows redraw).
    @Published private(set) var previewTick = 0
    private(set) var systemFamilies: [String] = []

    private var catalogIndex: [String: Int] = [:]
    private var installs: [String: Task<InstallResult, Error>] = [:]
    private var catalogTask: Task<Void, Never>?
    private var displayFonts: [String: NSFont] = [:]
    private var categories: [String: Category?] = [:]
    private var previewDescriptors: [String: CTFontDescriptor] = [:]
    private var previewFailed: Set<String> = []
    private var previewQueue: [String] = []
    private var previewsInFlight = 0
    private var ensuring: Set<String> = []

    private init() {
        recent = AppDelegate.isTesting ? [] : (UserDefaults.standard.stringArray(forKey: "recentFonts") ?? [])
        reload()
    }

    // MARK: Launch

    /// Registers every downloaded and added font for this process. Called once at launch, before any project window
    /// opens, so every render sees them. Returns how many files are available.
    @discardableResult
    static func registerInstalledFonts() -> Int {
        let t0 = Date()
        let files = fontFiles(in: googleDirectory) + fontFiles(in: customDirectory)
        let ok = files.filter(register).count
        if !files.isEmpty { DebugLog.event("fonts-registered", ["files": files.count, "ok": ok, "ms": Int(Date().timeIntervalSince(t0) * 1000)]) }
        return ok
    }

    /// Registers one file with Core Text (process scope). A file already registered counts as done.
    @discardableResult
    static func register(_ url: URL) -> Bool {
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        guard let e = error?.takeRetainedValue() else { return false }
        if CFErrorGetCode(e) == CTFontManagerError.alreadyRegistered.rawValue { return true }
        DebugLog.event("font-register-failed", ["file": url.lastPathComponent, "error": CFErrorCopyDescription(e) as String? ?? ""])
        return false
    }

    static func unregister(_ url: URL) {
        var error: Unmanaged<CFError>?
        _ = CTFontManagerUnregisterFontsForURL(url as CFURL, .process, &error)
        error?.release()
    }

    /// Font files under a folder (one level of family folders deep).
    static func fontFiles(in dir: URL) -> [URL] {
        // Built from `dir` itself (a directory enumerator rewrites /private/var as /var), so paths match the ones
        // stored in the Assets library and returned by installs and adds.
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.flatMap { u -> [URL] in
            let file = dir.appendingPathComponent(u.lastPathComponent)
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return fontFiles(in: file) }
            return fontExtensions.contains(u.pathExtension.lowercased()) ? [file] : []
        }.sorted { $0.path < $1.path }
    }

    /// The faces in a font file (a collection has several), without registering it. Empty when Core Text cannot read it.
    static func faces(in url: URL) -> [TextFont.Face] {
        ((CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]) ?? []).compactMap(TextFont.face(of:))
    }

    // MARK: Scanning

    /// Rescans the font folders and the Mac's families, and reloads the cached catalogue.
    func reload() {
        customFiles = Self.fontFiles(in: Self.customDirectory).map { CustomFile(url: $0, faces: Self.faces(in: $0)) }.filter { !$0.faces.isEmpty }
        var google: [String: [URL]] = [:]
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Self.googleDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let files = Self.fontFiles(in: dir)
            if !files.isEmpty { google[dir.lastPathComponent] = files }
        }
        googleInstalled = google
        let ours = Set((customFiles.flatMap(\.families) + google.keys).map { $0.lowercased() })
        systemFamilies = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") && !ours.contains($0.lowercased()) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        displayFonts = [:]
        loadCachedCatalog()
    }

    /// Forgets everything loaded, then rescans (tests point `directory` somewhere else first).
    func reset() {
        catalog = []; catalogIndex = [:]; catalogDate = nil; catalogState = .loading
        progress = [:]; installErrors = [:]; recent = []
        previewDescriptors = [:]; previewFailed = []; previewQueue = []; categories = [:]
        reload()
    }

    private func fontsChanged() {
        reload()
        version += 1
    }

    // MARK: Catalogue

    private struct CatalogCache: Codable { var fetched: Date; var families: [GoogleFamily] }

    func loadCachedCatalog() {
        guard let data = try? Data(contentsOf: Self.catalogURL), let cache = try? JSONDecoder().decode(CatalogCache.self, from: data), !cache.families.isEmpty else {
            if catalog.isEmpty { catalogState = .loading }
            return
        }
        setCatalog(cache.families, fetched: cache.fetched)
        catalogState = Date().timeIntervalSince(cache.fetched) < Self.catalogMaxAge ? .ready : .stale
    }

    private func setCatalog(_ families: [GoogleFamily], fetched: Date) {
        catalog = families
        catalogDate = fetched
        catalogIndex = Dictionary(families.enumerated().map { ($1.family.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Fetches the Google Fonts catalogue when the cached one is a day old or missing (`force` fetches anyway). Offline
    /// it keeps the cache (`stale`); with no cache it reports `unavailable` and the browser shows system and added fonts.
    func refreshCatalog(force: Bool = false) async {
        if let t = catalogTask { return await t.value }
        if !force, let d = catalogDate, Date().timeIntervalSince(d) < Self.catalogMaxAge, !catalog.isEmpty { catalogState = .ready; return }
        let task = Task { @MainActor in
            do {
                var req = URLRequest(url: Self.metadataURL, timeoutInterval: 30)
                req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
                let data = try await Self.fetch(req)
                let families = try await Task.detached(priority: .userInitiated) { try Self.parseCatalog(data) }.value
                let now = Date()
                setCatalog(families, fetched: now)
                catalogState = .ready
                try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                try? JSONEncoder().encode(CatalogCache(fetched: now, families: families)).write(to: Self.catalogURL, options: .atomic)
                DebugLog.event("fonts-catalog", ["families": families.count])
            } catch {
                catalogState = catalog.isEmpty ? .unavailable : .stale
                DebugLog.event("fonts-catalog-failed", ["error": error.localizedDescription])
            }
        }
        catalogTask = task
        await task.value
        catalogTask = nil
    }

    /// Parses fonts.google.com/metadata/fonts (with or without its `)]}'` guard line).
    nonisolated static func parseCatalog(_ data: Data) throws -> [GoogleFamily] {
        struct Raw: Decodable {
            struct Item: Decodable {
                struct Any_: Decodable {}
                var family: String
                var category: String?
                var stroke: String?
                var popularity: Int?
                var trending: Int?
                var dateAdded: String?
                var fonts: [String: Any_]?
                var subsets: [String]?
            }
            var familyMetadataList: [Item]
        }
        var body = data
        if let s = String(data: data.prefix(8), encoding: .utf8), s.hasPrefix(")]}'") {
            body = data.drop(while: { $0 != UInt8(ascii: "\n") && $0 != UInt8(ascii: "{") })
        }
        let raw = try JSONDecoder().decode(Raw.self, from: body)
        return raw.familyMetadataList.map { i in
            let styles = (i.fonts.map { Array($0.keys) } ?? ["400"]).sorted { styleOrder($0) < styleOrder($1) }
            return GoogleFamily(family: i.family, category: Category.parse(i.category) ?? Category.parse(i.stroke),
                                popularity: i.popularity ?? 99_999, trending: i.trending ?? 99_999, dateAdded: i.dateAdded ?? "",
                                styles: styles, subsets: (i.subsets ?? []).filter { $0 != "menu" })
        }
    }

    /// "700i" → (1, 700) so styles sort upright first, light to heavy.
    nonisolated static func styleOrder(_ s: String) -> (Int, Int) { (s.hasSuffix("i") ? 1 : 0, Int(s.trimmingCharacters(in: CharacterSet.decimalDigits.inverted)) ?? 400) }

    func googleFamily(named name: String) -> GoogleFamily? {
        catalogIndex[name.lowercased()].map { catalog[$0] }
    }

    // MARK: Google downloads

    struct InstallResult: Codable, Equatable {
        var family: String
        var styles: [String]
        /// PostScript names now on this Mac.
        var faces: [String]
        var files: [String]
        var alreadyInstalled: Bool
        /// Styles asked for that Google did not send.
        var missing: [String]? = nil
    }

    func isInstalled(google family: String) -> Bool { googleInstalled.keys.contains { $0.caseInsensitiveCompare(family) == .orderedSame } }

    /// Downloads a Google family (every style it has, or `styles` such as ["400", "700", "400i"]) as TTF files into
    /// `google/<Family>/`, registers them and adds them to the Assets library. Styles already on disk are not fetched again;
    /// a second call while one is running waits for it.
    @discardableResult
    func installGoogle(_ name: String, styles wanted: [String]? = nil) async throws -> InstallResult {
        if googleFamily(named: name) == nil { await refreshCatalog() }
        guard let g = googleFamily(named: name) else {
            if catalog.isEmpty { throw FontError.download("The Google Fonts list could not be loaded, so '\(name)' cannot be downloaded. Check the connection.") }
            throw FontError.notFound("No Google font named '\(name)'.\(suggestion(for: name))")
        }
        let styles = try Self.resolveStyles(wanted, of: g)
        let key = g.family.lowercased()
        if let running = installs[key] { _ = try? await running.value }
        let task = Task { @MainActor in try await self.download(g, styles: styles) }
        installs[key] = task
        defer { installs[key] = nil }
        return try await task.value
    }

    /// Validates requested styles: numbers or strings ("700", "700i", "700italic", "regular", "bold", "italic").
    static func resolveStyles(_ wanted: [String]?, of g: GoogleFamily) throws -> [String] {
        guard let wanted, !wanted.isEmpty else { return g.styles }
        var out: [String] = []
        for w in wanted {
            var s = w.lowercased().replacingOccurrences(of: " ", with: "")
            switch s { case "regular", "normal": s = "400"; case "bold": s = "700"; case "italic": s = "400i"; case "bolditalic": s = "700i"; default: break }
            s = s.replacingOccurrences(of: "italic", with: "i")
            guard g.styles.contains(s) else {
                throw FontError.notFound("\(g.family) has no style '\(w)'. It has \(g.styles.joined(separator: ", ")) (i = italic).")
            }
            if !out.contains(s) { out.append(s) }
        }
        return out
    }

    private static func file(for family: String, style: String, ext: String = "ttf") -> URL {
        googleDirectory.appendingPathComponent(family, isDirectory: true)
            .appendingPathComponent("\(family.replacingOccurrences(of: " ", with: ""))-\(style).\(ext)")
    }

    /// The css2 query for some styles of a family: `family=Inter:ital,wght@0,400;1,700` (tuples sorted, as the API requires).
    static func cssQuery(family: String, styles: [String]) -> String {
        let name = family.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: " -_.")))!.replacingOccurrences(of: " ", with: "+")
        let parsed = Set(styles).map(styleOrder).sorted { $0 < $1 }
        if parsed.isEmpty || (parsed.count == 1 && parsed[0] == (0, 400)) { return "family=\(name)" }
        if !parsed.contains(where: { $0.0 == 1 }) { return "family=\(name):wght@" + parsed.map { String($0.1) }.joined(separator: ";") }
        return "family=\(name):ital,wght@" + parsed.map { "\($0.0),\($0.1)" }.joined(separator: ";")
    }

    struct CSSFace: Equatable { var style: String; var url: URL; var format: String }

    /// The faces of a css2 answer: one `@font-face` block per style (non-browser User-Agent: one whole file each).
    static func parseCSS(_ css: String) -> [CSSFace] {
        css.components(separatedBy: "@font-face").dropFirst().compactMap { block in
            func first(_ pattern: String) -> String? {
                guard let r = block.range(of: pattern, options: .regularExpression) else { return nil }
                let m = String(block[r])
                guard let re = try? NSRegularExpression(pattern: pattern), let g = re.firstMatch(in: m, range: NSRange(m.startIndex..., in: m)), g.numberOfRanges > 1,
                      let rr = Range(g.range(at: 1), in: m) else { return nil }
                return String(m[rr])
            }
            guard let weight = first(#"font-weight:\s*(\d+)"#), let u = first(#"url\(([^)]+)\)"#), let url = URL(string: u) else { return nil }
            let italic = first(#"font-style:\s*(\w+)"#) == "italic"
            return CSSFace(style: weight + (italic ? "i" : ""), url: url, format: first(#"format\('([^']+)'\)"#) ?? "truetype")
        }
    }

    private func download(_ g: GoogleFamily, styles: [String]) async throws -> InstallResult {
        let family = g.family
        let dir = Self.googleDirectory.appendingPathComponent(family, isDirectory: true)
        let have = Dictionary(Self.fontFiles(in: dir).map { ($0.deletingPathExtension().lastPathComponent.components(separatedBy: "-").last ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        let todo = styles.filter { have[$0] == nil }
        if todo.isEmpty {
            let files = styles.compactMap { have[$0] }
            files.forEach { Self.register($0) }
            return InstallResult(family: family, styles: styles, faces: files.flatMap { Self.faces(in: $0).map(\.postScript) }, files: files.map(\.path), alreadyInstalled: true)
        }
        progress[family] = 0.02
        installErrors[family] = nil
        defer { progress[family] = nil }
        do {
            var req = URLRequest(url: URL(string: "\(Self.cssURL)?\(Self.cssQuery(family: family, styles: todo))")!, timeoutInterval: 30)
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            let css = String(decoding: try await Self.fetch(req), as: UTF8.self)
            let faces = Self.parseCSS(css).filter { todo.contains($0.style) }
            guard !faces.isEmpty else { throw FontError.download("Google Fonts sent no files for \(family)") }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var saved: [URL] = [], done = 0
            // Four files at a time.
            try await withThrowingTaskGroup(of: (CSSFace, Data).self) { group in
                var queue = faces[...]
                func next() {
                    guard let f = queue.popFirst() else { return }
                    group.addTask {
                        var r = URLRequest(url: f.url, timeoutInterval: 60)
                        r.setValue(FontLibrary.userAgent, forHTTPHeaderField: "User-Agent")
                        return (f, try await FontLibrary.fetch(r))
                    }
                }
                for _ in 0..<4 { next() }
                for try await (face, data) in group {
                    let ext = face.format.contains("woff2") ? "woff2" : face.format.contains("woff") ? "woff" : face.format.contains("opentype") ? "otf" : "ttf"
                    let url = Self.file(for: family, style: face.style, ext: ext)
                    let tmp = dir.appendingPathComponent(".\(UUID().uuidString).\(ext)")
                    try data.write(to: tmp)
                    guard !Self.faces(in: tmp).isEmpty else { try? FileManager.default.removeItem(at: tmp); throw FontError.download("\(family) \(face.style): the file is not a font") }
                    if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
                    try FileManager.default.moveItem(at: tmp, to: url)
                    Self.register(url)
                    saved.append(url)
                    done += 1
                    progress[family] = Double(done) / Double(faces.count)
                    next()
                }
            }
            await AssetLibrary.shared.add(urls: saved, source: .download, copy: false)
            fontsChanged()
            let all = styles.compactMap { s in have[s] ?? saved.first { $0.deletingPathExtension().lastPathComponent.hasSuffix("-\(s)") } }
            let got = Set(faces.map(\.style))
            let missing = todo.filter { !got.contains($0) }
            DebugLog.event("font-installed", ["family": family, "files": saved.count])
            return InstallResult(family: family, styles: styles.filter { have[$0] != nil || got.contains($0) }, faces: all.flatMap { Self.faces(in: $0).map(\.postScript) },
                                 files: all.map(\.path), alreadyInstalled: false, missing: missing.isEmpty ? nil : missing)
        } catch {
            let message = "Could not download \(family): \(error.localizedDescription)"
            installErrors[family] = message
            DebugLog.event("font-install-failed", ["family": family, "error": error.localizedDescription])
            if !(Self.fontFiles(in: dir).isEmpty) { fontsChanged() }   // keep what did arrive
            throw FontError.download(message)
        }
    }

    // MARK: Fonts the user adds

    struct AddResult: Codable, Equatable {
        var families: [String]
        var faces: [String]
        var files: [String]
        var failures: [String]
    }

    /// Copies font files (.ttf .otf .ttc .otc .woff .woff2) into `custom/`, registers them and adds them to the Assets
    /// library. A file Core Text cannot read is refused; the same file added twice is kept once.
    func addFontFiles(_ urls: [URL]) async -> AddResult {
        var copies: [URL] = [], failures: [String] = [], faces: [TextFont.Face] = []
        for src in urls {
            let name = src.lastPathComponent
            guard Self.fontExtensions.contains(src.pathExtension.lowercased()) else { failures.append("\(name): not a font file (.ttf, .otf, .ttc, .otc, .woff or .woff2)"); continue }
            guard FileManager.default.fileExists(atPath: src.path) else { failures.append("\(name): file not found"); continue }
            let inFile = Self.faces(in: src)
            guard !inFile.isEmpty else { failures.append("\(name): macOS cannot read this font"); continue }
            let size = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            if let same = customFiles.first(where: { $0.faces.map(\.postScript) == inFile.map(\.postScript) && ((try? $0.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2) == size }) {
                copies.append(same.url); faces += same.faces; continue   // already added
            }
            do {
                try FileManager.default.createDirectory(at: Self.customDirectory, withIntermediateDirectories: true)
                var dest = Self.customDirectory.appendingPathComponent(name)
                var n = 2
                while FileManager.default.fileExists(atPath: dest.path) {
                    dest = Self.customDirectory.appendingPathComponent("\(src.deletingPathExtension().lastPathComponent) \(n).\(src.pathExtension)"); n += 1
                }
                try FileManager.default.copyItem(at: src, to: dest)
                guard Self.register(dest) else { try? FileManager.default.removeItem(at: dest); failures.append("\(name): macOS would not load this font"); continue }
                copies.append(dest); faces += inFile
            } catch { failures.append("\(name): \(error.localizedDescription)") }
        }
        if !copies.isEmpty {
            await AssetLibrary.shared.add(urls: copies, source: .upload, copy: false)
            fontsChanged()
            DebugLog.event("fonts-added", ["files": copies.count, "failures": failures.count])
        }
        return AddResult(families: Array(Set(faces.map(\.family))).sorted(), faces: faces.map(\.postScript), files: copies.map(\.path), failures: failures)
    }

    /// Removes a family the user added, or a downloaded Google family: its files go to the Trash and leave the Assets
    /// library. Texts using it draw in their preset's font (the Title card says the font is missing).
    func remove(family: String, source: Source) {
        var files: [URL] = []
        switch source {
        case .custom: files = customFiles.filter { $0.families.contains { $0.caseInsensitiveCompare(family) == .orderedSame } }.map(\.url)
        case .google: files = googleInstalled.first { $0.key.caseInsensitiveCompare(family) == .orderedSame }?.value ?? []
        case .system: return
        }
        guard !files.isEmpty else { return }
        for f in files { Self.unregister(f); Self.discard(f) }
        if source == .google, let dir = files.first?.deletingLastPathComponent(), Self.fontFiles(in: dir).isEmpty { Self.discard(dir) }
        let paths = Set(files.map(\.standardizedFileURL.path))
        AssetLibrary.shared.remove(Set(AssetLibrary.shared.items(kind: .font).filter { paths.contains(URL(fileURLWithPath: $0.path).standardizedFileURL.path) }.map(\.id)))
        recent.removeAll { $0.caseInsensitiveCompare(family) == .orderedSame }
        fontsChanged()
        DebugLog.event("fonts-removed", ["files": files.count, "source": source.rawValue])
    }

    /// The installed family a font file belongs to (an added or downloaded font), for Remove on an Assets card.
    func installedFamily(ofFile path: String) -> (family: String, source: Source)? {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        if let f = customFiles.first(where: { $0.url.standardizedFileURL.path == p }), let family = f.families.first { return (family, .custom) }
        if let g = googleInstalled.first(where: { $0.value.contains { $0.standardizedFileURL.path == p } }) { return (g.key, .google) }
        return nil
    }

    /// To the Trash (the user can put a font back); tests delete their temporary copies instead.
    private static func discard(_ url: URL) {
        if AppDelegate.isTesting { try? FileManager.default.removeItem(at: url) } else { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
    }

    // MARK: Lists

    /// Every family, filtered and sorted for the browser and `list_fonts`. Trending, Popular and Newest order the Google
    /// families by Google's own ranks; families without them (system, added) follow, A–Z.
    func families(search: String = "", category: Category? = nil, sort: Sort = .trending, sources: Set<Source> = Set(Source.allCases), installedOnly: Bool = false) -> [Family] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [Family] = []
        if sources.contains(.custom) {
            var byFamily: [String: [TextFont.Face]] = [:]
            for f in customFiles { for face in f.faces { byFamily[face.family, default: []].append(face) } }
            out += byFamily.map { Family(name: $0.key, source: .custom, category: inferredCategory($0.key), installed: true, styles: Set($0.value.map(\.postScript)).count) }
        }
        if sources.contains(.google) {
            for g in catalog {
                let installed = isInstalled(google: g.family)
                if installedOnly && !installed { continue }
                out.append(Family(name: g.family, source: .google, category: g.category, installed: installed, styles: g.styles.count, google: g))
            }
            for (name, files) in googleInstalled where googleFamily(named: name) == nil {   // downloaded, catalogue not loaded
                out.append(Family(name: name, source: .google, category: nil, installed: true, styles: files.count))
            }
        }
        if sources.contains(.system) {
            out += systemFamilies.map { Family(name: $0, source: .system, category: nil, installed: true, styles: 0) }
        }
        if !q.isEmpty { out = out.filter { $0.name.lowercased().contains(q) } }
        if let category { out = out.filter { ($0.source == .google ? $0.category : inferredCategory($0.name)) == category } }
        let byName: (Family, Family) -> Bool = { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        switch sort {
        case .name: out.sort(by: byName)
        case .trending, .popular, .newest:
            out.sort { a, b in
                switch (a.google, b.google) {
                case let (x?, y?):
                    switch sort {
                    case .trending: return x.trending < y.trending
                    case .popular: return x.popularity < y.popularity
                    default: return x.dateAdded != y.dateAdded ? x.dateAdded > y.dateAdded : x.popularity < y.popularity
                    }
                case (.some, nil): return true
                case (nil, .some): return false
                default: return byName(a, b)
                }
            }
        }
        return out
    }

    /// Families the project's texts use.
    func families(in project: Project) -> [String] {
        Array(Set(project.texts.compactMap(\.fontDisplayName))).sorted()
    }

    /// A family's category from its own design classes (system and added fonts; Google's come from the catalogue).
    func inferredCategory(_ family: String) -> Category? {
        if let c = categories[family] { return c }
        var c: Category?
        if let g = googleFamily(named: family) { c = g.category }
        else if let f = displayFont(family, size: 12) {
            let t = CTFontGetSymbolicTraits(f as CTFont)
            if t.contains(.traitMonoSpace) { c = .monospace }
            else {
                switch (t.rawValue & CTFontSymbolicTraits.traitClassMask.rawValue) >> 28 {
                case 1, 2, 3, 4, 5, 7: c = .serif
                case 8: c = .sansSerif
                case 9: c = .display
                case 10: c = .handwriting
                default: c = nil
                }
            }
        }
        categories[family] = c
        return c
    }

    /// A face of an installed family to draw its name in (regular weight, upright); nil when it is not on this Mac or
    /// cannot draw its own name (symbol fonts).
    func displayFont(_ family: String, size: CGFloat) -> NSFont? {
        let base: NSFont
        if let f = displayFonts[family] { base = f }
        else {
            guard let face = TextFont.face(family: family, near: 0), let f = NSFont(name: face.postScript, size: 12) else { return nil }
            let cls = (CTFontGetSymbolicTraits(f as CTFont).rawValue & CTFontSymbolicTraits.traitClassMask.rawValue) >> 28
            let chars = Array(family.utf16)
            var glyphs = [CGGlyph](repeating: 0, count: chars.count)
            guard cls != 12, CTFontGetGlyphsForCharacters(f as CTFont, chars, &glyphs, chars.count) else { return nil }
            displayFonts[family] = f
            base = f
        }
        return NSFontManager.shared.convert(base, toSize: size)
    }

    // MARK: Previews (Google families not downloaded)

    private static func previewFile(_ family: String) -> URL { previewDirectory.appendingPathComponent("\(family).ttf") }

    /// A font that draws `family`'s name before it is downloaded: Google's subset of just those letters (a few kB),
    /// loaded from data and never registered, because it carries the full font's PostScript name. nil until fetched.
    /// The letters a family's sample subset carries: the browser's preview pane shows a family before it is downloaded.
    static let sampleLetters = "The quick brown fox jumps over the lazy dog ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz 0123456789 .,:;!?&'\"-()"
    static let defaultSample = "The quick brown fox jumps over the lazy dog"
    private static let sampleSuffix = " (sample)"
    private static func previewKey(_ family: String, sample: Bool) -> String { sample ? family + sampleSuffix : family }

    /// A family's preview subset: its name in itself, or (`sample`) the alphabet and digits for the preview pane.
    func previewFont(_ family: String, size: CGFloat, sample: Bool = false) -> CTFont? {
        let key = Self.previewKey(family, sample: sample)
        if let d = previewDescriptors[key] { return CTFontCreateWithFontDescriptor(d, size, nil) }
        guard let data = try? Data(contentsOf: Self.previewFile(key)), let d = CTFontManagerCreateFontDescriptorFromData(data as CFData) else { return nil }
        previewDescriptors[key] = d
        return CTFontCreateWithFontDescriptor(d, size, nil)
    }

    /// True when a family's preview could not be fetched this session (offline, or Google has no such subset).
    func previewUnavailable(_ family: String, sample: Bool = false) -> Bool { previewFailed.contains(Self.previewKey(family, sample: sample)) }

    /// Fetches a family's preview subset (six at a time; a failure is not retried this session).
    func requestPreview(_ family: String, sample: Bool = false) {
        let key = Self.previewKey(family, sample: sample)
        guard previewDescriptors[key] == nil, !previewFailed.contains(key), !previewQueue.contains(key),
              !FileManager.default.fileExists(atPath: Self.previewFile(key).path) else { return }
        previewQueue.append(key)
        pumpPreviews()
    }

    private func pumpPreviews() {
        while previewsInFlight < 6, !previewQueue.isEmpty {
            let key = previewQueue.removeLast()   // the row that appeared last is on screen now
            let sample = key.hasSuffix(Self.sampleSuffix)
            let family = sample ? String(key.dropLast(Self.sampleSuffix.count)) : key
            let letters = sample ? family + Self.sampleLetters : family
            previewsInFlight += 1
            Task { @MainActor in
                defer { previewsInFlight -= 1; pumpPreviews() }
                do {
                    let text = letters.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? letters
                    var req = URLRequest(url: URL(string: "\(Self.cssURL)?\(Self.cssQuery(family: family, styles: ["400"]))&text=\(text)")!, timeoutInterval: 20)
                    req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
                    let css = String(decoding: try await Self.fetch(req), as: UTF8.self)
                    guard let face = Self.parseCSS(css).first else { throw FontError.download("no preview") }
                    var r = URLRequest(url: face.url, timeoutInterval: 20); r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
                    let data = try await Self.fetch(r)
                    guard let d = CTFontManagerCreateFontDescriptorFromData(data as CFData) else { throw FontError.download("bad preview") }
                    try? FileManager.default.createDirectory(at: Self.previewDirectory, withIntermediateDirectories: true)
                    try? data.write(to: Self.previewFile(key), options: .atomic)
                    previewDescriptors[key] = d
                    previewTick += 1
                } catch {
                    previewFailed.insert(key)
                    previewTick += 1   // the pane stops waiting
                }
            }
        }
    }

    /// Drops previews that have not been drawn yet (the browser closed).
    func cancelPendingPreviews() { previewQueue.removeAll() }

    // MARK: Picking and resolving

    /// Records a family as recently used (the browser's first section).
    func noteUsed(_ family: String) {
        recent.removeAll { $0.caseInsensitiveCompare(family) == .orderedSame }
        recent.insert(family, at: 0)
        if recent.count > 12 { recent.removeLast(recent.count - 12) }
        if !AppDelegate.isTesting { UserDefaults.standard.set(recent, forKey: "recentFonts") }
    }

    /// The family a name refers to among the fonts on this Mac (any case), or nil.
    func installedFamily(named name: String) -> String? {
        let all = customFiles.flatMap(\.families) + Array(googleInstalled.keys) + NSFontManager.shared.availableFontFamilies
        return all.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Resolves a font argument (a family in any case, or a PostScript name; "default" or "none" = the preset's font).
    /// A Google family that is not downloaded yet is downloaded first.
    func resolve(_ arg: String) async throws -> ToolExecutor.FontChoice {
        let s = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["", "default", "none", "preset"].contains(s.lowercased()) { return .preset }
        if let family = installedFamily(named: s) { return .family(family, face: nil) }
        if let f = TextFont.font(s, size: 12), let face = TextFont.face(of: f), face.postScript.caseInsensitiveCompare(s) == .orderedSame { return .family(face.family, face: face.postScript) }
        if googleFamily(named: s) == nil { await refreshCatalog() }
        if let g = googleFamily(named: s) {
            try await installGoogle(g.family)
            return .family(g.family, face: nil)
        }
        throw FontError.notFound("No font named '\(s)' on this Mac or in Google Fonts.\(suggestion(for: s))\(catalog.isEmpty ? " (The Google Fonts list could not be loaded.)" : "")")
    }

    private func suggestion(for name: String) -> String {
        let q = name.lowercased()
        let pool = catalog.map(\.family) + systemFamilies + customFiles.flatMap(\.families)
        let close = pool.filter { $0.lowercased().contains(q) || q.contains($0.lowercased()) && $0.count > 3 }.prefix(5)
        return close.isEmpty ? "" : " Close matches: \(close.joined(separator: ", "))."
    }

    // MARK: Projects

    /// How a text's chosen font stands on this Mac.
    func status(of t: TextOverlay) -> FontStatus {
        guard t.fontIsMissing, let name = t.fontDisplayName else { return .ok }
        if let g = googleFamily(named: name) {
            if let p = progress[g.family] { return .downloading(family: g.family, progress: p) }
            return .missingGoogle(family: g.family, error: installErrors[g.family])
        }
        return .missingCustom(family: name)
    }

    /// Fonts the project's texts use that are not on this Mac: Google families download now (the picture redraws when
    /// they arrive, through `version`); the others stay missing and the Title card says so. Never an edit.
    func ensureFonts(for project: Project) {
        let missing = Set(project.texts.filter(\.fontIsMissing).compactMap { $0.fontFamily ?? $0.fontName }).subtracting(ensuring)
        guard !missing.isEmpty else { return }
        ensuring.formUnion(missing)
        Task { @MainActor in
            defer { ensuring.subtract(missing) }
            if missing.contains(where: { googleFamily(named: $0) == nil }) { await refreshCatalog() }
            for family in missing.sorted() where googleFamily(named: family) != nil {
                do { try await installGoogle(family); DebugLog.event("font-fetched-for-project", ["family": family]) }
                catch { DebugLog.event("font-fetch-for-project-failed", ["family": family, "error": error.localizedDescription]) }
            }
        }
    }
}
