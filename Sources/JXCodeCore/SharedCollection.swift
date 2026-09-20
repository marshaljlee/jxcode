import Foundation

/// Slugs and other identifier helpers.
///
/// This lived in two places — a global in the CLI target and a private static
/// on `AppState` — with identical bodies. The shared collection needed a third
/// copy, which is where a duplicated rule stops being a coincidence and starts
/// being a maintenance problem: the moment one of them learns to handle a
/// non-ASCII name, the other two quietly disagree.
public enum Identifier {

    /// A stable, filesystem-safe id derived from a display name.
    ///
    /// Anything that is not a letter or a digit becomes a separator, runs are
    /// collapsed, and the result is lowercased. An input with no usable
    /// characters at all falls back, because an empty id is not a usable key.
    public static func slug(_ text: String, fallback: String = "item") -> String {
        let allowed = text.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? fallback : collapsed
    }
}

// MARK: - Skills

/// A reusable instruction pack, shared by every agent.
///
/// Stored as a `SKILL.md` file with YAML frontmatter — the format the agents
/// themselves use — rather than as JSON. That choice matters: a skill is
/// something a person writes and edits, and a Markdown file with a heading and
/// prose is editable in any editor. Wrapping the same text in a JSON string
/// would make every newline an escape sequence.
///
/// The `SKILL.md` is therefore the source of truth for the *content*, and the
/// sibling `skill.json` holds only what the file cannot express: whether the
/// skill is switched on, and when it changed.
public struct Skill: Codable, Identifiable, Hashable, Sendable {

