import Foundation

/// What a running `llama-server` reports about the model it actually loaded.
///
/// This exists because the planner's chat-template and projector decisions were
/// *predictions*, and predictions about a GGUF header can be wrong in ways that
/// are invisible until a tool call arrives as prose. `/props` is the server's
/// own answer to the same questions, so it is the only thing that can confirm
/// the prediction rather than restate it.
///
/// The load-bearing field is `chat_template_caps.supports_tools`. When a model
/// embeds no template and maps onto no built-in preset, llama.cpp falls back to
/// a generic format and that flag comes back `false` — which is exactly the
/// silent failure `ChatTemplateLibrary` was written to prevent. Reading it back
/// turns "we think tool calling works" into "the server says it works".
public struct ServerProps: Sendable, Equatable, Codable {

    /// What the loaded chat template can actually express.
    ///
    /// Reported by the server, not derived by us. A field that is absent is
    /// `nil` rather than `false`, because an older build that does not report
    /// capabilities is not the same as one reporting no support.
    public struct TemplateCapabilities: Sendable, Equatable, Codable {
        public let supportsTools: Bool?
        public let supportsToolCalls: Bool?
        public let supportsParallelToolCalls: Bool?
        public let supportsSystemRole: Bool?
        public let supportsObjectArguments: Bool?
        public let supportsTypedContent: Bool?
        public let supportsStringContent: Bool?
        public let supportsPreserveReasoning: Bool?

        public init(
            supportsTools: Bool? = nil,
            supportsToolCalls: Bool? = nil,
            supportsParallelToolCalls: Bool? = nil,
            supportsSystemRole: Bool? = nil,
            supportsObjectArguments: Bool? = nil,
            supportsTypedContent: Bool? = nil,
            supportsStringContent: Bool? = nil,
            supportsPreserveReasoning: Bool? = nil
        ) {
            self.supportsTools = supportsTools
            self.supportsToolCalls = supportsToolCalls
            self.supportsParallelToolCalls = supportsParallelToolCalls
            self.supportsSystemRole = supportsSystemRole
            self.supportsObjectArguments = supportsObjectArguments
            self.supportsTypedContent = supportsTypedContent
            self.supportsStringContent = supportsStringContent
            self.supportsPreserveReasoning = supportsPreserveReasoning
        }

        /// Whether an agent can rely on tool calling here.
        ///
        /// `nil` when the build did not report capabilities at all — callers
        /// should treat that as "unknown" and fall back to the plan's own
        /// prediction, not as a failure.
        public var toolCallingIsUsable: Bool? {
            guard supportsTools != nil || supportsToolCalls != nil else { return nil }
            return (supportsTools ?? false) && (supportsToolCalls ?? false)
        }

        /// Every capability the template advertises, for display.
        public var supported: [String] {
            var out: [String] = []
            if supportsTools == true { out.append("tools") }
            if supportsToolCalls == true { out.append("tool calls") }
            if supportsParallelToolCalls == true { out.append("parallel tool calls") }
            if supportsSystemRole == true { out.append("system role") }
            if supportsObjectArguments == true { out.append("object arguments") }
            if supportsTypedContent == true { out.append("typed content") }
            if supportsPreserveReasoning == true { out.append("preserved reasoning") }
            return out
        }
    }

    /// What the loaded model can actually take as input.
    public struct Modalities: Sendable, Equatable, Codable {
        public let vision: Bool
        public let video: Bool
        public let audio: Bool

        public init(vision: Bool = false, video: Bool = false, audio: Bool = false) {
            self.vision = vision
            self.video = video
            self.audio = audio
        }

        public var isMultimodal: Bool { vision || video || audio }
    }

