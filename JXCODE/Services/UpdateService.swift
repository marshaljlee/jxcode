import Sparkle
import Foundation
import os

/// Service that manages Sparkle auto-updates and embedded Claude CLI updates.
/// Automatically checks for app updates on launch; users can check manually from the menu.
/// Also synchronises the embedded `claude` binary with the user's installed version.
@MainActor
final class UpdateService {
    static let shared = UpdateService()

    private let controller: SPUStandardUpdaterController
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.idealapp.JXCODE", category: "UpdateService")

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Check whether the installed `claude` binary is newer than the one
    /// embedded in the bundle. If so, replace the embedded copy so the
    /// app always ships the freshest CLI on the next build.
    ///
    /// Called on app launch. Runs in a background task — never blocks startup.
    func syncEmbeddedClaude() async {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path

        var installedPaths: [String] = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
        ]

        // Find the installed binary (not the embedded one we're about to replace)
        guard let installed = installedPaths.first(where: { fm.isExecutableFile(atPath: $0) }),
              let bundlePath = Bundle.main.path(forResource: "claude", ofType: nil) else {
            logger.debug("syncEmbeddedClaude: no installed claude or embedded copy found")
            return
        }

        guard let installedVersion = try? await claudeVersion(at: installed),
              let bundleVersion = try? await claudeVersion(at: bundlePath) else {
            logger.debug("syncEmbeddedClaude: could not read version from either binary")
            return
        }

        // Pre-release / versionless binaries are treated as "always current"
        guard installedVersion != bundleVersion else { return }

        logger.info("Updating embedded claude from \(bundleVersion, privacy: .public) to \(installedVersion, privacy: .public)")
        do {
            _ = try fm.replaceItemAt(
                URL(fileURLWithPath: bundlePath),
                withItemAt: URL(fileURLWithPath: installed)
            )
            logger.info("Embedded claude updated successfully")
        } catch {
            logger.error("Failed to update embedded claude: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func claudeVersion(at path: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
    }
}