    public var id: String
    /// Display name, from frontmatter `name:` or the first heading.
    public var name: String
    /// One line, from frontmatter `description:` or the first paragraph.
    ///
    /// This is what the agent is shown when several skills are bound at once,
    /// so it has to say what the skill is *for*, not repeat its name.
    public var summary: String
    /// The Markdown body, without frontmatter.
    public var body: String
    public var enabled: Bool
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        summary: String,
        body: String,
        enabled: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.body = body
        self.enabled = enabled
        self.updatedAt = updatedAt
    }

    /// Render back to a `SKILL.md` with frontmatter.
    ///
    /// Round-trips through `parse`, so writing a skill and reading it back
    /// yields the same value — asserted in the tests, because a skill that
    /// loses its description on the second read is a bug that only shows up
    /// after a restart.
    public func rendered() -> String {
        var lines = ["---", "name: \(Self.escapeFrontmatter(name))"]
        if !summary.isEmpty {
            lines.append("description: \(Self.escapeFrontmatter(summary))")
        }
        lines.append("---")
        lines.append("")
        lines.append(body)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Read a `SKILL.md`, deriving the display name and summary when the
    /// frontmatter omits them.
    public static func parse(id: String, text: String, enabled: Bool, updatedAt: Date) -> Skill {
        let (frontmatter, body) = splitFrontmatter(text)

        let name = frontmatter["name"]?.nonEmpty
            ?? firstHeading(in: body)
            ?? id

        // Prefer the declared description. Falling back to the first paragraph
        // is a guess, but a much better one than showing the agent an empty
        // line where the summary should be.
        let summary = frontmatter["description"]?.nonEmpty
            ?? firstParagraph(in: body)
            ?? ""

        return Skill(
            id: id,
            name: name,
            summary: summary,
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: enabled,
            updatedAt: updatedAt
        )
    }

    /// Split leading `---` frontmatter from the body.
    ///
    /// Deliberately not a YAML parser. The keys that matter here are flat
    /// `key: value` pairs, and a full YAML dependency would be a large amount
    /// of surface area for a config file whose worst case is a missing
    /// description.
    static func splitFrontmatter(_ text: String) -> ([String: String], String) {
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalised.components(separatedBy: "\n")

        // Skip a leading blank line or a BOM before the opening fence, or a
        // file that is otherwise fine reads as having no frontmatter at all.
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        guard let opening = lines.first,
              opening.trimmingCharacters(in: .whitespaces) == "---"
        else { return ([:], normalised) }

        guard let closing = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else {
            // An unterminated fence. Treat the whole file as body rather than
            // swallowing it — a skill whose content vanished is worse than one
            // whose frontmatter did.
            return ([:], normalised)
        }

        var pairs: [String: String] = [:]
        for line in lines[1..<closing] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            pairs[key] = unquote(value)
        }

        let body = lines[(closing + 1)...].joined(separator: "\n")
        return (pairs, body)
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Quote a value that would otherwise be misread, e.g. one containing `: `.
    static func escapeFrontmatter(_ value: String) -> String {
        if value.contains(": ") || value.hasPrefix(" ") || value.hasSuffix(" ")
            || value.hasPrefix("\"") || value.hasPrefix("'") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return value
    }

    private static func firstHeading(in body: String) -> String? {
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return nil
    }

    private static func firstParagraph(in body: String) -> String? {
        var collecting = false
        var collected: [String] = []
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.isEmpty {
                if collecting { break }
                continue
            }
            collecting = true
            collected.append(trimmed)
        }
        let paragraph = collected.joined(separator: " ")
        return paragraph.isEmpty ? nil : paragraph
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Connectors

/// How a connector is reached.
public enum ConnectorTransport: String, Codable, Sendable, CaseIterable {
    /// A subprocess speaking MCP over stdio. The common case.
    case stdio
    /// A remote MCP endpoint over HTTP.
    case http

    public var label: String {
        switch self {
        case .stdio: return "Local command"
        case .http:  return "Remote URL"
        }
    }
}

/// An external capability an agent can call — an MCP server.
///
/// Stored once and bound into every agent's own MCP config. The binding step is
/// where the per-agent knowledge lives: the four agents that support MCP all
/// use different files, different key names and different entry shapes, and
/// there is no shared standard to fall back on.
public struct Connector: Codable, Identifiable, Hashable, Sendable {

    public var id: String
    public var name: String
    public var transport: ConnectorTransport

    /// stdio: the executable, resolved against the sandbox `PATH`.
    public var command: String
    /// stdio: arguments passed to `command`.
    public var arguments: [String]

    /// http: the endpoint.
    public var url: String
    /// http: request headers, typically auth.
    public var headers: [String: String]

    /// Extra environment for the child process (stdio only).
    public var environment: [String: String]

    /// Run once, into the shared prefix, before the connector is first used.
    ///
    /// This is the "shared install" half of the collection: a connector
    /// installed here lands in `shared/bin` (or the sandbox npm prefix), both
    /// of which are on every agent's `PATH`, so the next agent gets it for
    /// free rather than installing its own copy.
    public var installCommand: String?

    public var enabled: Bool
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        transport: ConnectorTransport = .stdio,
        command: String = "",
        arguments: [String] = [],
        url: String = "",
        headers: [String: String] = [:],
        environment: [String: String] = [:],
        installCommand: String? = nil,
        enabled: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.url = url
        self.headers = headers
        self.environment = environment
        self.installCommand = installCommand
        self.enabled = enabled
        self.updatedAt = updatedAt
    }

    /// Why this connector cannot be bound, or `nil` if it can.
    ///
    /// Checked before anything is written, so an incomplete connector produces
    /// a sentence rather than a config file that starts a process that does not
    /// exist.
    public var validationError: String? {
        switch transport {
        case .stdio:
            if command.trimmingCharacters(in: .whitespaces).isEmpty {
                return "\(name) has no command. A local connector needs one to start."
            }
        case .http:
            let trimmed = url.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                return "\(name) has no URL. A remote connector needs one to reach."
            }
            guard let parsed = URL(string: trimmed), parsed.scheme != nil, parsed.host != nil else {
                return "\(name) has a URL that cannot be parsed: \(trimmed)"
            }
        }
        return nil
    }

    /// The full argv for a stdio connector.
    public var argv: [String] { [command] + arguments }
}

