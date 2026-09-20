import Foundation

// MARK: - Chat templates
//
// A chat template is the thing that turns a list of messages into the exact
// string a model was trained to read. Get it wrong and nothing crashes: the
// model simply receives a prompt in a format it has never seen, and degrades
// into something that answers plausibly and calls tools never. That silence is
// what makes this worth a dedicated type.
//
// llama.cpp has two sources for a template. The good one is the model file
// itself (`tokenizer.chat_template`), used when `--jinja` is passed. The
// fallback is a table of templates compiled into llama.cpp, selected with
// `--chat-template <name>`. The optimiser currently only ever uses the first,
// so a GGUF that ships no template — which is common for community
// quantisations, and for anything converted with an old script — is served
// with llama.cpp's generic guess.
//
// This type supplies the missing second path. It maps `general.architecture`
// onto one of the built-in names, and it is deliberately conservative: see
// `presetName(for:vocabularySize:)`.

/// Maps a model's architecture onto one of llama.cpp's built-in chat templates.
public struct ChatTemplateLibrary: Sendable {

    /// Where the template that will be used comes from.
    public enum Source: Sendable, Equatable {
        /// The model file carries its own template.
        case embedded
        /// Use `--chat-template <name>`.
        case builtInPreset(String)
        /// Nothing suitable was found.
        case none
    }

    /// Whether the template that will be used can express a tool call.
    ///
    /// This is the question that decides whether a coding agent works, and the
    /// answer is knowable before the model is ever loaded — but only for a
    /// template we can read. It exists because preferring the model's own
    /// template is right in general and wrong in one specific case: a small
    /// model whose author never wrote tool handling into it. A real example on
    /// this machine is a 1.1B model carrying a 410-character template of plain
    /// `<|user|>` / `<|assistant|>` role tags. Nothing about that file looks
    /// broken, and llama.cpp accepts it happily — the model just answers in
    /// prose when an agent asks for a tool.
    public enum ToolCallingSupport: String, Sendable, Equatable, Codable {
        /// The template handles tools, so tool calling should work.
        case supported
        /// The template contains no tool handling at all.
        case unsupported
        /// Not determinable from what we hold — a built-in preset's body is
        /// compiled into llama.cpp, not into this app.
        case unknown
    }

    /// The outcome of looking for a template, ready to be appended to a plan.
    public struct Resolution: Sendable, Equatable {
        public let source: Source
        public let arguments: [LlamaArgument]
        /// Human-readable, shown in the UI next to the flags.
        public let note: String
        /// What we can tell about tool calling before the model is loaded.
        public let toolCalling: ToolCallingSupport

        /// False only for `.none`, i.e. the model will run on llama.cpp's
        /// generic fallback.
        public var isResolved: Bool {
            if case .none = source { return false }
            return true
        }

        /// A warning worth showing the user, or `nil` when there is nothing to
        /// say.
        ///
        /// Separate from `note` because the two do different jobs: `note`
        /// explains the choice, this says the choice has a consequence the user
        /// probably did not intend.
        public var warning: String? {
            guard toolCalling == .unsupported else { return nil }
            return "This model's own chat template has no tool handling, so tool calling will "
                + "not work: an agent will receive its tool calls as plain text instead of as "
                + "structured calls. That is a property of the model file, not of this app. "
                + "Choose a model whose template supports tools for agent work, or force one "
                + "with --chat-template."
        }
    }

