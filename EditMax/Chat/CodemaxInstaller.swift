import Foundation
import CryptoKit

/// Puts the bundled codemax on the user's Mac at first launch so `codemax` also works in their terminal.
/// EditMax itself always runs the bundled copy. A codemax the user installed themselves is never replaced.
@MainActor
final class CodemaxInstaller: ObservableObject {
    static let shared = CodemaxInstaller()

    struct Status {
        var bundledVersion: String?
        var installedPath: String?
        var linkPath: String?
        var existingOnPath: String?
        var message = "Checking the bundled agent runtime…"
    }
    @Published var status = Status()

    nonisolated static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("EditMax")
    }
    nonisolated static var installedBinary: URL { supportDirectory.appendingPathComponent("bin/codemax") }
    nonisolated static var linkPath: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codemax") }

    func ensureInstalled() {
        let bundled = CodemaxRunner.bundledBinary
        Task.detached(priority: .utility) {
            let result = Self.install(bundled: bundled)
            DebugLog.event("codemax-install", ["bundled": result.bundledVersion ?? "", "installed": result.installedPath ?? "", "link": result.linkPath ?? "", "existing": result.existingOnPath ?? "", "message": result.message])
            await MainActor.run { self.status = result }
        }
    }

    nonisolated private static func install(bundled: URL?) -> Status {
        var st = Status()
        var updatedNote = ""
        guard let bundled else {
            st.message = "This build of EditMax has no bundled codemax. Run scripts/vendor-codemax.sh and rebuild."
            return st
        }
        let fm = FileManager.default
        st.bundledVersion = version(of: bundled)
        let dest = installedBinary
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            // An update newer than this build's codemax stays; otherwise the bundled build is the floor.
            let state = CodemaxUpdater.loadState()
            let keepUpdated = state.active == "updated" && state.updatedVersion.map { CodemaxUpdater.isNewer($0, st.bundledVersion ?? "0.0.0") } == true && fm.isExecutableFile(atPath: dest.path)
            if keepUpdated {
                updatedNote = " (updated to \(state.updatedVersion ?? ""))"
            } else if state.active == "updated" {
                var s = state; s.active = "bundled"; s.updatedVersion = nil; CodemaxUpdater.saveState(s)
            }
            // Same version string can be a newer build: compare the bytes, not the version.
            if !keepUpdated, digest(of: dest) != digest(of: bundled) {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: bundled, to: dest)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            }
            st.installedPath = dest.path
        } catch {
            st.message = "Could not install codemax: \(error.localizedDescription)"
            return st
        }
        // Terminal use: a link in ~/.local/bin, only when the user has no codemax of their own.
        let link = linkPath
        let linkTarget = try? fm.destinationOfSymbolicLink(atPath: link.path)
        let ours = linkTarget == dest.path
        let existing = whichOnLoginShell("codemax")
        if let existing, existing != link.path, !ours {
            st.existingOnPath = existing
            st.message = "codemax \(st.bundledVersion ?? "")\(updatedNote) is bundled. Your own codemax at \(existing) is left alone."
            return st
        }
        do {
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !ours {
                if linkTarget != nil || fm.fileExists(atPath: link.path) { try fm.removeItem(at: link) }
                try fm.createSymbolicLink(at: link, withDestinationURL: dest)
            }
            st.linkPath = link.path
            st.message = existing != nil
                ? "codemax \(st.bundledVersion ?? "")\(updatedNote) is installed and on your PATH (~/.local/bin/codemax)."
                : "codemax \(st.bundledVersion ?? "")\(updatedNote) is installed at ~/.local/bin/codemax. Add ~/.local/bin to your PATH to use it in Terminal."
        } catch {
            st.message = "codemax is installed, but ~/.local/bin/codemax could not be linked: \(error.localizedDescription)"
        }
        return st
    }

    nonisolated private static func digest(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func version(of bin: URL) -> String? {
        guard FileManager.default.isExecutableFile(atPath: bin.path) else { return nil }
        let p = Process(); p.executableURL = bin; p.arguments = ["--version"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment; env["PATH"] = CodemaxRunner.spawnPATH; p.environment = env
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !s.isEmpty ? s : nil
    }

    nonisolated private static func whichOnLoginShell(_ name: String) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-lc", "command -v \(name)"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