// MARK: - Automation

/// When an automation runs.
///
/// A flat struct rather than an enum with associated values, for two reasons:
/// the JSON stays readable and hand-editable, and the "is it due?" calculation
/// stays a pure function of stored values — which is what makes it testable
/// without waiting for a clock or starting a process.
public struct AutomationSchedule: Codable, Hashable, Sendable {

    public enum Cadence: String, Codable, Sendable, CaseIterable {
        /// Once a day at `hour`:`minute`.
        case daily
        /// Once a week on `weekday` at `hour`:`minute`.
        case weekly
        /// Every `intervalMinutes`, measured from the last run.
        case interval

        public var label: String {
            switch self {
            case .daily:    return "Daily"
            case .weekly:   return "Weekly"
            case .interval: return "Interval"
            }
        }
    }

    public var cadence: Cadence
    public var hour: Int
    public var minute: Int
    /// 1 = Sunday … 7 = Saturday, matching `Calendar`'s `weekday` component.
    public var weekday: Int
    public var intervalMinutes: Int

    public init(
        cadence: Cadence = .daily,
        hour: Int = 9,
        minute: Int = 0,
        weekday: Int = 2,
        intervalMinutes: Int = 60
    ) {
        self.cadence = cadence
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
        self.intervalMinutes = intervalMinutes
    }

    /// A human sentence, for the list row and the CLI.
    public var summary: String {
        let time = String(format: "%02d:%02d", hour, minute)
        switch cadence {
        case .daily:
            return "Every day at \(time)"
        case .weekly:
            let names = ["", "Sunday", "Monday", "Tuesday", "Wednesday",
                         "Thursday", "Friday", "Saturday"]
            let index = min(max(weekday, 1), 7)
            return "Every \(names[index]) at \(time)"
        case .interval:
            if intervalMinutes % 60 == 0, intervalMinutes >= 60 {
                let hours = intervalMinutes / 60
                return hours == 1 ? "Every hour" : "Every \(hours) hours"
            }
            return "Every \(intervalMinutes) minutes"
        }
    }

    /// Whether this automation should run, given when it last did.
    ///
    /// `last == nil` means never run, and the two families of cadence treat that
    /// differently — deliberately, and not in the way it first looks.
    ///
    /// For `interval` there is no anchor, so a never-run automation is due
    /// immediately. Otherwise a freshly added interval automation would never
    /// start.
    ///
    /// For `daily` and `weekly` the clock is the anchor, so a never-run
    /// automation waits until today's time has passed — and then it *is* due.
    /// It is tempting to say it should wait a whole day instead, but that
    /// deadlocks: nothing else ever sets `last`, so the automation would never
    /// become due and would never run at all. Running once at the first
    /// opportunity and settling onto the schedule afterwards is the only
    /// behaviour that terminates.
    public func isDue(last: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        switch cadence {
        case .interval:
            guard intervalMinutes > 0 else { return false }
            guard let last else { return true }
            return now.timeIntervalSince(last) >= Double(intervalMinutes) * 60

        case .daily, .weekly:
            guard let scheduledToday = calendar.date(
                bySettingHour: min(max(hour, 0), 23),
                minute: min(max(minute, 0), 59),
                second: 0,
                of: now
            ) else { return false }

            if cadence == .weekly {
                let today = calendar.component(.weekday, from: now)
                guard today == min(max(weekday, 1), 7) else { return false }
            }

            // Not yet reached today.
            guard now >= scheduledToday else { return false }

            // Already run since today's scheduled time.
            if let last, last >= scheduledToday { return false }
            return true
        }
    }
}

/// A scheduled agent run.
public struct Automation: Codable, Identifiable, Hashable, Sendable {

    public var id: String
    public var name: String
    /// Which agent runs it.
    public var agentID: String
    /// What it is asked to do — passed to the agent as its first argument.
    public var prompt: String
    /// The workspace it runs in. `nil` runs in the sandbox home.
    public var workspaceID: UUID?
    public var schedule: AutomationSchedule
    public var enabled: Bool

