import Foundation

/// One-line description of what changed between two project states, for the History tab and list_history.
enum ProjectDiff {
    static func summary(from a: Project, to b: Project) -> String {
        var parts: [String] = []
        if a.settings != b.settings { parts.append("project settings") }
        let added = b.assets.count - a.assets.count
        if added > 0 { parts.append("\(added) media imported") } else if added < 0 { parts.append("\(-added) media removed") }
        let ac = Dictionary(uniqueKeysWithValues: a.tracks.flatMap { t in t.clips.map { ($0.id, ($0, t.name)) } })
        let bc = Dictionary(uniqueKeysWithValues: b.tracks.flatMap { t in t.clips.map { ($0.id, ($0, t.name)) } })
        for (id, (clip, track)) in bc where ac[id] == nil { parts.append("\(clip.name) added on \(track) at \(tc(clip.start))") }
        for (id, (clip, _)) in ac where bc[id] == nil { parts.append("\(clip.name) removed") }
        for (id, (x, tx)) in ac {
            guard let (y, ty) = bc[id], x != y else { continue }
            var c: [String] = []
            if tx != ty { c.append("moved to \(ty)") }
            if abs(x.start - y.start) > 1e-6 { c.append("moved \(tc(x.start)) → \(tc(y.start))") }
            if abs(x.duration - y.duration) > 1e-6 || abs(x.sourceIn - y.sourceIn) > 1e-6 { c.append("trimmed to \(fmt(y.duration)) s") }
            if abs(x.speed - y.speed) > 1e-6 { c.append("speed \(fmt(y.speed))×") }
            if abs(x.volume - y.volume) > 1e-6 { c.append("volume \(fmt(y.volume))") }
            if abs(x.opacity - y.opacity) > 1e-6 { c.append("opacity \(fmt(y.opacity))") }
            if x.color != y.color { c.append("color: " + fields(x.color, y.color)) }
            if x.transform != y.transform { c.append("transform: " + fields(x.transform, y.transform)) }
            if x.audio != y.audio { c.append("audio: " + fields(x.audio, y.audio)) }
            if x.fadeIn != y.fadeIn || x.fadeOut != y.fadeOut { c.append("fades \(fmt(y.fadeIn))/\(fmt(y.fadeOut)) s") }
            if x.transitionIn != y.transitionIn { c.append(y.transitionIn.map { "transition \($0.kind.rawValue) \(fmt($0.duration)) s" } ?? "transition removed") }
            if x.animations != y.animations { c.append("keyframes") }
            if x.multicam != y.multicam { c.append("multicam") }
            if x.stabilization != y.stabilization { c.append(y.stabilization.map { "stabilized (zoom \(fmt($0.zoom))×)" } ?? "stabilization removed") }
            if x.grades != y.grades { c.append("grade layers (\(y.grades.count))") }
            if x.finish != y.finish { c.append(y.finish.map { "finishing: " + fields(x.finish ?? ClipFinish(), $0) } ?? "finishing removed") }
            if c.isEmpty { c.append("changed") }
            parts.append("\(y.name): " + c.joined(separator: ", "))
        }
        if a.tracks.count != b.tracks.count { parts.append("tracks \(a.tracks.count) → \(b.tracks.count)") }
        else if zip(a.tracks, b.tracks).contains(where: { $0.isMuted != $1.isMuted || $0.isHidden != $1.isHidden || $0.duck != $1.duck || $0.name != $1.name }) { parts.append("track settings") }
        let ta = b.texts.count - a.texts.count
        if ta > 0 { parts.append("\(ta) text\(ta == 1 ? "" : "s") added") } else if ta < 0 { parts.append("\(-ta) text\(ta == -1 ? "" : "s") removed") }
        else if a.texts != b.texts { parts.append("text changed") }
        if a.markers != b.markers { parts.append("markers") }
        if a.sequences != b.sequences { parts.append("sequences") }
        if parts.isEmpty, a != b { parts.append("project reset") }
        var s = parts.joined(separator: "; ")
        if s.count > 220 { s = String(s.prefix(217)) + "…" }
        return s
    }

    /// "contrast 1 → 1.2, lut Cool Blue" for two values of the same struct, by field name.
    static func fields<T>(_ a: T, _ b: T) -> String {
        let ma = Dictionary(uniqueKeysWithValues: Mirror(reflecting: a).children.compactMap { c in c.label.map { ($0, c.value) } })
        var out: [String] = []
        for c in Mirror(reflecting: b).children {
            guard let label = c.label, let old = ma[label], !same(old, c.value) else { continue }
            let name = label == "inputLut" ? "input LUT" : label == "lutMix" ? "look mix" : label == "lut" ? "look" : label == "highPass" ? "high-pass" : label
            out.append("\(name) \(show(old)) → \(show(c.value))")
        }
        return out.isEmpty ? "changed" : out.joined(separator: ", ")
    }
    private static func same(_ a: Any, _ b: Any) -> Bool { show(a) == show(b) }
    private static func show(_ v: Any) -> String {
        if let d = v as? Double { return fmt(d) }
        if let s = v as? String { return s.isEmpty ? "none" : (s.hasSuffix(".cube") ? (s as NSString).lastPathComponent : s) }
        if let o = v as? Optional<String> { return o.map { show($0) } ?? "none" }
        if let o = v as? Optional<Double> { return o.map { show($0) } ?? "none" }
        if let b = v as? Bool { return b ? "on" : "off" }
        let m = Mirror(reflecting: v)
        if m.displayStyle == .optional { return m.children.first.map { show($0.value) } ?? "none" }
        return String(describing: v)
    }
    static func fmt(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) }
    static func tc(_ t: Double) -> String { String(format: "%d:%05.2f", Int(t) / 60, t - Double(Int(t) / 60 * 60)) }
}

/// Decoded change lines per history entry, so the History tab does not re-decode snapshots on every redraw.
@MainActor final class VersionDiffCache { static let shared = VersionDiffCache(); var text: [UUID: String] = [:] }
