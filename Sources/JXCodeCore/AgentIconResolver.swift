import Foundation

/// Where an agent's icon came from, and whether it should be watched.
///
/// The distinction the dashboard needs is not "which icon" but "could this
/// change under me". A mark transcribed into the source is fixed until the app
/// is rebuilt; a mark loaded from a file can change while the app is running.
/// Mixing the two without saying which is which is how a card ends up showing
/// a stale mark next to a fresh one with no way to tell why.
public enum AgentIconSource: Equatable, Sendable {
    /// A file in the sandbox that the dashboard re-reads when it changes.
    case file(URL)
    /// Path data compiled into the app.
    case builtIn
    /// Nothing to draw; the caller falls back to a glyph.
    case none

    /// Whether a change to this source should trigger a redraw.
    public var isLive: Bool {
        if case .file = self { return true }
        return false
    }
}

/// Resolves an agent's mark, preferring a file the user supplied.
///
/// Built-in marks are transcribed into `AgentIcons`, which means a new agent —
/// or a rebrand of an old one — shows a stand-in glyph until somebody edits
/// `AgentIcons.swift` and ships a build. That is a slow loop for a picture, and
/// the picture is the thing most likely to change.
///
/// So the dashboard looks for `<sandbox>/state/agent-icons/<id>.svg` (or
/// `.png`) first. Drop a file in and the card picks it up on the next refresh;
/// delete it and the built-in mark comes back. Nothing here writes to that
/// folder: the app reads, the user (or whatever produced the artwork) writes,
/// which is why there is no upload path and no cache to invalidate by hand.
///
/// The reason it is not fully automatic — a filesystem watcher — is that a
/// watcher has to be torn down when the window closes and has to survive the app
/// being backgrounded, and a dashboard that redraws on `refreshInstalledAgents`
/// already re-reads this at every meaningful moment. A watcher would add a
/// lifetime to own for a change that happens when a person is editing files.
public struct AgentIconResolver: Sendable {

    private let paths: SandboxPaths

    public init(paths: SandboxPaths = .default) {
        self.paths = paths
    }

    /// The folder a user drops an agent's icon into.
    public var directory: URL {
        paths.state.appendingPathComponent("agent-icons", isDirectory: true)
    }

    /// The file for `agentID`, if the user has supplied one.
    ///
    /// SVG is tried before PNG: an icon that scales to 36pt and 16pt without
    /// resampling is the whole reason to prefer it, and `NSImage` reads SVG on
    /// every macOS this app supports.
    public func suppliedFile(for agentID: String) -> URL? {
        // An agent id comes from the registry, which the user can edit by hand.
        // A path built from one is a path traversal if the id is `../../x`, so
        // the characters that could climb out are the ones refused.
        guard isSafeComponent(agentID) else { return nil }
        for ext in ["svg", "png"] {
            let candidate = directory
                .appendingPathComponent(agentID)
                .appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Where `agentID`'s mark comes from, right now.
    public func source(for agentID: String) -> AgentIconSource {
        if let file = suppliedFile(for: agentID) { return .file(file) }
        if AgentIcons.icon(for: agentID) != nil { return .builtIn }
        return .none
    }

    /// A fingerprint of every supplied icon, used to tell "something changed"
    /// from "re-render for no reason".
    ///
    /// Modification date and size rather than contents: hashing every icon on
    /// every redraw is work proportional to the artwork, and a file whose mtime
    /// and length are unchanged has not meaningfully changed. A fingerprint is
    /// only ever compared against the previous one, so a coarse value is fine —
    /// it is a change *detector*, not a content address.
    public func fingerprint() -> String {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return "" }

        return entries
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> String? in
                guard let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]
                ) else { return nil }
                let stamp = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                return "\(url.lastPathComponent):\(Int(stamp)):\(values.fileSize ?? 0)"
            }
            .joined(separator: "|")
    }

    /// Whether `agentID` is safe to use as one path component.
    ///
    /// Permits the characters an id legitimately has — letters, digits, dash,
    /// underscore, dot — and refuses `/` and anything else. A leading dot would
    /// also hide the file, and `..` is the traversal itself, so both are out.
    ///
    /// Public because "could this agent ever have a supplied icon" is a question
    /// the icon tests ask for every built-in: an agent whose id cannot form a
    /// filename can never be given a mark this way, so it has to carry a
    /// compiled-in one or the registry entry is incomplete.
    public func isAcceptableAgentID(_ agentID: String) -> Bool {
        isSafeComponent(agentID)
    }

    /// Whether `agentID` is safe to use as one path component.
    ///
    /// An agent id comes from the registry, which the user can edit by hand.
    /// A path built from one is a path traversal if the id is `../../x`, so the
    /// characters that could climb out are the ones refused.
    private func isSafeComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        guard !value.hasPrefix(".") else { return false }
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_."))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// The path shown to the user, for the icon row's tooltip.
    public func describeSource(for agentID: String) -> String {
        switch source(for: agentID) {
        case .file(let url):
            return "Icon: \(url.lastPathComponent) (\(url.deletingLastPathComponent().path))"
        case .builtIn:
            return "Icon: built in"
        case .none:
            return "No icon for \(agentID) — drop \(agentID).svg into \(directory.path)"
        }
    }
}