    public var lastRun: Date?
    /// A short outcome, kept so the list can say what happened last time
    /// without the user opening a log.
    public var lastResult: String?
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        agentID: String,
        prompt: String,
        workspaceID: UUID? = nil,
        schedule: AutomationSchedule = AutomationSchedule(),
        enabled: Bool = true,
        lastRun: Date? = nil,
        lastResult: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.agentID = agentID
        self.prompt = prompt
        self.workspaceID = workspaceID
        self.schedule = schedule
        self.enabled = enabled
        self.lastRun = lastRun
        self.lastResult = lastResult
        self.updatedAt = updatedAt
    }
}

// MARK: - Store

/// The app-wide collection: skills, connectors and automations.
///
/// Agents are not duplicated here — `AgentRegistry` already owns them, and a
/// second list would be a second source of truth. The Shared pane shows the
/// registry alongside the three collections this store owns, which is why
/// `agents` is a separate object rather than a fourth array.
public final class SharedStore {

    public private(set) var skills: [Skill] = []
    public private(set) var connectors: [Connector] = []
    public private(set) var automations: [Automation] = []

    private let paths: SandboxPaths
    private let fileManager = FileManager.default

    public init(paths: SandboxPaths = .default) {
        self.paths = paths
        load()
    }

    public func load() {
        try? paths.createDirectories()
        skills = loadSkills()
        connectors = loadConnectors()
        automations = loadAutomations()
    }

    // MARK: Skills

    private func loadSkills() -> [Skill] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: paths.sharedSkills,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var found: [Skill] = []
        for directory in entries {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            let id = directory.lastPathComponent
            let skillFile = directory.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: skillFile, encoding: .utf8) else { continue }

            let metadata = readJSON(SkillMetadata.self, from: directory.appendingPathComponent("skill.json"))
            let updated = (try? skillFile.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()

            found.append(Skill.parse(
                id: id,
                text: text,
                enabled: metadata?.enabled ?? true,
                updatedAt: metadata?.updatedAt ?? updated
            ))
        }

