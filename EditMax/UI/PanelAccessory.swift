import AppKit

/// The format pop-up under a Save or Open panel ("Format: H.264, 8-bit…"). It is AppKit's own pop-up button: macOS
/// draws these panels in another process, and a SwiftUI menu in an accessory view opened behind the panel, out of reach.
enum PanelAccessory {
    struct Item<T> {
        let title: String
        let value: T
    }

    /// A label and a pop-up of `items` (`nil` is a separator line); `onChange` gets the value the user picks.
    static func popUp<T: Equatable>(label: String, items: [Item<T>?], selected: T, onChange: @escaping (T) -> Void) -> NSView {
        let values = items.compactMap { $0?.value }
        let button = ActionPopUpButton(frame: .zero, pullsDown: false)
        button.removeAllItems()
        var index = 0
        for item in items {
            guard let item else { button.menu?.addItem(.separator()); continue }
            let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            menuItem.tag = index
            button.menu?.addItem(menuItem)
            index += 1
        }
        if let i = values.firstIndex(of: selected) { button.selectItem(withTag: i) }
        button.onSelect = { tag in if values.indices.contains(tag) { onChange(values[tag]) } }

        let text = NSTextField(labelWithString: label)
        let stack = NSStackView(views: [text, button])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        stack.setFrameSize(stack.fittingSize)
        return stack
    }
}

/// An `NSPopUpButton` that reports the chosen item's tag to a closure.
final class ActionPopUpButton: NSPopUpButton {
    var onSelect: ((Int) -> Void)?

    override init(frame: NSRect, pullsDown: Bool) {
        super.init(frame: frame, pullsDown: pullsDown)
        target = self
        action = #selector(picked)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func picked() { onSelect?(selectedTag()) }
}
