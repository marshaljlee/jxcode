import SwiftUI
import JXCODECore

struct MCPManagerView: View {
    @State private var store = MCPConfigStore.shared
    
    @State private var command = ""
    @State private var argsString = ""
    @State private var envString = ""
    
    // Testing state
    @State private var testStatus = "idle" // idle, testing, success, failed
    @State private var testLog = ""
    @State private var showingAddAlert = false
    @State private var newServerName = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model Context Protocol (MCP) Manager")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                    Text("Configure external tool servers for Claude Code")
                        .font(.subheadline)
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                
                Spacer()
                
                Button("Add Server") {
                    newServerName = ""
                    showingAddAlert = true
                }
                .buttonStyle(.borderedProminent)
                .tint(ClaudeTheme.accent)
            }
            .padding(20)
            .background(ClaudeTheme.surfaceElevated)

            ClaudeThemeDivider()

            if let selectionId = store.selectedServerId,
               let server = store.servers.first(where: { $0.id == selectionId }) {
                serverEditor(for: server)
            } else {
                noSelectionPlaceholder
            }
        }
        .background(ClaudeTheme.background)
        .onAppear {
            store.load()
            initializeForm()
        }
        .onChange(of: store.selectedServerId) { _, _ in
            initializeForm()
        }
        .alert("Add MCP Server", isPresented: $showingAddAlert) {
            TextField("Server Name (e.g. github)", text: $newServerName)
            Button("Add") {
                guard !newServerName.isEmpty else { return }
                let newSrv = MCPServer(name: newServerName, command: "", args: [])
                store.servers.append(newSrv)
                store.save()
                store.selectedServerId = newSrv.id
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func serverEditor(for server: MCPServer) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Settings Form
                VStack(alignment: .leading, spacing: 12) {
                    Text("Server Configuration: \(server.name)")
                        .font(.headline)
                        .foregroundStyle(ClaudeTheme.textPrimary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Executable / Command Path")
                            .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                        TextField("e.g. npx or node or python3", text: $command)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Arguments (one per line)")
                            .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                        TextEditor(text: $argsString)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 80)
                            .border(ClaudeTheme.surfaceSecondary, width: 1)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Environment Variables (KEY=VALUE, one per line)")
                            .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                        TextEditor(text: $envString)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 80)
                            .border(ClaudeTheme.surfaceSecondary, width: 1)
                    }

                    HStack {
                        Button("Delete Server", role: .destructive) {
                            store.servers.removeAll { $0.id == server.id }
                            store.save()
                            store.selectedServerId = nil
                        }
                        .buttonStyle(.bordered)
                        
                        Spacer()

                        Button("Save Config") {
                            saveForm(for: server)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ClaudeTheme.accent)
                    }
                    .padding(.top, 8)
                }
                .padding(16)
                .background(ClaudeTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))

                // Test Connection Panel
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Connection Diagnostic")
                            .font(.headline)
                            .foregroundStyle(ClaudeTheme.textPrimary)
                        Spacer()
                        
                        Button("Test Connection") {
                            Task { await runDiagnostic(for: server) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(command.isEmpty)
                    }

                    if testStatus != "idle" {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Circle()
                                    .fill(statusColor)
                                    .frame(width: 8, height: 8)
                                Text(statusText)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(ClaudeTheme.textPrimary)
                            }

                            ScrollView {
                                Text(testLog)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .frame(height: 120)
                            .background(Color.black.opacity(0.15))
                            .border(ClaudeTheme.surfaceSecondary, width: 1)
                        }
                        .padding(12)
                        .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(16)
                .background(ClaudeTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(20)
        }
    }

    private func initializeForm() {
        testStatus = "idle"
        testLog = ""
        
        guard let selectionId = store.selectedServerId,
              let server = store.servers.first(where: { $0.id == selectionId }) else { return }
        
        command = server.command
        argsString = server.args.joined(separator: "\n")
        
        var envLines: [String] = []
        if let env = server.env {
            for (k, v) in env {
                envLines.append("\(k)=\(v)")
            }
        }
        envString = envLines.joined(separator: "\n")
    }

    private func saveForm(for server: MCPServer) {
        let args = argsString.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        var env: [String: String] = [:]
        let envLines = envString.components(separatedBy: .newlines)
        for line in envLines {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                let k = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let v = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !k.isEmpty {
                    env[k] = v
                }
            }
        }

        if let idx = store.servers.firstIndex(where: { $0.id == server.id }) {
            store.servers[idx].command = command
            store.servers[idx].args = args
            store.servers[idx].env = env.isEmpty ? nil : env
            store.save()
        }
    }

    // MARK: - Diagnostic Spawner

    private func runDiagnostic(for server: MCPServer) async {
        testStatus = "testing"
        testLog = "Launching MCP Server Process: \(server.command)\nArgs: \(server.args)\n"
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: server.command.isEmpty ? "/usr/bin/env" : server.command)
        
        // If command path is relative (e.g. npx/node), fallback search
        if !server.command.hasPrefix("/") {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            var newArgs = [server.command]
            newArgs.append(contentsOf: server.args)
            proc.arguments = newArgs
        } else {
            proc.arguments = server.args
        }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        if let serverEnv = server.env {
            for (k, v) in serverEnv {
                env[k] = v
            }
        }
        proc.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe

        do {
            try proc.run()
            testLog += "Process started successfully (PID: \(proc.processIdentifier))\nSending initialize JSON-RPC...\n"
            
            let payload = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"JXCODE\",\"version\":\"1.0\"}}}\n"
            if let payloadData = payload.data(using: .utf8) {
                try stdinPipe.fileHandleForWriting.write(contentsOf: payloadData)
            }
            
            // Read response with timeout
            let readTask = Task {
                let lines = stdoutPipe.fileHandleForReading.bytes.lines
                for try await line in lines {
                    await MainActor.run {
                        testLog += "Received: \(line)\n"
                    }
                    if line.contains("protocolVersion") || line.contains("capabilities") {
                        return true
                    }
                }
                return false
            }
            
            // Wait up to 2 seconds
            let success = try await Task.detached {
                let start = Date()
                while Date().timeIntervalSince(start) < 2.0 {
                    if readTask.isCancelled { return false }
                    if await readTask.result != nil {
                        return try await readTask.value
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                readTask.cancel()
                return false
            }.value
            
            proc.terminate()
            
            if success {
                testStatus = "success"
                testLog += "\n=== Handshake Completed: SUCCESS ==="
            } else {
                testStatus = "failed"
                testLog += "\n=== Handshake Timeout: FAILED ==="
            }
        } catch {
            testStatus = "failed"
            testLog += "\n=== Error starting process: \(error.localizedDescription) ==="
        }
    }

    private var statusColor: Color {
        switch testStatus {
        case "testing": return .blue
        case "success": return .green
        case "failed": return .red
        default: return .gray
        }
    }

    private var statusText: String {
        switch testStatus {
        case "testing": return "Testing Handshake..."
        case "success": return "Success"
        case "failed": return "Failed"
        default: return ""
        }
    }

    private var noSelectionPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: ClaudeTheme.size(48)))
                .foregroundStyle(ClaudeTheme.textTertiary)

            Text("MCP Servers Panel")
                .font(.title2.weight(.semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)

            Text("Select a configured server or add a new one from the sidebar.")
                .font(.subheadline)
                .foregroundStyle(ClaudeTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
