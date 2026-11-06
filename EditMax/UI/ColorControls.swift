import SwiftUI

/// A slider row in the color sections, styled like the clip inspector's own: label, slider, value (double-click resets).
/// Ids: `inspector.color.<id>.slider` and `inspector.color.<id>.reset`.
struct ColorSliderRow: View {
    let title: String
    let id: String
    let value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%+.2f", $0) }
    var reset: Double = 0
    let set: (Double) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title).inspectorLabel()
            Slider(value: .init(get: { min(range.upperBound, max(range.lowerBound, value)) }, set: set), in: range).controlSize(.small).pointer().uiFrame("inspector.color.\(id).slider")
            Text(format(value)).inspectorValue()
                .onTapGesture(count: 2) { set(reset) }.help("Double-click to reset").pointer()
                .uiFrame("inspector.color.\(id).reset").uiTap("inspector.color.\(id).reset", count: 2) { set(reset) }
        }
    }
}

/// What a color section edits: the clip's primary grade or one grade layer, with the ids its controls register.
struct ColorTargetInfo {
    let target: ToolExecutor.GradeTarget
    /// Prefix for control ids under `inspector.color.`: "" for the primary grade, "layer.<n>." for layer n (1-based).
    let idPrefix: String
    static let primary = ColorTargetInfo(target: .primary, idPrefix: "")
}

extension ClipColor {
    var wheelsOrIdentity: ColorWheels { wheels ?? ColorWheels() }
    var curvesOrIdentity: ColorCurves { curves ?? ColorCurves() }
}