        // Sorted so the UI and the CLI agree, and so a directory listing's
        // arbitrary order never leaks into output.
        return found.sorted { $0.id < $1.id }
    }

    @discardableResult
    public func writeSkill(_ skill: Skill) throws -> Skill {
        var skill = skill
        skill.updatedAt = Date()

        let directory = paths.sharedSkills.appendingPathComponent(skill.id, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        try skill.rendered().write(
            to: directory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try writeJSON(
            SkillMetadata(enabled: skill.enabled, updatedAt: skill.updatedAt),
            to: directory.appendingPathComponent("skill.json")
        )

        if let index = skills.firstIndex(where: { $0.id == skill.id }) {
            skills[index] = skill
        } else {
            skills.append(skill)
            skills.sort { $0.id < $1.id }
        }
        return skill
    }

    public func setSkillEnabled(id: String, enabled: Bool) throws {
        guard let index = skills.firstIndex(where: { $0.id == id }) else { return }
        skills[index].enabled = enabled
        try writeSkill(skills[index])
    }

    public func removeSkill(id: String) throws {
        try? fileManager.removeItem(at: paths.sharedSkills.appendingPathComponent(id))
        skills.removeAll { $0.id == id }
    }

    /// Skills that should actually be bound into an agent.
    public var enabledSkills: [Skill] { skills.filter(\.enabled) }

    // MARK: Connectors

    private func loadConnectors() -> [Connector] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: paths.sharedConnectors,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var found: [Connector] = []
        for directory in entries {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            guard let connector = readJSON(
                Connector.self,
                from: directory.appendingPathComponent("connector.json")
            ) else { continue }
            found.append(connector)
        }
        return found.sorted { $0.id < $1.id }
    }

    @discardableResult
    public func writeConnector(_ connector: Connector) throws -> Connector {
        var connector = connector
        connector.updatedAt = Date()

        let directory = paths.sharedConnectors.appendingPathComponent(connector.id, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeJSON(connector, to: directory.appendingPathComponent("connector.json"))

        if let index = connectors.firstIndex(where: { $0.id == connector.id }) {
            connectors[index] = connector
        } else {
            connectors.append(connector)
            connectors.sort { $0.id < $1.id }
        }
        return connector
    }

    /// Switch a connector on or off, without re-registering it.
    ///
    /// Deliberately unvalidated, and separate from the *registration* path,
    /// which does validate. `enabled` is the user's field: it records whether
    /// they want this connector bound, not whether the connector is
    /// well-formed. Refusing to write it because the connector is incomplete
    /// produces the one state nobody can escape — a row that shows a problem
    /// *and* offers a switch that does nothing. Validation belongs at bind time,
    /// where `ConnectorBinder.apply` already reports an incomplete connector as
    /// `.refused`.
    public func setConnectorEnabled(id: String, enabled: Bool) throws {
        guard let index = connectors.firstIndex(where: { $0.id == id }) else { return }
        connectors[index].enabled = enabled
        try writeConnector(connectors[index])
    }

    public func removeConnector(id: String) throws {
        try? fileManager.removeItem(at: paths.sharedConnectors.appendingPathComponent(id))
        connectors.removeAll { $0.id == id }
    }

    public var enabledConnectors: [Connector] { connectors.filter(\.enabled) }

    // MARK: Automations

    private func loadAutomations() -> [Automation] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: paths.sharedAutomations,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var found: [Automation] = []
        for file in entries where file.pathExtension == "json" {
            if let automation = readJSON(Automation.self, from: file) {
                found.append(automation)
            }
        }
        return found.sorted { $0.id < $1.id }
    }

    @discardableResult
    public func writeAutomation(_ automation: Automation) throws -> Automation {
        var automation = automation
        automation.updatedAt = Date()

        try fileManager.createDirectory(at: paths.sharedAutomations, withIntermediateDirectories: true)
        try writeJSON(
            automation,
            to: paths.sharedAutomations.appendingPathComponent("\(automation.id).json")
        )

        if let index = automations.firstIndex(where: { $0.id == automation.id }) {
            automations[index] = automation
        } else {
            automations.append(automation)
            automations.sort { $0.id < $1.id }
        }
        return automation
    }

    /// Switch an automation on or off. The counterpart of `setSkillEnabled`; see
    /// `setConnectorEnabled` for why this is a setter rather than a re-add.
    public func setAutomationEnabled(id: String, enabled: Bool) throws {
        guard let index = automations.firstIndex(where: { $0.id == id }) else { return }
        automations[index].enabled = enabled
        try writeAutomation(automations[index])
    }

    public func removeAutomation(id: String) throws {
        try? fileManager.removeItem(
            at: paths.sharedAutomations.appendingPathComponent("\(id).json")
        )
        automations.removeAll { $0.id == id }
    }

    public var enabledAutomations: [Automation] { automations.filter(\.enabled) }

    /// Record the outcome of a run. Separate from `writeAutomation` so the
    /// runner does not have to re-send a whole value it just read.
    public func recordRun(id: String, at date: Date, result: String) throws {
        guard let index = automations.firstIndex(where: { $0.id == id }) else { return }
        automations[index].lastRun = date
        automations[index].lastResult = result
        try writeAutomation(automations[index])
    }

    // MARK: - JSON helpers

    /// The sidecar that holds what `SKILL.md` cannot express.
    private struct SkillMetadata: Codable {
        var enabled: Bool
        var updatedAt: Date
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from file: URL) -> T? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func writeJSON<T: Encodable>(_ value: T, to file: URL) throws {
        // Deterministic bytes with unescaped slashes, so rewriting an unchanged
        // value does not churn the file and a diff means something.
        try JSONText.encode(value).write(to: file, atomically: true, encoding: .utf8)
    }
}
