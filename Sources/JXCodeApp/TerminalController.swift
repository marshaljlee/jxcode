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

    /// Extra argv appended to the agent's own launch arguments — the YOLO
    /// seam. Empty for an ordinary launch; YOLO mode hands in the union of the
    /// per-agent skip-permission flags, and each CLI ignores the flags that
    /// belong to the others.
    ///
    /// Passed through `Sandbox.launch`, so the CLI harness and any other
    /// caller keep their exact behaviour untouched.
    var launchArguments: [String] = []

    @Published var title: String
    @Published var isRunning = false
    @Published var statusNote: String?

    private let sandbox: Sandbox
    private let workspace: Workspace?
    private var session: PTYSession?
    private weak var terminalView: TerminalView?
    private var didStart = false

    init(subject: Subject, sandbox: Sandbox, workspace: Workspace?, launchArguments: [String] = []) {
        self.subject = subject
        self.sandbox = sandbox
        self.workspace = workspace
        self.launchArguments = launchArguments
        self.title = subject.name
        super.init()
    }

    convenience init(agent: AgentDefinition, sandbox: Sandbox, workspace: Workspace?,
                     launchArguments: [String] = []) {
        self.init(subject: .agent(agent), sandbox: sandbox, workspace: workspace,
                  launchArguments: launchArguments)
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
                    extraArguments: launchArguments,
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

    /// Type text into the running program as if the user had.
    ///
    /// The only channel jxcode has into a CLI agent. A pty has no "set prompt"
    /// verb — the agent reads what arrives on stdin — so the bytes are written
    /// exactly as a keystroke would arrive, and the caller decides what the text
    /// is. Return value says whether the write reached a live session, because a
    /// charter written to a process that has already exited is silently lost and
    /// the primary would come up with no idea it is in charge.
    @discardableResult
    func type(_ text: String) -> Bool {
        guard let session, isRunning else { return false }
        session.write(Data(text.utf8))
        return true
    }

    /// Hand the primary its charter, once the agent has had time to start.
    ///
    /// The delay is not decoration. A CLI agent needs to paint its own UI and
    /// reach its prompt before anything typed is read as input, and typing into a
    /// half-drawn screen either lands in a spinner or lands in a redraw that eats
    /// it. One and a half seconds is what the install path already waits before
    /// typing into a fresh shell, and it is the number that works here too.
    func deliverCharter(_ text: String, after delay: TimeInterval = 1.5) {
        guard !text.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isRunning else { return }
            // A leading newline settles the cursor onto a clean prompt line, and
            // the trailing one submits. Without them the first characters of the
            // charter are consumed by whatever the agent was still drawing.
            self.type("\n" + text + "\n")
        }
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