    public let buildInfo: String?
    public let modelPath: String?
    public let modelAlias: String?
    /// The quantisation as the server sees it, e.g. `Q8_0`. Read from the file
    /// rather than the filename, which lies often enough to matter.
    public let modelQuantization: String?
    /// The total context across all slots — what `-c` was set to.
    public let contextLength: Int?
    /// How many slots `-c` is divided between. Anything but 1 means the context
    /// an agent asks for is not the context it gets.
    public let totalSlots: Int?
    /// The legacy chat-format label.
    ///
    /// **This is not a failure signal.** A model using its own Jinja template
    /// reports `Content-only` here, which reads like a fallback and is not —
    /// it is the name of the legacy field, which the Jinja path leaves at its
    /// placeholder. Verified against a real build where tool calling worked
    /// correctly while this read `Content-only`. Judge the template by
    /// `capabilities`, never by this.
    public let chatFormat: String?
    public let capabilities: TemplateCapabilities?
    public let modalities: Modalities?
    public let hasChatTemplate: Bool
    /// Whether `POST /props` can change settings. `GET /props` works either way.
    public let propsEndpointIsWritable: Bool
    public let isSleeping: Bool

    public init(
        buildInfo: String? = nil,
        modelPath: String? = nil,
        modelAlias: String? = nil,
        modelQuantization: String? = nil,
        contextLength: Int? = nil,
        totalSlots: Int? = nil,
        chatFormat: String? = nil,
        capabilities: TemplateCapabilities? = nil,
        modalities: Modalities? = nil,
        hasChatTemplate: Bool = false,
        propsEndpointIsWritable: Bool = false,
        isSleeping: Bool = false
    ) {
        self.buildInfo = buildInfo
        self.modelPath = modelPath
        self.modelAlias = modelAlias
        self.modelQuantization = modelQuantization
        self.contextLength = contextLength
        self.totalSlots = totalSlots
        self.chatFormat = chatFormat
        self.capabilities = capabilities
        self.modalities = modalities
        self.hasChatTemplate = hasChatTemplate
        self.propsEndpointIsWritable = propsEndpointIsWritable
        self.isSleeping = isSleeping
    }
}

// MARK: - Decoding

public extension ServerProps {

    /// Decode a `/props` body.
    ///
    /// Returns `nil` for anything that is not an object, so a router that
    /// proxied an error page cannot be mistaken for a server with no features.
    init?(json: JSONValue) {
        guard case .object(let root) = json else { return nil }

        let generation = root["default_generation_settings"]?.objectValue ?? [:]
        let params = generation["params"]?.objectValue ?? [:]

        let caps = root["chat_template_caps"]?.objectValue

        // Absent is `nil`, not `false`: a build that does not report a
        // capability has told us nothing, and reporting "no support" for it
        // would turn a missing field into a false alarm.
        func cap(_ key: String) -> Bool? {
            caps?[key]?.boolValue
        }

        let modalities = root["modalities"]?.objectValue

        self.init(
            buildInfo: root["build_info"]?.stringValue,
            modelPath: root["model_path"]?.stringValue,
            modelAlias: root["model_alias"]?.stringValue,
            modelQuantization: root["model_ftype"]?.stringValue,
            // `n_ctx` lives under default_generation_settings, not at the root.
            contextLength: generation["n_ctx"]?.intValue,
            totalSlots: root["total_slots"]?.intValue,
            chatFormat: params["chat_format"]?.stringValue,
            capabilities: caps == nil ? nil : TemplateCapabilities(
                supportsTools: cap("supports_tools"),
                supportsToolCalls: cap("supports_tool_calls"),
                supportsParallelToolCalls: cap("supports_parallel_tool_calls"),
                supportsSystemRole: cap("supports_system_role"),
                supportsObjectArguments: cap("supports_object_arguments"),
                supportsTypedContent: cap("supports_typed_content"),
                supportsStringContent: cap("supports_string_content"),
                supportsPreserveReasoning: cap("supports_preserve_reasoning")
            ),
            modalities: modalities.map {
                Modalities(
                    vision: $0["vision"]?.boolValue ?? false,
                    video: $0["video"]?.boolValue ?? false,
                    audio: $0["audio"]?.boolValue ?? false
                )
            },
            // A non-empty template is the thing that matters; an empty string
            // means the server has none and is using a built-in.
            hasChatTemplate: !(root["chat_template"]?.stringValue ?? "").isEmpty,
            propsEndpointIsWritable: root["endpoint_props"]?.boolValue ?? false,
            isSleeping: root["is_sleeping"]?.boolValue ?? false
        )
    }

