import SwiftUI
import AppKit

/// The menu under the EditMax icon in the menu bar (top right of the screen). Shown unless Settings ▸ General turns it
/// off (`showMenuBarIcon`). Every item brings EditMax forward first: the menu bar works while another app is in front.
/// The one exception is "Open the drawer": the notch drawer works over whatever app is in front, and stays there.
struct MenuBarMenu: View {
    @ObservedObject private var library = ProjectLibrary.shared
    @ObservedObject private var mcp = MCPService.shared
    @ObservedObject private var updates = AppUpdater.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("New Project") { front(); newLibraryProject(Templates.list().first!) }
        Button("Home") { front(); HomeWindow.shared.show() }
        Button("Open the drawer") { NotchDrawer.shared.open() }.disabled(!settings.notchDrawer)
        let recent = Array(library.entries.prefix(5))
        if !recent.isEmpty {
            Section("Recent Projects") {
                ForEach(recent) { e in Button(e.name) { front(); library.open(e.url) } }
            }
        }
        Divider()
        Text(mcpLine)
        if let client = mcp.lastClient { Text("Last agent: \(client)") }
        Divider()
        Button("Check for Updates…") { front(); updates.checkForUpdates() }.disabled(!updates.canCheck)
        Button("Settings…") { front(); openSettings() }
        Divider()
        Button("Quit EditMax") { NSApp.terminate(nil) }
    }

    private var mcpLine: String {
        switch mcp.status {
        case .running(let port): return "Agents can connect on port \(port)"
        case .stopped: return "MCP server is off"
        case .failed(let why): return "MCP server failed: \(why)"
        }
    }

    private func front() { NSApp.activate() }
}
