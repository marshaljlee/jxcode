import SwiftUI
import JXCODECore

struct ClaudeMdSettingsTab: View {
    @Environment(WindowState.self) private var windowState
    @State private var content: String = ""
    @State private var hasFile: Bool = false
    
    private var claudeMdPath: String? {
        guard let projectPath = windowState.selectedProject?.path else { return nil }
        return projectPath + "/CLAUDE.md"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("System Prompt Guidelines (CLAUDE.md)")
                    .font(.system(size: 13, weight: .bold))
                if let project = windowState.selectedProject {
                    Text("Configure custom instructions for \(project.name). These rules are appended to the system prompt of Claude Code.")
                        .font(.system(size: 11))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                }
            }
            
            Divider()
            
            if let path = claudeMdPath {
                if hasFile {
                    TextEditor(text: $content)
                        .font(.custom("JetBrains Mono NL", size: 11))
                        .padding(8)
                        .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(ClaudeTheme.border, lineWidth: 1)
                        )
                        .onChange(of: content) { _, newContent in
                            saveFile(path: path, text: newContent)
                        }
                } else {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "doc.text.badge.plus")
                            .font(.system(size: 32))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                        Text("No CLAUDE.md rules defined for this project.")
                            .font(.system(size: 11))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                        
                        Button {
                            initializeClaudeMd(path: path)
                        } label: {
                            Text("Create CLAUDE.md File")
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(ClaudeTheme.accent, in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 32))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Text("Select a project in the sidebar first to manage its CLAUDE.md rules.")
                        .font(.system(size: 11))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            loadFile()
        }
    }
    
    // MARK: - Disk Sync
    private func loadFile() {
        guard let path = claudeMdPath else { return }
        if FileManager.default.fileExists(atPath: path) {
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                self.content = text
                self.hasFile = true
            }
        } else {
            self.hasFile = false
        }
    }
    
    private func saveFile(path: String, text: String) {
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
    
    private func initializeClaudeMd(path: String) {
        let template = """
# CLAUDE.md

## Build Commands
- Build project: swift build
- Test project: swift test

## Code Style & Architecture
- Follow standard Swift conventions.
- Keep components small, decoupled, and testable.
- Document key design decisions.
"""
        saveFile(path: path, text: template)
        self.content = template
        self.hasFile = true
    }
}