    init?(data: Data) {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        self.init(json: json)
    }
}

// MARK: - Checking a running server against the plan

public extension ServerProps {

    /// Compare what the server loaded against what the plan intended.
    ///
    /// This is the point of reading `/props` at all. Every check here is
    /// something the plan *predicted* and the server can *contradict* — so a
    /// mismatch is a real finding, not a restatement.
    ///
    /// - Parameters:
    ///   - expectedVision: whether the plan passed `--mmproj`.
    ///   - requestedContext: the `-c` value the plan asked for.
    ///   - expectedSlots: the `--parallel` value the plan asked for.
    func disagreements(
        expectedVision: Bool? = nil,
        requestedContext: Int? = nil,
        expectedSlots: Int? = nil
    ) -> [String] {
        var out: [String] = []

        // The one that matters most: a coding agent is unusable without it, and
        // the failure is a tool call arriving as prose rather than an error.
        if let usable = capabilities?.toolCallingIsUsable, !usable {
            out.append(
                "The loaded chat template does not support tool calling "
                    + "(supports_tools=\(capabilities?.supportsTools.map(String.init) ?? "?"), "
                    + "supports_tool_calls=\(capabilities?.supportsToolCalls.map(String.init) ?? "?")). "
                    + "Agents will emit tool calls as text instead of invoking them. "
                    + "Set a template explicitly with --chat-template."
            )
        }

        if let expectedVision, let modalities {
            if expectedVision, !modalities.vision {
                out.append(
                    "The plan attached a vision projector but the server reports no vision "
                        + "modality, so the projector was not loaded. Check that the mmproj "
                        + "matches this model."
                )
            }
            if !expectedVision, modalities.vision {
                out.append(
                    "The server reports vision support but the plan passed no projector, "
                        + "so llama.cpp found one on its own."
                )
            }
        }

        if let requestedContext, let actual = contextLength, actual != requestedContext {
            out.append(
                "The plan asked for a \(requestedContext)-token context but the server loaded "
                    + "\(actual)."
            )
        }

        // A slot count above 1 silently divides the context, which is the exact
        // failure `--parallel 1` exists to prevent.
        if let expectedSlots, let actual = totalSlots, actual != expectedSlots {
            out.append(
                "The plan asked for \(expectedSlots) slot(s) but the server opened \(actual), "
                    + "so each agent gets a fraction of the context."
            )
        }

        if !hasChatTemplate, capabilities == nil {
            out.append(
                "The server reports no chat template and no capability block, so the "
                    + "prompt format is whatever llama.cpp guessed."
            )
        }

        return out
    }

    /// The window one agent actually gets.
    ///
    /// `contextLength` is the total across *all* slots, so with more than one
    /// slot an agent is given a fraction of it. The plan passes `--parallel 1`
    /// precisely so these are the same number — but `/props` is the
    /// measurement, and when it disagrees the agent's real budget is the
    /// divided figure. That is the number worth telling Claude Code about,
    /// because it is the one that decides whether the first turn fits.
    public var agentContextLength: Int? {
        guard let contextLength, contextLength > 0 else { return nil }
        if let slots = totalSlots, slots > 1 { return contextLength / slots }
        return contextLength
    }

    /// A one-line description for the UI.
    var summary: String {
        var parts: [String] = []
        if let contextLength { parts.append("\(contextLength / 1024)k context") }
        if let totalSlots, totalSlots > 1 { parts.append("\(totalSlots) slots") }
        if let modelQuantization { parts.append(modelQuantization) }
        if let modalities, modalities.isMultimodal {
            var kinds: [String] = []
            if modalities.vision { kinds.append("vision") }
            if modalities.video { kinds.append("video") }
            if modalities.audio { kinds.append("audio") }
            parts.append(kinds.joined(separator: "+"))
        }
        if let usable = capabilities?.toolCallingIsUsable {
            parts.append(usable ? "tool calling" : "no tool calling")
        }
        return parts.isEmpty ? "no details reported" : parts.joined(separator: " · ")
    }
}
