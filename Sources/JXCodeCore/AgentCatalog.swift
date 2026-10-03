import Foundation

// MARK: - Agents worth offering
//
// The built-in list is deliberately small: five CLIs, a cloud agent and a
// shell. That is the right *default* — a launcher that ships with twenty cards
// is a launcher nobody reads — but it was also the whole list, with no way to
// add to it except by hand-editing `agents.json`. The app launches arbitrary
// CLIs by design, so the set of things it can launch should not be closed.
//
// `AgentRegistry` has always loaded custom entries; this is the list the Add
// agent sheet offers so that adding one is a click rather than a JSON file, and
// the manual form stays for everything not here.
public enum AgentCatalog {

    /// Agents the dashboard can offer without shipping them as built-ins.
    ///
    /// Each entry is a real CLI with a real install command, and the install
    /// command matters more than it looks: an agent is installed *into the
    /// sandbox*, so anything that writes to a path of its own choosing — a
    /// `curl | bash` installer, a Homebrew tap — is deliberately absent here.
    /// `npm i -g` and `pip` honour the sandbox's prefix, which is what makes
    /// the install land inside rather than on the host.
    public static let discoverable: [AgentDefinition] = [
        AgentDefinition(
            id: "aider",
            name: "Aider",
            command: "aider",
            installCommand: "python3 -m pip install aider-install && aider-install",
            isBuiltIn: true,
            tagline: "Pair-programming in the terminal, git-aware"
        ),
        AgentDefinition(
            id: "crush",
            name: "Crush",
            command: "crush",
            installCommand: "npm i -g @charmland/crush",
            isBuiltIn: true,
            tagline: "Charm's terminal coding agent"
        ),
        AgentDefinition(
            id: "amp",
            name: "Amp",
            command: "amp",
            installCommand: "npm i -g @sourcegraph/amp",
            isBuiltIn: true,
            tagline: "Sourcegraph's coding agent"
        ),
        AgentDefinition(
            id: "qwen",
            name: "Qwen Code",
            command: "qwen",
            installCommand: "npm i -g @qwen-code/qwen-code",
            isBuiltIn: true,
            tagline: "Alibaba's Qwen coding agent"
        ),
        AgentDefinition(
            id: "droid",
            name: "Droid",
            command: "droid",
            installCommand: "npm i -g @factory-ai/droid",
            isBuiltIn: true,
            tagline: "Factory's autonomous coding agent"
        ),
        AgentDefinition(
            id: "kilo",
            name: "Kilo Code",
            command: "kilocode",
            installCommand: "npm i -g @kilocode/cli",
            isBuiltIn: true,
            tagline: "Open-source coding agent for the terminal"
        ),
        AgentDefinition(
            id: "copilot",
            name: "GitHub Copilot CLI",
            command: "copilot",
            installCommand: "npm i -g @github/copilot",
            isBuiltIn: true,
            tagline: "GitHub's coding agent in the terminal"
        )
    ]

    /// The catalog entries the launcher is not already showing.
    public static func suggestions(absentFrom current: [AgentDefinition]) -> [AgentDefinition] {
        let taken = Set(current.map(\.id))
        return discoverable.filter { !taken.contains($0.id) }
    }
}