    /// Every template name llama.cpp build 10150 accepts for `--chat-template`.
    ///
    /// Taken from that build's own `--help`, so it is a list of names that
    /// actually exist rather than a list that looks plausible. Nothing here is
    /// invented, and nothing outside it may be emitted: an unrecognised name
    /// makes llama-server exit at startup, which is at least a loud failure,
    /// but a name that is merely *close* to the right one would be a quiet one.
    public static let builtInPresetNames: [String] = [
        "bailing",
        "bailing-think",
        "bailing2",
        "chatglm3",
        "chatglm4",
        "chatml",
        "command-r",
        "deepseek",
        "deepseek-ocr",
        "deepseek2",
        "deepseek3",
        "exaone-moe",
        "exaone3",
        "exaone4",
        "falcon3",
        "gemma",
        "gigachat",
        "glmedge",
        "gpt-oss",
        "granite",
        "granite-4.0",
        "granite-4.1",
        "grok-2",
        "hunyuan-dense",
        "hunyuan-moe",
        "hunyuan-vl",
        "kimi-k2",
        "llama2",
        "llama2-sys",
        "llama2-sys-bos",
        "llama2-sys-strip",
        "llama3",
        "llama4",
        "megrez",
        "minicpm",
        "mistral-v1",
        "mistral-v3",
        "mistral-v3-tekken",
        "mistral-v7",
        "mistral-v7-tekken",
        "monarch",
        "openchat",
        "orion",
        "pangu-embedded",
        "phi3",
        "phi4",
        "rwkv-world",
        "seed_oss",
        "smolvlm",
        "solar-open",
        "vicuna",
        "vicuna-orca",
        "yandex",
        "zephyr",
    ]

    /// Decide how this model should be given a chat template.
    ///
    /// - Parameters:
    ///   - architecture: `general.architecture` from the GGUF header.
    ///   - embeddedTemplate: `tokenizer.chat_template`, if the file has one.
    ///   - vocabularySize: used only to tell Llama 2 from Llama 3.
    public static func resolve(
        architecture: String?,
        embeddedTemplate: String?,
        vocabularySize: Int? = nil
    ) -> Resolution {
        // The model's own template wins whenever it exists. A built-in preset
        // is somebody's re-implementation of a template for a family, and it
        // can only ever approximate a specific file: Qwen3-VL, for instance,
        // ships a template with no built-in equivalent, and so do fine-tunes
        // whose authors changed the tool-call format. Preferring the file is
        // preferring the format the weights were actually trained on.
        if let raw = embeddedTemplate,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let template = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let toolCalling = Self.toolCallingSupport(inTemplate: template)
            return Resolution(
                source: .embedded,
                arguments: [
                    LlamaArgument(
                        flag: "--jinja",
                        reason: "use the \(template.count)-character chat template stored in the "
                            + "model file, which is what this model was trained on",
                        category: .template
                    )
                ],
                note: "The model file carries its own chat template, so it is used in preference "
                    + "to any built-in preset. A preset could only approximate it.",
                toolCalling: toolCalling
            )
        }

        if let architecture, let preset = presetName(for: architecture, vocabularySize: vocabularySize) {
            return Resolution(
                source: .builtInPreset(preset),
                arguments: [
                    LlamaArgument(
                        flag: "--chat-template",
                        value: preset,
                        reason: "the model file has no template, so llama.cpp's built-in "
                            + "'\(preset)' template stands in for \(normalised(architecture))",
                        category: .template
                    )
                ],
                note: "No template is stored in the model file. llama.cpp's built-in '\(preset)' "
                    + "template is used instead, because \(normalised(architecture)) models are "
                    + "trained on that format. Without it, tool calling would fall back to a "
                    + "generic format and usually break.",
                // The preset's body lives in llama.cpp, not here, so claiming
                // either way would be a guess. Several of these presets do
                // support tools and several do not.
                toolCalling: .unknown
            )
        }

