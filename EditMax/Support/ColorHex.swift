import SwiftUI
import AppKit

extension Color {
    /// "#RRGGBB" or "#RRGGBBAA" → Color; anything else is white.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces); if s.hasPrefix("#") { s.removeFirst() }
        guard let v = UInt64(s, radix: 16), s.count == 6 || s.count == 8 else { self = .white; return }
        let a = s.count == 8 ? Double(v & 0xFF) / 255 : 1
        let rgb = s.count == 8 ? v >> 8 : v
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255, opacity: a)
    }
    /// "#RRGGBB" in sRGB, alpha dropped.
    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}
