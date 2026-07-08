import SwiftUI
import JXCODECore

// MARK: - Paseo Projects Tab

public struct PaseoProjectsTab: View {
    @Environment(AppState.self) private var appState
    @State private var recentProjects: [URL] = []
    @State private var showImporter = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Project Manager")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                Spacer()
                Button("Import Project") { showImporter = true }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ClaudeThemeDivider()

            if recentProjects.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No recent projects")
                        .font(.system(size: ClaudeTheme.size(12)))
                        .foregroundStyle(.secondary)
                    Text("Import a project to get started")
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(recentProjects, id: \.self) { url in
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(ClaudeTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent)
                                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                                Text(url.path.replacingOccurrences(of: "/" + url.lastPathComponent, with: ""))
                                    .font(.system(size: ClaudeTheme.size(10)))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: ClaudeTheme.size(10)))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture { openProject(url) }
                    }
                }
                .listStyle(.plain)
            }
        }
        .onAppear(perform: loadRecentProjects)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.directory]) { result in
            if case .success(let url) = result {
                addProject(url)
            }
        }
    }

    private func loadRecentProjects() {
        guard let data = UserDefaults.standard.data(forKey: "jxcode.recentProjects"),
              let urls = try? JSONDecoder().decode([Data].self, from: data) else { return }
        recentProjects = urls.compactMap { try? NSItemProvider(item: $0 as NSSecureCoding?)?.registeredTypeIdentifiers.first.flatMap { _ in nil } }
        // Simpler approach
        recentProjects = (UserDefaults.standard.array(forKey: "jxcode.recentProjects") as? [String])?.compactMap { URL(string: $0) } ?? []
    }

    private func addProject(_ url: URL) {
        if !recentProjects.contains(url) {
            recentProjects.insert(url, at: 0)
            if recentProjects.count > 20 { recentProjects = Array(recentProjects.prefix(20)) }
            UserDefaults.standard.set(recentProjects.map(\.absoluteString), forKey: "jxcode.recentProjects")
        }
    }

    private func openProject(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
