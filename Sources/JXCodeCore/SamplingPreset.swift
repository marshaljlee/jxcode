import Foundation

// MARK: - Sampling
//
// llama.cpp has defaults, and they are not this app's defaults. Out of the box
// it samples at temperature 0.8 / top-k 40 / top-p 0.95 / min-p 0.05 /
// repeat-penalty 1.1 — settings tuned for chat, where variety is a feature.
//
// A coding agent is the opposite workload. Claude Code and its peers send a
// tool schema and expect a JSON object back; a few tokens of creative licence
// turn that into a parse error, and the same prompt run twice should produce
// the same call so a failure can be reproduced. Temperature 0.8 is therefore
// not a neutral choice here, it is a bug: the model is being asked to be
// spontaneous at the exact moment it needs to be mechanical.
//
// So the presets below are explicit rather than inherited, and the default is
// the deterministic one.

/// How a model samples, as a named preset.
///
/// The values are llama.cpp's documented sampler defaults and its recommended
/// presets, not inventions: `balanced` is deliberately llama.cpp's own default
/// configuration, so choosing it changes nothing about how a model behaves
/// today, and `agent` is the greedy configuration recommended for tool calling.
public enum SamplingPreset: String, Sendable, Codable, CaseIterable {

    /// Emit no sampling flags at all. Whatever llama.cpp decides wins.
    case modelDefault

    /// Greedy decoding, for tool calling.
    case agent

    /// llama.cpp's own defaults. General chat.
    case balanced

    /// Full temperature with DRY repetition control. Exploratory writing.
    case creative

    /// The preset used when nothing else is chosen.
    ///
    /// This is `.agent`, and the reasoning is worth stating because the
    /// opposite choice is the tempting one. The application exists to run
    /// coding agents: its prompts are tool schemas, its expected outputs are
    /// JSON, and its failures need to be reproducible. All three of those
    /// properties come from deterministic sampling and none of them survive
    /// temperature 0.8. A model served through this app is a component of an
    /// agent, not a chat companion, so it should not be sampling creatively
    /// unless a person deliberately asks it to. Anyone who wants conversational
    /// behaviour is one selection away from `balanced`, which is exactly
    /// llama.cpp's default — but they have to make that choice knowingly.
    public static let `default`: SamplingPreset = .agent

    public var label: String {
        switch self {
        case .modelDefault: return "Model default"
        case .agent:        return "Agent (deterministic)"
        case .balanced:     return "Balanced"
        case .creative:     return "Creative"
        }
    }

    public var explanation: String {
        switch self {
        case .modelDefault:
            return "emit no sampling flags and let llama.cpp apply its own defaults."
        case .agent:
            return "greedy decoding, so a tool call is reproducible and its JSON parses."
        case .balanced:
            return "llama.cpp's own defaults, for general conversation."
        case .creative:
            return "high temperature with DRY repetition control, for exploratory writing."
        }
    }

    /// The temperature this preset asks for, or nil when it asks for none.
    public var temperature: Double? {
        switch self {
        case .modelDefault: return nil
        case .agent:        return 0.0
        case .balanced:     return 0.7
        case .creative:     return 1.0
        }
    }

    /// The flags this preset contributes, in the order they should appear.
    ///
    /// Empty for `.modelDefault`, which is the whole point of that case: it is
    /// how a user says "I know what I am doing, leave the sampler alone".
    public var arguments: [LlamaArgument] {
        switch self {
        case .modelDefault:
            return []

        case .agent:
            // Temperature 0 alone would be enough to make this greedy. top-p and
            // top-k are still set explicitly because leaving them at 0.95 / 40
            // reads, in the command line and in the UI, as if a truncation step
            // were doing work — and because a future llama.cpp release changing
            // its default would otherwise silently change this preset's meaning.
            return [
                flag("--temp", 0.0,
                     "greedy decoding: the same prompt must produce the same tool call"),
                flag("--top-p", 1.0,
                     "no nucleus truncation, so nothing competes with the greedy choice"),
                flag("--top-k", 1.0,
                     "keep only the single most likely token"),
                flag("--repeat-penalty", 1.0,
                     "off: penalising repeats distorts code and JSON, which repeat tokens legitimately"),
            ]

        case .balanced:
            return [
                flag("--temp", 0.7,
                     "llama.cpp's default temperature, which reads naturally in conversation"),
                flag("--min-p", 0.05,
                     "drops the unlikely tail without cutting as hard as top-p alone"),
                flag("--top-k", 40.0,
                     "llama.cpp's default shortlist of candidates"),
                flag("--top-p", 0.95,
                     "llama.cpp's default nucleus cut"),
                flag("--repeat-penalty", 1.1,
                     "llama.cpp's default; mild discouragement of loops"),
            ]

        case .creative:
            return [
                flag("--temp", 1.0,
                     "full-temperature sampling, for varied phrasing"),
                flag("--min-p", 0.05,
                     "still removes the implausible tail"),
                flag("--top-k", 0.0,
                     "0 means no top-k limit in llama.cpp, leaving the whole vocabulary in play"),
                flag("--top-p", 1.0,
                     "no nucleus truncation; DRY does the filtering instead"),
                flag("--dry-multiplier", 0.8,
                     "DRY penalises repeated sequences rather than single tokens, which is what "
                         + "keeps long writing from looping"),
                flag("--dry-base", 1.75,
                     "llama.cpp's default DRY base"),
                flag("--xtc-probability", 0.5,
                     "excludes the most obvious tokens half the time, which is what makes the "
                         + "output stop being predictable"),
                flag("--xtc-threshold", 0.1,
                     "only tokens the model is very confident about are eligible for exclusion"),
                // Deliberately 1.0, i.e. off. DRY and repeat_penalty both fight
                // repetition, and stacking them penalises twice for one offence:
                // the prose goes stilted and common words get avoided for no
                // reason. DRY is the better tool here, so it is the only one
                // switched on.
                flag("--repeat-penalty", 1.0,
                     "off: stacking it on top of DRY over-penalises and makes the prose stilted"),
            ]
        }
    }

    /// `LlamaArgument.Category` has no `sampling` case — its cases are model,
    /// multimodal, template, context, memory, performance and server — and the
    /// optimiser that defines it is not ours to change. Sampling flags are
    /// generation settings rather than speed settings, so none of those fit
    /// well; `performance` is the least misleading of them. If a `sampling`
    /// case is ever added, this is the single line that should change.
    private static let category: LlamaArgument.Category = .performance

    private func flag(_ flag: String, _ value: Double, _ reason: String) -> LlamaArgument {
        LlamaArgument(
            flag: flag,
            value: Self.scalar(value),
            reason: reason,
            category: Self.category
        )
    }

    /// Render a sampler value the way llama.cpp writes it.
    ///
    /// llama.cpp takes these as floats but documents and echoes them as
    /// integers where they are integers, and a command line reading
    /// `--top-k 1.0` looks like a mistake to anyone reading it — enough that
    /// people "fix" it. So a value with no fractional part is written without
    /// one. Not private: the rule is easy to break by accident and worth a test
    /// of its own.
    static func scalar(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(value)
    }
}