        let subject = architecture.map { "\(normalised($0))" } ?? "This model"
        return Resolution(
            source: .none,
            arguments: [],
            note: "\(subject) stores no chat template and no built-in preset is known to match it, "
                + "so llama.cpp will use its generic fallback. Tool calling may not work. If you "
                + "know the right format, set --chat-template <name> yourself; the accepted names "
                + "are in llama-server --help.",
            // The existing note already says tool calling may not work, so a
            // second warning saying the same thing is noise. Unknown, not
            // unsupported: we have not read the fallback either.
            toolCalling: .unknown
        )
    }

    /// Decide whether a Jinja chat template handles tools at all.
    ///
    /// A text search, which is a crude tool for the job — but the alternative
    /// is rendering the template, and the question only needs a yes or no. A
    /// template that supports tool calling has to read the `tools` variable
    /// llama.cpp injects, or the `tool_calls` / `tool_call_id` fields it puts
    /// on messages; there is no way to emit a structured call without
    /// referencing one of them. So their absence is strong evidence, and their
    /// presence — even in a branch this particular request never takes — is
    /// enough to say the format exists.
    ///
    /// Deliberately biased towards `supported`: a false "unsupported" would
    /// warn about a model that works, which is worse than staying quiet about
    /// one that does not, because the runtime check against `/props` catches
    /// the latter anyway.
    static func toolCallingSupport(inTemplate template: String) -> ToolCallingSupport {
        let markers = ["tool_calls", "tool_call", "tool_call_id", "tool_result", "function"]
        let lowered = template.lowercased()
        if markers.contains(where: { lowered.contains($0) }) { return .supported }
        // The bare `tools` variable, matched on word boundaries so that prose
        // like "tools" inside a system prompt is not mistaken for the variable
        // — though a template containing that word is far more likely to be
        // handling it than not.
        if lowered.range(of: #"\btools\b"#, options: .regularExpression) != nil {
            return .supported
        }
        return .unsupported
    }

    /// The built-in preset for an architecture, or nil when there is no
    /// confident answer.
    ///
    /// This function is deliberately small, and everything it declines to do is
    /// the point. A wrong template does not fail — it silently corrupts every
    /// prompt the model ever sees, producing a model that seems stupid rather
    /// than misconfigured, and there is no error message to search for. So a
    /// mapping is only included when the architecture string names one model
    /// family with one prompt format. Anything ambiguous returns nil and the
    /// user gets a warning they can act on instead of a guess they cannot see.
    ///
    /// The comparison is case-insensitive and ignores surrounding whitespace,
    /// because architecture strings come from model files written by many
    /// different conversion scripts.
    public static func presetName(for architecture: String, vocabularySize: Int? = nil) -> String? {
        switch normalised(architecture) {

        // ChatML is the format most of this family converged on, including the
        // MoE variants and the vision models, whose text side is unchanged.
        case "qwen2", "qwen3", "qwen2moe", "qwen3moe", "qwen35", "qwen3vl",
             "yi", "internlm2", "smollm":
            return "chatml"

        case "gemma", "gemma2", "gemma3":
            return "gemma"

        case "phi3":
            return "phi3"
        case "phi4":
            return "phi4"

        case "deepseek":
            return "deepseek"
        case "deepseek2":
            return "deepseek2"
        case "deepseek3":
            return "deepseek3"

        case "mistral":
            return "mistral-v3"

        case "command-r", "commandr":
            return "command-r"

        case "gpt-oss":
            return "gpt-oss"

        case "granite":
            return "granite"

        case "minicpm":
            return "minicpm"

        case "glm4", "chatglm":
            return "chatglm4"

        case "smolvlm":
            return "smolvlm"

        case "hunyuan-moe":
            return "hunyuan-moe"

        case "kimi-k2":
            return "kimi-k2"

        // "llama" is the one genuinely ambiguous architecture in the table, and
        // it is ambiguous in the worst way: Llama 2 and Llama 3 both report it,
        // and their templates differ in whether a system message exists at all,
        // so choosing wrongly breaks the model's instruction following rather
        // than merely degrading it. There is no version field to read, but the
        // vocabulary size separates them — Llama 3 extended the tokenizer from
        // 32k to 128256 — so that is the discriminator.
        //
        // Two bands, not an exact match, and a gap between them:
        //
        //  * Equality is too strict. Fine-tunes add tokens: a real model on
        //    this machine reports 130560 entries, which equals neither 128256
        //    nor 32000 and would have fallen through to `nil` — losing the
        //    template for a model that is unambiguously Llama 3.
        //  * A single cut is too loose in the other direction. A vocabulary
        //    around 50k (GPT-2's 50257, say) is genuinely neither family, and
        //    guessing there is exactly the silent corruption this type exists
        //    to avoid.
        //
        // So answer only when the size is clearly in one family's range, and
        // decline in the middle. Both real cases clear their band by a wide
        // margin, and the ambiguous middle stays unanswered.
        case "llama":
            guard let vocabularySize, vocabularySize > 0 else { return nil }
            if vocabularySize >= 100_000 { return "llama3" }
            if vocabularySize <= 40_000 { return "llama2" }
            return nil

        default:
            return nil
        }
    }

    private static func normalised(_ architecture: String) -> String {
        architecture.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
