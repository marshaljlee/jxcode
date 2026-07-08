import Foundation

/// Where the session's message content lives on disk.
public enum SessionOrigin: String, Codable, Sendable {
    /// Legacy JXCODE-owned JSON at `~/Library/Application Support/JXCODE/sessions/{projectId}/{sid}.json`.
    /// Read-only going forward; will not appear in the CLI's `~/.claude/projects/...` directory.
    case legacyJXCODE

    /// Backed by Claude Code CLI's `~/.claude/projects/{enc(cwd)}/{sid}.jsonl`.
    /// Source of truth is the CLI; JXCODE keeps JXCODE-only metadata in a sidecar.
    case cliBacked
}
