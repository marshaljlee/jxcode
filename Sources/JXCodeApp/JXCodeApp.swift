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
                .task {
                    state.bootstrap()
                    // The delegate outlives this view. Hand it the shutdown hook
                    // so quitting tears down the served model and the ptys.
                    AppDelegate.onTerminate = { state.shutdown() }
                }
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

    /// Handed over by the SwiftUI layer once `AppState` exists.
    ///
    /// AppKit builds the delegate before the `App` struct's state is created, so
    /// the delegate cannot hold a reference to it at construction. A closure is
    /// the smallest thing that crosses that gap without the delegate owning the
    /// application's state.
    static var onTerminate: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Runs before the process exits — the one thing `deinit` cannot be relied
    /// on to do, and the reason quitting used to leave llama-server and every
    /// agent pty running as orphans.
    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.onTerminate?()
    }
}
