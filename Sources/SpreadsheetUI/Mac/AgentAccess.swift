#if os(macOS)
import SwiftUI
import AppKit

/// Settings ▸ Agents: lets AI agents (Claude Code, Claude Desktop, any MCP
/// client) read and edit the open spreadsheets through a local MCP server
/// (MCPHTTPServer + MCPTools). Off until the user turns it on; the address
/// and token are what the user gives the agent.
@MainActor
final class AgentAccess: ObservableObject {
    static let shared = AgentAccess()

    static let defaultPort: UInt16 = 52700
    private static let enabledKey = "AgentAccessEnabled"
    private static let portKey = "AgentAccessPort"
    private static let tokenKey = "AgentAccessToken"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            restart()
        }
    }
    @Published var port: UInt16 {
        didSet {
            UserDefaults.standard.set(Int(port), forKey: Self.portKey)
            if oldValue != port { restart() }
        }
    }
    @Published private(set) var token: String
    @Published private(set) var state: MCPHTTPServer.State = .stopped

    private var server: MCPHTTPServer?
    private lazy var endpoint: MCPEndpoint = {
        let tools = MCPTools(openDocuments: Self.openDocuments)
        tools.windows = MCPTools.WindowActions(
            window: { DocumentWindowHook.window(showing: $0) },
            didSave: { RecentFilesManager.shared.record($0) },
            close: { document in
                guard let window = DocumentWindowHook.window(showing: document) else { return false }
                // Through the close button's path (it would still ask if
                // something changed meanwhile), a moment later: closing the
                // last window quits, and the reply must get out first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { window.performClose(nil) }
                return true
            })
        return MCPEndpoint(tools: tools)
    }()

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        let saved = defaults.integer(forKey: Self.portKey)
        port = (1024...65535).contains(saved) ? UInt16(saved) : Self.defaultPort
        if let saved = defaults.string(forKey: Self.tokenKey), !saved.isEmpty {
            token = saved
        } else {
            token = Self.newToken()
            defaults.set(token, forKey: Self.tokenKey)
        }
    }

    /// At launch: listen if the user left it on.
    func startIfEnabled() {
        if isEnabled { restart() }
    }

    private func restart() {
        server?.stop()
        server = nil
        guard isEnabled else {
            state = .stopped
            return
        }
        let server = MCPHTTPServer(port: port, token: token,
                                   handler: { [weak self] body in await self?.endpoint.handle(body) },
                                   onStateChange: { [weak self] state in
                                       guard let self, self.server != nil else { return }
                                       self.state = state
                                   })
        self.server = server
        server.start()
    }

    /// A new token: agents set up with the old one are refused.
    func resetToken() {
        token = Self.newToken()
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        restart()
    }

    static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }

    var url: String { "http://127.0.0.1:\(port)\(MCPHTTPServer.path)" }

    /// Claude Code's command for adding the server.
    var claudeCodeCommand: String {
        "claude mcp add --transport http simplespread \(url) --header \"Authorization: Bearer \(token)\""
    }

    /// The `mcpServers` entry other clients take (Claude Desktop via
    /// mcp-remote, Cursor, VS Code, …).
    var jsonConfig: String {
        """
        {
          "mcpServers": {
            "simplespread": {
              "type": "http",
              "url": "\(url)",
              "headers": { "Authorization": "Bearer \(token)" }
            }
          }
        }
        """
    }

    /// The documents in open windows, front-most first.
    static func openDocuments() -> [MCPTools.OpenDocument] {
        DocumentWindowHook.windowDocuments().compactMap { document in
            DocumentStore.shared.id(of: document).map { MCPTools.OpenDocument(id: $0, document: document) }
        }
    }
}

struct AgentSettingsView: View {
    @ObservedObject var access = AgentAccess.shared
    @State private var portText = ""
    /// The status line says "Copied" for a moment after a click copies the URL.
    @State private var urlCopied = false

    var body: some View {
        Form {
            Section {
                Toggle("Allow AI agents to read and edit open spreadsheets", isOn: $access.isEnabled)
                Text("Agents such as Claude Code connect over MCP and edit the documents in your windows while you watch. "
                     + "Each change is one step you can undo. Agents can save and close only "
                     + "documents that won’t lose anything by it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Status") { status }
            }
            Section("Connect an agent") {
                LabeledContent("Port") {
                    TextField("Port", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(applyPort)
                        .labelsHidden()
                }
                CopyableField(title: "Claude Code", text: access.claudeCodeCommand,
                              note: "Run this in Terminal, then start Claude Code.")
                CopyableField(title: "Other MCP clients", text: access.jsonConfig, lines: 9)
                HStack {
                    Text("The token in these lets an agent in. Resetting it disconnects every agent set up with the old one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Reset Token") { access.resetToken() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .onAppear { portText = String(access.port) }
    }

    @ViewBuilder private var status: some View {
        switch access.state {
        case .listening:
            Button {
                copyToPasteboard(access.url)
                urlCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { urlCopied = false }
            } label: {
                Label(urlCopied ? "Copied \(access.url)" : "Listening at \(access.url)", systemImage: "circle.fill")
                    .foregroundStyle(.green)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click to copy the URL")
        case .starting:
            Text("Starting…")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .stopped:
            Text("Off").foregroundStyle(.secondary)
        }
    }

    private func applyPort() {
        if let value = UInt16(portText.trimmingCharacters(in: .whitespaces)), value >= 1024 {
            access.port = value
        }
        portText = String(access.port)
    }
}

@MainActor
private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Read-only, selectable text with a Copy button.
private struct CopyableField: View {
    let title: String
    let text: String
    var note: String?
    var lines = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button("Copy") { copyToPasteboard(text) }
            }
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(lines...lines + 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
            if let note {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct AppSettingsView: View {
    var body: some View {
        TabView {
            AgentSettingsView()
                .tabItem { Label("Agents", systemImage: "sparkles") }
        }
    }
}
#endif
