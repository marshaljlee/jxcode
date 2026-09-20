import AppKit
import Foundation
import JXCodeCore
import SwiftTerm

/// Owns one terminal tab: the pty, the view, and the bridge between them.
///
/// Bytes arrive on the pty's background queue and must be handed to AppKit on
/// the main queue, so every callback hops before touching the view.
final class TerminalController: NSObject, ObservableObject, TerminalViewDelegate, Identifiable {

    /// What this tab is running.
    ///
    /// An enum rather than an optional agent alongside an optional tool: the two
    /// are mutually exclusive, and a pair of optionals would let a caller set
    /// both or neither, leaving the launch path to guess. Here "one or the
    /// other" is the only thing that can be said.
    enum Subject {
        case agent(AgentDefinition)
        case tool(ToolDefinition)

        var name: String {
            switch self {
            case .agent(let agent): return agent.name
            case .tool(let tool):   return tool.name
            }
        }

        /// Tool tabs are named after the tool rather than after a process, so
        /// they are not renamed by whatever the tool prints in its title.
        var adoptsProcessTitle: Bool {
            if case .agent = self { return true }
            return false
        }
    }

    let id = UUID()
    let subject: Subject

    @Published var title: String
    @Published var isRunning = false
    @Published var statusNote: String?

    private let sandbox: Sandbox
    private let workspace: Workspace?
    private var session: PTYSession?
    private weak var terminalView: TerminalView?
    private var didStart = false

    init(subject: Subject, sandbox: Sandbox, workspace: Workspace?) {
        self.subject = subject
        self.sandbox = sandbox
        self.workspace = workspace
        self.title = subject.name
        super.init()
    }

    convenience init(agent: AgentDefinition, sandbox: Sandbox, workspace: Workspace?) {
        self.init(subject: .agent(agent), sandbox: sandbox, workspace: workspace)
    }

    convenience init(tool: ToolDefinition, sandbox: Sandbox, workspace: Workspace?) {
        self.init(subject: .tool(tool), sandbox: sandbox, workspace: workspace)
    }

    // MARK: - Lifecycle

    func attach(_ view: TerminalView) {
        terminalView = view
        view.terminalDelegate = self
        if let session {
            let dims = view.terminal.getDims()
            session.resize(columns: dims.cols, rows: dims.rows)
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        // Everything about *what* runs and *under what environment* is decided
        // inside `Sandbox`; this only wires the view. Building the pty here
        // instead — which this used to do — meant the GUI had its own launch
        // path, and that one silently skipped the agent's own environment
        // overrides.
        let configure: (PTYSession) -> Void = { [weak self] session in
            session.onData = { data in
                DispatchQueue.main.async {
                    self?.terminalView?.feed(byteArray: ArraySlice(data))
                }
            }
            session.onExit = { code in
                DispatchQueue.main.async {
                    self?.isRunning = false
                    self?.statusNote = "exited (\(code))"
                }
            }
        }

        do {
            let dims = terminalView?.terminal.getDims() ?? (cols: 120, rows: 32)

            let session: PTYSession
            switch subject {
            case .agent(let agent):
                session = try sandbox.launch(
                    agent: agent,
                    workspace: workspace,
                    columns: dims.cols,
                    rows: dims.rows,
                    configure: configure
                )
            case .tool(let tool):
                // `launchCommand` resolves against the sandbox `PATH` and throws
                // rather than falling back to the host binary — which is what
                // makes "launch" fail loudly for a tool that is only on the Mac,
                // instead of quietly running it against the host home.
                session = try sandbox.launchCommand(
                    tool.binary,
                    arguments: tool.arguments,
                    workspace: workspace,
                    columns: dims.cols,
                    rows: dims.rows,
                    configure: configure
                )
            }

            self.session = session
            isRunning = true
            statusNote = nil
        } catch {
            isRunning = false
            statusNote = "failed to launch"
            let message = "\(error)\r\n"
            terminalView?.feed(byteArray: ArraySlice(Data(message.utf8)))
        }
    }

    func terminate() {
        session?.terminate()
    }

    func focus() {
        guard let view = terminalView else { return }
        view.window?.makeFirstResponder(view)
    }

    var workspacePath: String {
        workspace?.path ?? sandbox.paths.home.path
    }

    /// Glyph for the tab bar. Shared with the launcher so the two agree.
    var icon: MXIconName {
        switch subject {
        case .agent(let agent): return AgentPresentation.icon(for: agent.id)
        case .tool(let tool):   return AgentPresentation.icon(forTool: tool.id)
        }
    }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        session?.write(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session?.resize(columns: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        guard subject.adoptsProcessTitle else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.title = trimmed
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // Surfaced later as a workspace-relative breadcrumb.
    }

    func scrolled(source: TerminalView, position: Double) {}

    /// OSC 52. The payload arrives as raw bytes rather than a String because it
    /// is not guaranteed to be UTF-8.
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let string = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    func clipboardRead(source: TerminalView) -> Data? {
        NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
