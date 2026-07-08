import SwiftUI
import JXCODECore

// MARK: - Paseo Projects Tab

// MARK: - Recent Project Entry

public struct RecentProjectEntry: Codable, Hashable, Identifiable {
    public var id: String { url }
    public let url: String
    public let name: String
    public let lastOpened: Date

    public init(url: String, name: String, lastOpened: Date) {
        self.url = url
        self.name = name
        self.lastOpened = lastOpened
    }
}

// MARK: - Paseo Projects Tab View

public struct PaseoProjectsTab: View {
    @Environment(AppState.self) private var appState
    @State private var recentProjects: [RecentProjectEntry] = []
    @State private var showImporter = false
    @State private var quickOpenPath = ""
    @State private var showQuickOpen = false
    @State private var searchText = ""
    @State private var hoveredProjectId: String?

    private let maxRecentProjects = 20
    private let defaultsKey = "jxcode.recentProjects"

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                Divider()
                quickOpenSection
                Divider()
                recentProjectsSection
                Divider()
                actionsSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: loadRecentProjects)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.directory]) { result in
            if case .success(let url) = result {
                importProject(url)
            }
        }
        .sheet(isPresented: $showQuickOpen) {
            quickOpenSheet
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project Manager")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("Manage your development projects. Import directories, reopen recent work, or quickly navigate to any project path.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Import Project") { showImporter = true }
                    .controlSize(.small)

                Button("Quick Open") { showQuickOpen = true }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Quick Open

    private var quickOpenSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Open")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.textTertiary)

                TextField("Enter project path or name...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: ClaudeTheme.size(12)))
                    .onSubmit { quickOpenSearch() }

                if !searchText.isEmpty {
                    Button {
                        quickOpenSearch()
                    } label: {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: ClaudeTheme.size(14)))
                            .foregroundStyle(ClaudeTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(ClaudeTheme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
            .overlay(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                    .strokeBorder(ClaudeTheme.border, lineWidth: 1)
            )

            if !searchText.isEmpty {
                let results = filteredResults
                if results.isEmpty {
                    Text("No matching projects found")
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                } else {
                    ForEach(results) { entry in
                        quickOpenRow(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func quickOpenRow(_ entry: RecentProjectEntry) -> some View {
        Button {
            openInFinder(URL(fileURLWithPath: entry.url))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    Text(entry.url)
                        .font(.system(size: ClaudeTheme.size(9)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(entry.lastOpened.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: ClaudeTheme.size(9)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(hoveredProjectId == entry.id ? ClaudeTheme.surfaceTertiary.opacity(0.5) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
            .onHover { hovering in
                hoveredProjectId = hovering ? entry.id : nil
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recent Projects List

    private var recentProjectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Projects")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            if recentProjects.isEmpty {
                emptyState
            } else {
                VStack(spacing: 4) {
                    ForEach(recentProjects) { entry in
                        projectRow(entry)
                    }
                }
                .padding(12)
                .background(ClaudeTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium))
                .overlay(
                    RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium)
                        .strokeBorder(ClaudeTheme.border, lineWidth: 0.5)
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 32))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Text("No recent projects")
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(ClaudeTheme.textSecondary)
            Text("Import a project directory to see it here, or use Quick Open above to navigate to any project on disk.")
                .font(.system(size: ClaudeTheme.size(10)))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    @ViewBuilder
    private func projectRow(_ entry: RecentProjectEntry) -> some View {
        let url = URL(fileURLWithPath: entry.url)
        let projectExists = FileManager.default.fileExists(atPath: entry.url)

        HStack(spacing: 10) {
            // Icon
            Image(systemName: projectExists ? "folder.fill" : "folder.badge.questionmark")
                .font(.system(size: ClaudeTheme.size(14)))
                .foregroundStyle(projectExists ? ClaudeTheme.accent : ClaudeTheme.statusWarning)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                    if !projectExists {
                        Text("(missing)")
                            .font(.system(size: ClaudeTheme.size(9)))
                            .foregroundStyle(ClaudeTheme.statusError)
                    }
                }
                Text(entry.url)
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 12) {
                    Label {
                        Text("Last opened: \(entry.lastOpened.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: ClaudeTheme.size(9)))
                    } icon: {
                        Image(systemName: "clock")
                            .font(.system(size: ClaudeTheme.size(8)))
                    }
                    .foregroundStyle(ClaudeTheme.textTertiary)

                    if isGitRepository(url) {
                        Label {
                            Text("Git repo")
                                .font(.system(size: ClaudeTheme.size(9)))
                        } icon: {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: ClaudeTheme.size(8)))
                        }
                        .foregroundStyle(ClaudeTheme.statusSuccess)
                    }
                }
            }

            Spacer()

            // Actions
            HStack(spacing: 4) {
                if projectExists {
                    Button {
                        addToAppProjects(entry)
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: ClaudeTheme.size(12)))
                    }
                    .buttonStyle(.plain)
                    .help("Add to JXCODE projects")

                    Button {
                        openInFinder(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: ClaudeTheme.size(12)))
                    }
                    .buttonStyle(.plain)
                    .help("Open in Finder")
                }

                Button {
                    removeProject(entry)
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: ClaudeTheme.size(12)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Remove from recent list")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(hoveredProjectId == entry.id ? ClaudeTheme.surfaceTertiary.opacity(0.3) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        .onHover { hovering in
            hoveredProjectId = hovering ? entry.id : nil
        }
        .contextMenu {
            if projectExists {
                Button("Open in Finder") { openInFinder(url) }
                Button("Add to JXCODE Projects") { addToAppProjects(entry) }
                Button("Show in Terminal") { openInTerminal(url) }
                Divider()
            }
            Button("Remove from Recent", role: .destructive) { removeProject(entry) }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Actions")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            HStack(spacing: 16) {
                actionButton(
                    icon: "folder.badge.plus",
                    label: "Import\nProject",
                    action: { showImporter = true }
                )
                actionButton(
                    icon: "arrow.clockwise",
                    label: "Refresh\nList",
                    action: loadRecentProjects
                )
                actionButton(
                    icon: "text.badge.checkmark",
                    label: "Validate\nPaths",
                    action: validateProjectPaths
                )
                actionButton(
                    icon: "trash",
                    label: "Clear\nAll",
                    action: clearAllRecent,
                    destructive: true
                )
            }
        }
    }

    private func actionButton(icon: String, label: String, action: @escaping () -> Void, destructive: Bool = false) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: ClaudeTheme.size(16)))
                    .foregroundStyle(destructive ? ClaudeTheme.statusError : ClaudeTheme.accent)
                Text(label)
                    .font(.system(size: ClaudeTheme.size(9)))
                    .foregroundStyle(destructive ? ClaudeTheme.statusError : ClaudeTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(width: 64, height: 52)
            .background(ClaudeTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
            .overlay(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                    .strokeBorder(ClaudeTheme.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Quick Open Sheet

    private var quickOpenSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(ClaudeTheme.textTertiary)
                TextField("Type a project path or name...", text: $quickOpenPath)
                    .textFieldStyle(.plain)
                    .font(.system(size: ClaudeTheme.size(13)))
                if !quickOpenPath.isEmpty {
                    Button {
                        quickOpenPath = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(ClaudeTheme.inputBackground)
            .overlay(
                Rectangle()
                    .fill(ClaudeTheme.border)
                    .frame(height: 1),
                alignment: .bottom
            )

            let resolved = resolveQuickOpenPath()
            if !quickOpenPath.isEmpty {
                List {
                    if quickOpenPath.contains("/") || quickOpenPath.contains("~") {
                        // Treat as path input
                        let url = resolved
                        let exists = url.map { FileManager.default.fileExists(atPath: $0.path ) } ?? false
                        if let url = url {
                            quickOpenCandidateRow(url: url, exists: exists)
                        } else {
                            Text("Invalid path")
                                .font(.system(size: ClaudeTheme.size(11)))
                                .foregroundStyle(ClaudeTheme.statusError)
                        }
                    } else {
                        // Search recent projects by name
                        let matches = recentProjects.filter { $0.name.localizedCaseInsensitiveContains(quickOpenPath) }
                        if matches.isEmpty {
                            Text("No matching projects")
                                .font(.system(size: ClaudeTheme.size(11)))
                                .foregroundStyle(ClaudeTheme.textTertiary)
                        } else {
                            ForEach(matches) { entry in
                                Button {
                                    openInFinder(URL(fileURLWithPath: entry.url))
                                    showQuickOpen = false
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "folder.fill")
                                            .foregroundStyle(ClaudeTheme.accent)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(entry.name)
                                                .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                                            Text(entry.url)
                                                .font(.system(size: ClaudeTheme.size(10)))
                                                .foregroundStyle(ClaudeTheme.textTertiary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 28))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Text("Enter a project path or search by name")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack {
                Text("Press Enter to open")
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                Spacer()
                Button("Cancel") { showQuickOpen = false }
                    .controlSize(.small)
                    .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 440, height: 320)
    }

    @ViewBuilder
    private func quickOpenCandidateRow(url: URL, exists: Bool) -> some View {
        Button {
            if exists {
                importProject(url)
                openInFinder(url)
                showQuickOpen = false
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: exists ? "folder.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(exists ? ClaudeTheme.accent : ClaudeTheme.statusWarning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    Text(url.path)
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    if !exists {
                        Text("Path does not exist on disk")
                            .font(.system(size: ClaudeTheme.size(9)))
                            .foregroundStyle(ClaudeTheme.statusError)
                    }
                }
                Spacer()
                if exists {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(ClaudeTheme.accent)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(!exists)
    }

    // MARK: - Helpers

    private var filteredResults: [RecentProjectEntry] {
        guard !searchText.isEmpty else { return recentProjects }
        return recentProjects.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.url.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func resolveQuickOpenPath() -> URL? {
        let trimmed = quickOpenPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    private func quickOpenSearch() {
        guard !searchText.isEmpty else { return }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("/") || trimmed.contains("~") || FileManager.default.fileExists(atPath: trimmed) ||
           FileManager.default.fileExists(atPath: (trimmed as NSString).expandingTildeInPath) {
            showQuickOpen = true
            quickOpenPath = trimmed
        } else {
            // Treat as name search, open the best match
            if let match = recentProjects.first(where: {
                $0.name.localizedCaseInsensitiveContains(trimmed)
            }) {
                openInFinder(URL(fileURLWithPath: match.url))
            }
        }
    }

    private func loadRecentProjects() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([RecentProjectEntry].self, from: data) else {
            recentProjects = []
            return
        }
        recentProjects = entries.sorted { $0.lastOpened > $1.lastOpened }
    }

    private func saveRecentProjects() {
        let sorted = Array(recentProjects.sorted { $0.lastOpened > $1.lastOpened }.prefix(maxRecentProjects))
        recentProjects = sorted
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func importProject(_ url: URL) {
        let resolved = url.resolvingSymlinksInPath()
        let entry = RecentProjectEntry(
            url: resolved.path,
            name: resolved.lastPathComponent,
            lastOpened: Date()
        )
        recentProjects.removeAll { $0.url == resolved.path }
        recentProjects.insert(entry, at: 0)
        saveRecentProjects()

        // Also add to app state if not already present
        if !appState.projects.contains(where: { $0.path == resolved.path }) {
            Task {
                await appState.addProject(
                    name: resolved.lastPathComponent,
                    path: resolved.path,
                    gitHubRepo: nil
                )
            }
        }
    }

    private func addToAppProjects(_ entry: RecentProjectEntry) {
        guard !appState.projects.contains(where: { $0.path == entry.url }) else { return }
        let url = URL(fileURLWithPath: entry.url)
        Task {
            await appState.addProject(
                name: entry.name,
                path: entry.url,
                gitHubRepo: detectGitRemote(url)
            )
        }
    }

    private func removeProject(_ entry: RecentProjectEntry) {
        recentProjects.removeAll { $0.url == entry.url }
        saveRecentProjects()
    }

    private func clearAllRecent() {
        recentProjects = []
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private func openInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func openInTerminal(_ url: URL) {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
        // Open folder in Terminal via scripting
        let source = """
        tell application "Terminal"
            activate
            tell application "System Events" to tell process "Terminal" to keystroke "t" using command down
            delay 0.2
            do script "cd \(url.path.shellQuoted())" in front window
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    private func validateProjectPaths() {
        for index in recentProjects.indices.reversed() {
            if !FileManager.default.fileExists(atPath: recentProjects[index].url) {
                recentProjects.remove(at: index)
            }
        }
        saveRecentProjects()
    }

    private func isGitRepository(_ url: URL) -> Bool {
        let gitPath = url.appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: gitPath.path)
    }

    private func detectGitRemote(_ url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", url.path, "remote", "get-url", "origin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
