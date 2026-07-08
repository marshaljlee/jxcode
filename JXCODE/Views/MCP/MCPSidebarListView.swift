import SwiftUI
import JXCODECore
import os

@Observable
class MCPConfigStore {
    static let shared = MCPConfigStore()
    private let logger = Logger(subsystem: "com.claudework", category: "MCPConfigStore")
    
    var servers: [MCPServer] = []
    var selectedServerId: String? = nil

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/mcp.json")
    }

    func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configURL.path) else {
            servers = []
            return
        }

        do {
            let data = try Data(contentsOf: configURL)
            let config = try JSONDecoder().decode(MCPConfig.self, from: data)
            servers = config.mcpServers.map { name, srv in
                MCPServer(
                    name: name,
                    command: srv.command,
                    args: srv.args,
                    env: srv.env
                )
            }.sorted { $0.name < $1.name }
            logger.info("Loaded \(self.servers.count) MCP servers from ~/.claude/mcp.json")
        } catch {
            logger.error("Failed to load mcp.json: \(error.localizedDescription)")
            servers = []
        }
    }

    func save() {
        var mcpServers: [String: MCPServerConfig] = [:]
        for srv in servers {
            mcpServers[srv.name] = MCPServerConfig(
                command: srv.command,
                args: srv.args,
                env: srv.env
            )
        }

        let config = MCPConfig(mcpServers: mcpServers)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(config)
            
            // Create directory if not exists
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            
            try data.write(to: configURL, options: .atomic)
            logger.info("Saved MCP config to ~/.claude/mcp.json")
        } catch {
            logger.error("Failed to save mcp.json: \(error.localizedDescription)")
        }
    }
}

struct MCPServer: Identifiable, Codable, Hashable {
    var id: String { name }
    let name: String
    var command: String
    var args: [String]
    var env: [String: String]?
}

struct MCPConfig: Codable {
    var mcpServers: [String: MCPServerConfig]
}

struct MCPServerConfig: Codable {
    var command: String
    var args: [String]
    var env: [String: String]?
}

// MARK: - Sidebar View

struct MCPSidebarListView: View {
    @State private var store = MCPConfigStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MCP Servers")
                .font(.system(size: ClaudeTheme.size(11), weight: .bold))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .textCase(.uppercase)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if store.servers.isEmpty {
                        Text("No servers configured.")
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(store.servers) { server in
                            serverRow(for: server)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            
            Spacer()
        }
        .onAppear {
            store.load()
        }
    }

    private func serverRow(for server: MCPServer) -> some View {
        let isSelected = store.selectedServerId == server.id
        
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                store.selectedServerId = server.id
            }
        } label: {
            HStack(spacing: 8) {
                // Status dot (mocked green/active)
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                
                Text(server.name)
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    .foregroundStyle(isSelected ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
                    .lineLimit(1)
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(isSelected ? ClaudeTheme.surfaceSecondary : Color.clear)
        }
        .buttonStyle(.plain)
    }
}
