import XCTest
import SwiftUI
import AppKit
import MCP
@testable import EditMax

@MainActor
final class DriverModel: ObservableObject {
    @Published var rows = ["A", "B"]
    @Published var show = true
    @Published var top: CGFloat = 0
    @Published var text = ""
    @Published var choice = "Wide"
    @Published var picked: [String] = []
}

final class MenuTarget: NSObject {
    var fired: [String] = []
    @objc func emoji(_ sender: Any?) { fired.append("emoji") }
    @objc func command(_ sender: Any?) { fired.append("command") }
}

/// The MCP UI driver (`ui_*` tools) against real SwiftUI views in an off-screen window (never shown on a display): its
/// handlers are the view's current ones, its frames are where the view is now and only what a user can see, clicks go
/// to the window that draws the element, keys respect a focused text field, and pickers are set without a menu.
@MainActor
final class UIDriverTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        UIDriver.pinned = nil
        for w in windows { w.parent?.removeChildWindow(w); w.orderOut(nil); w.contentView = nil }
        windows = []
    }

    /// Hosts `view` in a borderless window parked far off every display, and points the driver at it.
    private func host<V: View>(_ view: V, size: CGSize, ordered: Bool = false) -> NSWindow {
        let w = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        if ordered { w.orderFrontRegardless() }
        windows.append(w)
        UIDriver.pinned = w
        pump(w)
        return w
    }
    private func pump(_ w: NSWindow, _ times: Int = 3) {
        for _ in 0..<times { w.contentView?.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    private func rect(_ id: String, _ w: NSWindow) -> CGRect? { UIRegistry.shared.elements(in: w).visible.first { $0.id == id }?.rect }

    // MARK: H5 — handlers are the view's current ones

    func testTapHandlerFollowsReorderedRows() {
        let m = DriverModel()
        struct V: View {
            @ObservedObject var m: DriverModel
            var body: some View {
                VStack { ForEach(Array(m.rows.enumerated()), id: \.element) { i, r in Text(r).uiTap("t.row.\(i).remove") { m.rows.removeAll { $0 == r } } } }
            }
        }
        let w = host(V(m: m), size: CGSize(width: 200, height: 200))
        m.rows = ["B", "A"]; pump(w)   // "move it up"
        UIRegistry.shared.tap("t.row.1.remove", count: 1)?()
        XCTAssertEqual(m.rows, ["B"], "row 1 is A after the reorder; its remove must remove A")
        m.rows = ["B", "C"]; pump(w)
        UIRegistry.shared.tap("t.row.0.remove", count: 1)?()
        XCTAssertEqual(m.rows, ["C"])
    }

    func testHandlersOfRemovedViewsAreGone() {
        let m = DriverModel()
        struct V: View {
            @ObservedObject var m: DriverModel
            var body: some View { VStack { if m.show { Text("x").uiTap("t.gone") { m.picked.append("tap") }.uiDrag("t.gone.drag") { _ in m.picked.append("drag") } } } }
        }
        let w = host(V(m: m), size: CGSize(width: 200, height: 100))
        XCTAssertNotNil(UIRegistry.shared.tap("t.gone", count: 1))
        XCTAssertNotNil(UIRegistry.shared.dragHandler(id: "t.gone.drag", at: .zero, in: w))
        m.show = false; pump(w)
        XCTAssertNil(UIRegistry.shared.tap("t.gone", count: 1), "a removed view's tap handler must not run")
        XCTAssertNil(UIRegistry.shared.dragHandler(id: "t.gone.drag", at: .zero, in: w))
        XCTAssertThrowsError(try UIDriver.target(.string("t.gone"), dx: 0, dy: 0, in: w))
    }

    // MARK: M2 — frames are where the view is now, and only what can be seen

    func testRemovedViewIsNotAnElement() {
        let m = DriverModel()
        m.rows = ["V1", "V2", "A1"]
        struct V: View {
            @ObservedObject var m: DriverModel
            var body: some View {
                ScrollView { LazyVStack(spacing: 0) { ForEach(m.rows, id: \.self) { r in
                    HStack { Text(r).uiFrame("t.header.\(r)"); Image(systemName: "eye").uiFrame("t.header.\(r).hide") }.frame(maxWidth: .infinity).frame(height: 40).uiFrame("t.row.\(r)").transition(.opacity)
                } } }
            }
        }
        let w = host(V(m: m), size: CGSize(width: 200, height: 300))
        XCTAssertNotNil(rect("t.header.V2.hide", w))
        XCTAssertEqual(rect("t.row.A1", w)?.minY ?? -1, 80, accuracy: 0.5)
        withAnimation(.easeInOut(duration: 0.2)) { m.rows = ["V1", "A1"] }
        pump(w, 10)
        let els = UIRegistry.shared.elements(in: w)
        XCTAssertFalse(els.visible.contains { $0.id.hasPrefix("t.header.V2") }, "a removed track's header is not an element")
        XCTAssertFalse(els.hidden.contains { $0.hasPrefix("t.header.V2") })
        XCTAssertEqual(rect("t.row.A1", w)?.minY ?? -1, 40, accuracy: 0.5, "A1 moved up into V2's place")
    }

    func testFrameFollowsAnAnimatedMove() throws {
        let m = DriverModel()
        struct V: View {
            @ObservedObject var m: DriverModel
            var body: some View { HStack(spacing: 0) { Color.clear.frame(width: m.top); VStack { Spacer(); Color.gray.frame(width: 8, height: 30).uiFrame("t.resize"); Spacer() }; Spacer() } }
        }
        let w = host(V(m: m), size: CGSize(width: 400, height: 300))
        m.top = 100; pump(w)
        XCTAssertEqual(rect("t.resize", w)?.minX ?? -1, 100, accuracy: 0.5)
        withAnimation(.easeInOut(duration: 0.1)) { m.top = 200 }
        pump(w, 6)
        XCTAssertEqual(rect("t.resize", w)?.minX ?? -1, 200, accuracy: 0.5, "the frame is where the handle is now, not one drag behind")
        let t = try UIDriver.target(.string("t.resize"), dx: 0, dy: 0, in: w)
        XCTAssertEqual(t.local.x, 204, accuracy: 0.5)
    }

    func testScrolledAwayElementsAreHiddenAndCanBeScrolledIntoView() async throws {
        struct V: View {
            var body: some View {
                VStack(spacing: 0) {
                    ScrollView { VStack(spacing: 0) { ForEach(0..<30, id: \.self) { i in Text("\(i)").frame(maxWidth: .infinity).frame(height: 40).uiFrame("t.scroll.\(i)") } } }.frame(height: 100)
                    Text("below").frame(maxWidth: .infinity).frame(height: 20).uiFrame("t.below")
                    Spacer()
                }
            }
        }
        let w = host(V(), size: CGSize(width: 200, height: 200))
        let layout = try UIDriver.layout(prefix: "t.", in: w)
        let ids = Set(layout.elements.map(\.id))
        XCTAssertTrue(ids.contains("t.scroll.0"))
        XCTAssertFalse(ids.contains("t.scroll.20"), "row 20 is 700 pt below a 100 pt scroll view")
        XCTAssertTrue(layout.hidden?.contains("t.scroll.20") ?? false, "listed as hidden, so an agent knows to scroll")
        // Row 2 is cut by the scroll view at y = 100: only its visible part counts, so (100, 110) is the label below it,
        // not a row a user cannot see (a click on the mixer was once logged as a hidden inspector control).
        XCTAssertEqual(rect("t.scroll.2", w)?.height ?? -1, 20, accuracy: 0.5)
        XCTAssertEqual(UIRegistry.shared.element(at: CGPoint(x: 100, y: 110), in: w), "t.below")
        // A click on it cannot land, and says so instead of claiming success.
        XCTAssertThrowsError(try UIDriver.target(.string("t.scroll.20"), dx: 0, dy: 0, in: w)) { e in
            XCTAssertTrue("\(e.localizedDescription)".contains("ui_scroll"), "\(e)")
        }
        XCTAssertThrowsError(try UIDriver.target(.object(["x": .double(150), "y": .double(500)]), dx: 0, dy: 0, in: w), "outside the window")
        // ui_scroll with just the id brings it into view.
        _ = try await UIDriver.scroll(.string("t.scroll.20"), dx: nil, dy: nil, in: w)
        pump(w)
        let r = try XCTUnwrap(rect("t.scroll.20", w), "scrolled into view")
        XCTAssertTrue(r.minY >= 0 && r.maxY <= 100.5, "\(r)")
        XCTAssertNil(rect("t.scroll.0", w), "row 0 is now above the visible area (it was once reported at y = −546)")
    }

    func testPopoverElementsAreInEditorPointsAndClicksGoToThePopover() throws {
        let root = host(Color.gray.uiFrame("t.editor"), size: CGSize(width: 600, height: 400), ordered: true)
        let pop = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        pop.isReleasedWhenClosed = false
        pop.contentView = NSHostingView(rootView: VStack(spacing: 0) { Color.clear.frame(height: 30); TextField("Search", text: .constant("")).frame(width: 160, height: 22).uiFrame("t.fonts.search"); Spacer() }.frame(width: 200, height: 150))
        // 100 pt in from the editor's left edge and 50 pt down from its top.
        pop.setFrame(CGRect(x: root.frame.minX + 100, y: root.frame.maxY - 50 - 150, width: 200, height: 150), display: false)
        root.addChildWindow(pop, ordered: .above)
        windows.append(pop)
        pump(root); pump(pop)

        let layout = try UIDriver.layout(prefix: "t.", in: root)
        let e = try XCTUnwrap(layout.elements.first { $0.id == "t.fonts.search" })
        XCTAssertEqual(e.window, "child window")
        XCTAssertEqual(e.x, 120, accuracy: 0.5, "the popover's own x 20 plus its 100 pt offset")
        XCTAssertEqual(e.y, 80, accuracy: 0.5, "the popover's own y 30 plus its 50 pt offset")
        let t = try UIDriver.target(.string("t.fonts.search"), dx: 0, dy: 0, in: root)
        XCTAssertTrue(t.window === pop, "the click goes to the popover's window, not the editor's title bar")
        XCTAssertEqual(t.local.x, 100, accuracy: 0.5); XCTAssertEqual(t.local.y, 41, accuracy: 0.5)
        // A bare point over the popover lands in the popover; one beside it lands in the editor.
        XCTAssertTrue(try UIDriver.target(.object(["x": .double(150), "y": .double(100)]), dx: 0, dy: 0, in: root).window === pop)
        XCTAssertTrue(try UIDriver.target(.object(["x": .double(500), "y": .double(100)]), dx: 0, dy: 0, in: root).window === root)
    }

    // MARK: M1 — keys

    func testKeysGoToAFocusedTextFieldNotTheEditor() async throws {
        let m = DriverModel()
        struct V: View {
            @ObservedObject var m: DriverModel
            var body: some View { VStack { TextField("Search", text: $m.text).frame(width: 160) } }
        }
        let w = host(V(m: m), size: CGSize(width: 200, height: 100))
        let field = try XCTUnwrap(allSubviews(w.contentView!).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        XCTAssertTrue(w.makeFirstResponder(field))
        XCTAssertTrue(w.firstResponder is NSTextView, "the field editor has the focus")
        let saved = UIRegistry.shared.keyHandler
        defer { UIRegistry.shared.keyHandler = saved }
        var editorKeys: [String] = []
        UIRegistry.shared.keyHandler = { e in editorKeys.append(e.charactersIgnoringModifiers ?? ""); return true }

        let how = try await UIDriver.key("r", modifiers: [], in: w)
        XCTAssertEqual(how, .text)
        XCTAssertEqual(editorKeys, [], "typing r into the search must not switch the timeline tool")
        _ = try await UIDriver.key("e", modifiers: [], in: w)
        pump(w)
        XCTAssertEqual(m.text, "re")
        _ = try await UIDriver.key("delete", modifiers: [], in: w)
        pump(w)
        XCTAssertEqual(m.text, "r")
    }

    func testEditorKeysWithoutTextFocusAndPlainKeysNeverRunMenus() async throws {
        let w = host(Text("editor"), size: CGSize(width: 200, height: 100))
        let saved = UIRegistry.shared.keyHandler, savedMenu = NSApp.mainMenu
        defer { UIRegistry.shared.keyHandler = saved; NSApp.mainMenu = savedMenu }
        var editorKeys: [String] = []
        UIRegistry.shared.keyHandler = { e in
            let c = e.charactersIgnoringModifiers ?? ""
            guard c == "s" else { return false }
            editorKeys.append(c); return true
        }
        // A menu like Edit ▸ Emoji & Symbols (fn-E) and a ⌘ command.
        let target = MenuTarget()
        let menu = NSMenu(), top = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""), sub = NSMenu(title: "Edit")
        let emoji = NSMenuItem(title: "Emoji & Symbols", action: #selector(MenuTarget.emoji(_:)), keyEquivalent: "e"); emoji.keyEquivalentModifierMask = [.function]; emoji.target = target
        let cmd = NSMenuItem(title: "Command", action: #selector(MenuTarget.command(_:)), keyEquivalent: "k"); cmd.keyEquivalentModifierMask = [.command]; cmd.target = target
        sub.addItem(emoji); sub.addItem(cmd); top.submenu = sub; menu.addItem(top)
        NSApp.mainMenu = menu

        let s = try await UIDriver.key("s", modifiers: [], in: w)
        XCTAssertEqual(s, .editor)
        XCTAssertEqual(editorKeys, ["s"])
        _ = try await UIDriver.key("e", modifiers: [], in: w)
        XCTAssertEqual(target.fired, [], "a plain e never runs a menu item that needs a modifier")
        let k = try await UIDriver.key("k", modifiers: ["command"], in: w)
        XCTAssertEqual(k, .menu)
        XCTAssertEqual(target.fired, ["command"], "⌘ chords still reach the menu bar")
    }

    // MARK: M3 — pop-up menus without a menu

    /// macOS 26's SwiftUI menu button, as CI showed it: an NSPopUpButton whose menu stays empty until mouse-down builds
    /// it. ui_select presses it with the menu caught and chooses from what the press built.
    func testSelectPressesAPopUpButtonThatBuildsItsMenuOnPress() async throws {
        final class Built: @unchecked Sendable { var picked: [String] = [] }
        final class LazyPopUp: NSPopUpButton {
            var built: Built?
            override func mouseDown(with event: NSEvent) {
                if let menu, menu.items.isEmpty {
                    menu.addItem(withTitle: "Add", action: nil, keyEquivalent: "")   // a pull-down's own title
                    for t in ["Title", "Lower third"] {
                        let i = NSMenuItem(title: t, action: #selector(pick(_:)), keyEquivalent: ""); i.target = self; menu.addItem(i)
                    }
                }
                super.mouseDown(with: event)
            }
            @objc func pick(_ i: NSMenuItem) { built?.picked.append(i.title) }
        }
        struct Lazy: NSViewRepresentable {
            let built: Built
            func makeNSView(context: Context) -> LazyPopUp { let b = LazyPopUp(frame: .zero, pullsDown: true); b.built = built; return b }
            func updateNSView(_ v: LazyPopUp, context: Context) {}
        }
        let built = Built()
        let w = host(Lazy(built: built).frame(width: 120, height: 24).uiFrame("t.lazy"), size: CGSize(width: 200, height: 60), ordered: true)
        pump(w)
        let said = try await UIDriver.select(try UIDriver.target(.string("t.lazy"), dx: 0, dy: 0, in: w), option: "Lower third")
        pump(w)
        XCTAssertEqual(built.picked, ["Lower third"], said)
    }

    func testSelectSetsPickersAndMenusWithoutOpeningAMenu() async throws {
        let m = DriverModel()
        struct V: View {
            @ObservedObject var m: DriverModel
            var body: some View {
                VStack(alignment: .leading) {
                    // As the inspector's template picker is written.
                    HStack(spacing: 8) {
                        Picker("Template", selection: $m.choice) { ForEach(["Wide", "Square 1:1", "Vertical 9:16"], id: \.self) { Text($0).tag($0) } }
                            .labelsHidden().pointer().uiFrame("t.template")
                        Spacer(minLength: 0)
                    }.frame(width: 220)
                    Picker("Format", selection: $m.choice) { ForEach(["Wide", "Square 1:1", "Vertical 9:16"], id: \.self) { Text($0).tag($0) } }
                        .pickerStyle(.menu).frame(width: 220).uiFrame("t.format")
                    Picker("", selection: $m.choice) { ForEach(["Wide", "Square 1:1", "Vertical 9:16"], id: \.self) { Text($0).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 260).uiFrame("t.segments")
                    Menu("Add") { Button("Title") { m.picked.append("Title") }; Button("Lower third") { m.picked.append("Lower third") } }
                        .frame(width: 120).uiFrame("t.menu")
                    Button("Plain") { m.picked.append("plain") }.uiFrame("t.plain")
                }
            }
        }
        // On screen as far as the window server goes (far off every display), as the editor window is: a window that
        // was never ordered in gets no events.
        let w = host(V(m: m), size: CGSize(width: 320, height: 220), ordered: true)
        var opened = 0
        let token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { _ in opened += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let list = try await UIDriver.select(try UIDriver.target(.string("t.template"), dx: 0, dy: 0, in: w), option: nil)
        XCTAssertTrue(list.contains("Square 1:1") && list.contains("Vertical 9:16"), list)
        let said = try await UIDriver.select(try UIDriver.target(.string("t.template"), dx: 0, dy: 0, in: w), option: "square")
        XCTAssertEqual(m.choice, "Square 1:1", said)
        XCTAssertNil(MenuCapture.caught, "a caught menu must not outlive its gesture (it cut a later double-click short)")
        pump(w)
        _ = try await UIDriver.select(try UIDriver.target(.string("t.format"), dx: 0, dy: 0, in: w), option: "Wide")
        XCTAssertEqual(m.choice, "Wide")
        pump(w)
        _ = try await UIDriver.select(try UIDriver.target(.string("t.segments"), dx: 0, dy: 0, in: w), option: "Vertical 9:16")
        XCTAssertEqual(m.choice, "Vertical 9:16")
        pump(w)
        _ = try await UIDriver.select(try UIDriver.target(.string("t.menu"), dx: 0, dy: 0, in: w), option: "Lower third")
        XCTAssertEqual(m.picked, ["Lower third"])
        XCTAssertEqual(opened, 0, "no menu was opened")
        do { _ = try await UIDriver.select(try UIDriver.target(.string("t.template"), dx: 0, dy: 0, in: w), option: "Cinema"); XCTFail("no such option") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Vertical 9:16"), "the error lists the options: \(error)") }
        do { _ = try await UIDriver.select(try UIDriver.target(.string("t.plain"), dx: 0, dy: 0, in: w), option: "x"); XCTFail("a button is not a pop-up") }
        catch { XCTAssertTrue(error.localizedDescription.contains("ui_click"), "\(error)") }
        pump(w)
        XCTAssertEqual(m.picked, ["Lower third"], "ui_select on a plain button does not press it")

        // ui_click on a picker in the background refuses and points to ui_select (the window is not key: EditMax is in
        // the background as far as this window goes), without opening the menu or changing the value.
        do { _ = try await UIDriver.click(try UIDriver.target(.string("t.template"), dx: 0, dy: 0, in: w), count: 1); XCTFail("the menu would open") }
        catch { XCTAssertTrue(error.localizedDescription.contains("ui_select") && error.localizedDescription.contains("Square 1:1"), "\(error)") }
        XCTAssertEqual(m.choice, "Vertical 9:16")
        XCTAssertEqual(opened, 0)
        // A plain button still takes the click.
        let how = try await UIDriver.click(try UIDriver.target(.string("t.plain"), dx: 0, dy: 0, in: w), count: 1)
        if case .events = how {} else { XCTFail("\(how)") }
        pump(w)
        XCTAssertEqual(m.picked, ["Lower third", "plain"])
    }

    func testOptionMatching() {
        let titles = ["YouTube 16:9 1080p", "Shorts / Reels 9:16", "Square 1:1"]
        XCTAssertEqual(UIDriver.match("square 1:1", in: titles), 2)
        XCTAssertEqual(UIDriver.match("shorts", in: titles), 1, "a unique start is enough")
        XCTAssertEqual(UIDriver.match("9:16", in: titles), 1, "a unique part is enough")
        XCTAssertNil(UIDriver.match("16", in: titles), "ambiguous: 16:9 and 9:16")
        XCTAssertNil(UIDriver.match("cinema", in: titles))
    }

    // MARK: L12 — screenshots

    func testFallbackReasonIsTheRealOne() {
        XCTAssertTrue(UIDriver.CaptureFailure.notGranted.reason.contains("not granted"))
        for f in [UIDriver.CaptureFailure.failed("audio/video capture failure"), .offScreen, .notListed] {
            XCTAssertFalse(f.reason.contains("not granted"), "only a missing permission is reported as one: \(f.reason)")
        }
        XCTAssertTrue(UIDriver.CaptureFailure.failed("audio/video capture failure").reason.contains("audio/video capture failure"))
    }

    private func allSubviews(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(allSubviews) }
}
