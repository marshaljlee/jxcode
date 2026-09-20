import AppKit
import SwiftUI

@main
struct JXCodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("JXCode") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 900, minHeight: 560)
                .task { state.bootstrap() }
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Workspace…") { state.promptForWorkspace = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("New Tab") { state.openTab(agentID: "shell") }
                    .keyboardShortcut("t", modifiers: .command)

                Divider()

                Button("Run Sandbox Doctor") { state.refreshDoctor() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}

/// Running as a bare executable (via `swift run`) rather than a bundled app
/// leaves the activation policy at `.prohibited`, so no window appears and the
/// process looks hung. This forces normal app behaviour in both cases.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
