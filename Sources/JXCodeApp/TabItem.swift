import AppKit
import Combine
import Foundation
import JXCodeCore

/// One tab in the workspace. A terminal (a pty running an agent), an embedded
/// web panel, or the shared collection.
///
/// The kinds exist because agents are not all the same shape. Claude Code and
/// `omp` are processes; Jules is an async cloud service whose dashboard is a web
/// page. Forcing Jules into a terminal would mean watching a session through
/// `jules remote list` polling, which is strictly worse than the dashboard it
/// already has.
@MainActor
final class TabItem: ObservableObject, Identifiable {

    enum Kind {
        case terminal(TerminalController)
        case web(WebPanelController)
        /// The app-wide shared collection.
        case shared
    }

    let id = UUID()
    let kind: Kind

    /// Mirrors the underlying controller's title so the tab bar re-renders on
    /// OSC title changes without observing every controller directly.
    @Published private(set) var title: String
    @Published private(set) var isRunning: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init(terminal: TerminalController) {
        self.kind = .terminal(terminal)
        self.title = terminal.title
        self.isRunning = terminal.isRunning

        terminal.$title
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.title = $0 }
            .store(in: &cancellables)

        terminal.$isRunning
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.isRunning = $0 }
            .store(in: &cancellables)
    }

    init(web: WebPanelController) {
        self.kind = .web(web)
        self.title = web.title
        self.isRunning = true

        web.$title
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.title = $0 }
            .store(in: &cancellables)
    }

    /// The shared collection, as a tab.
    ///
    /// Deliberately carries no payload. Which of its four sections is showing
    /// lives in `AppState.sharedSection`, so the pane's own tab strip can change
    /// it without rebuilding this tab — and there is no second copy of that fact
    /// to drift out of step with the first. The title is fixed for the same
    /// reason: a title seeded from the section would go stale the moment the
    /// user switched sections inside the pane.
    private init() {
        self.kind = .shared
        self.title = "Shared"
        self.isRunning = true
    }

    /// A named constructor rather than a bare `TabItem()`: at a call site next
    /// to `TabItem(terminal:)` and `TabItem(web:)`, `TabItem()` reads as a
    /// mystery rather than as the shared collection.
    static func sharedCollection() -> TabItem { TabItem() }

    var icon: MXIconName {
        switch kind {
        case .terminal(let controller): return controller.icon
        case .web: return .dashboard
        case .shared: return .layers
        }
    }

    var isTerminal: Bool {
        if case .terminal = kind { return true }
        return false
    }

    var isShared: Bool {
        if case .shared = kind { return true }
        return false
    }

    func terminate() {
        if case .terminal(let controller) = kind { controller.terminate() }
    }
}
