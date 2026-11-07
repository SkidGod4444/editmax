import XCTest
import AppKit
@testable import EditMax

/// The format pop-up under the Export, Batch Export and Export Timeline panels is AppKit's own pop-up button (its menu
/// opens above the panel), and the item picked maps to the right format past the separator line.
@MainActor
final class PanelAccessoryTests: XCTestCase {
    func testExportFormatPopUpPicksTheRightPresetPastTheSeparator() throws {
        let box = ExportFormatBox()
        var changed: [ExportService.Preset] = []
        box.onChange = { changed.append($0) }
        let view = PanelAccessory.popUp(label: "Format:", items: ExportFormatBox.items, selected: box.preset) { box.preset = $0 }
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? ActionPopUpButton }.first, "an NSPopUpButton, not a SwiftUI menu")
        XCTAssertEqual(button.titleOfSelectedItem, "H.264, 8-bit (plays everywhere; HEVC above 4K)")
        XCTAssertEqual(button.menu?.items.filter(\.isSeparatorItem).count, 1)

        let hq = try XCTUnwrap(button.menu?.items.first { $0.title.hasPrefix("ProRes 422 HQ") })
        button.select(hq)
        _ = button.sendAction(button.action, to: button.target)
        XCTAssertEqual(box.preset, .prores422hq)
        XCTAssertEqual(changed, [.prores422hq], "the panel's name field follows (.mov for ProRes)")
        XCTAssertGreaterThan(view.frame.width, 200)
    }

    func testTimelineFormatPopUp() throws {
        let box = TimelineFormatBox()
        let view = PanelAccessory.popUp(label: "Format:", items: Interchange.Format.allCases.map { .init(title: $0.title, value: $0) }, selected: box.format) { box.format = $0 }
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? ActionPopUpButton }.first)
        XCTAssertEqual(button.numberOfItems, Interchange.Format.allCases.count)
        button.selectItem(withTag: Interchange.Format.allCases.firstIndex(of: .edl)!)
        _ = button.sendAction(button.action, to: button.target)
        XCTAssertEqual(box.format, .edl)
    }
}

/// The full-screen preview covers the menu bar, the Dock and the notch drawer, but not menus and tooltips; and it is
/// left when another window comes forward (`otherWindowBecameKey`), so a dialog never opens hidden behind it.
@MainActor
final class FullScreenLevelTests: XCTestCase {
    func testFullScreenSitsAboveTheMenuBarAndDrawerAndBelowMenus() {
        let fs = FullScreenPreview.level.rawValue
        XCTAssertGreaterThan(fs, NSWindow.Level.mainMenu.rawValue)
        XCTAssertGreaterThan(fs, NSWindow.Level.statusBar.rawValue)
        XCTAssertGreaterThan(fs, NSWindow.Level.dock.rawValue)
        XCTAssertGreaterThan(fs, NSWindow.Level.mainMenu.rawValue + 3, "above the notch drawer")
        XCTAssertLessThan(fs, NSWindow.Level.popUpMenu.rawValue, "menus and tooltips show over it")
        XCTAssertFalse(FullScreenPreview.shared.isShowing)
        FullScreenPreview.shared.otherWindowBecameKey(NSWindow())   // nothing showing: nothing to do
        XCTAssertFalse(FullScreenPreview.shared.isShowing)
    }
}
