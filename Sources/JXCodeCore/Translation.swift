import Foundation

// MARK: - Result

/// A translated request plus a record of what could not be carried across.
///
/// The notes are surfaced in the app's provider pane and written to the router
/// log. Silent loss is what makes a translation layer maddening to debug —
/// "why did my model stop using tools" is almost always a field that vanished
/// here.
public struct TranslationResult: Sendable {
    public var request: OpenAIChatRequest
    public var notes: [String]

    public init(request: OpenAIChatRequest, notes: [String] = []) {
        self.request = request
        self.notes = notes
    }
}

/// A translated request plus a record of what could not be carried across, for
/// the direction whose target is the Anthropic wire.
///
/// A separate type rather than a generic one because the two results carry
/// different requests, and the notes are the only thing they have in common —
/// which is not enough to be worth a type parameter at every call site.
public struct AnthropicTranslationResult: Sendable {
    public var request: AnthropicRequest
    public var notes: [String]

    public init(request: AnthropicRequest, notes: [String] = []) {
        self.request = request
        self.notes = notes
    }
}

/// A translated response plus a record of what could not be carried across.
///
/// The response direction had no such channel until this existed, which made it
/// the quiet half of the pair: a `fallback` block or a `server_tool_use` on the
/// way out to an OpenAI-shaped client was dropped by a `default:` arm that said
/// nothing to anyone. The request direction has reported its losses since it was
/// written; this is the other side catching up.
public struct TranslatedResponse: Sendable {
    public var response: OpenAIChatResponse
    public var notes: [String]

    public init(response: OpenAIChatResponse, notes: [String] = []) {
        self.response = response
        self.notes = notes
    }
}

/// Translates between the Anthropic Messages API and OpenAI Chat Completions.
///
/// This is the piece that makes a non-Anthropic backend usable from Claude
/// Code. The two formats disagree on four things that matter in practice:
///
///  1. **Tool results live in different places.** Anthropic puts `tool_result`
///     blocks inside a `user` message; OpenAI requires a separate message with
///     role `tool` and a matching `tool_call_id`. Getting the order wrong makes
///     the upstream reject the whole conversation.
///  2. **Tool call arguments are objects on one side and a JSON *string* on the
///     other.** Anthropic sends `input` as a real object; OpenAI sends
///     `arguments` as a string that has to be re-parsed on the way back.
///  3. **`system` is a message on one side and a top-level field on the other**,
///     and on Anthropic's side it may be an array of blocks carrying
///     `cache_control`.
///  4. **Stop reasons and streaming event names differ entirely.**
///
/// Everything below is shaped by those four asymmetries.
public enum Translation {

    // MARK: - Request: Anthropic -> OpenAI

    /// Convert an Anthropic request into an OpenAI one.
    public static func request(_ source: AnthropicRequest) -> TranslationResult {
        var notes: [String] = []
        var messages: [OpenAIMessage] = []

        if let system = source.system {
            let text = system.plainText
            if !text.isEmpty {
                messages.append(OpenAIMessage(role: "system", text: text))
            }
            if case .blocks = system {
                notes.append("system: block metadata (e.g. cache_control) dropped")
            }
        }

        // Counted by *type* rather than as one number, because "3 unsupported
        // block(s) dropped" leaves the user with a count and no way to act on
        // it. `redacted_thinking` and `web_search_tool_result` are different
        // problems — the first is opaque reasoning the user cannot replace, the
        // second is a tool the client asked for and will not be told about.
        var droppedBlocks: [String: Int] = [:]
        var splitToolResults = 0
        /// Every `tool_use` id the conversation has declared so far. A
        /// `tool_result` naming an id that is not in here is a block OpenAI
        /// backends are free to reject, and some do.
        var declaredToolUseIDs: Set<String> = []
        var orphanToolResults = 0

        for message in source.messages {
            let blocks = message.content.blocks

            if message.role == "assistant" {
                var text = ""
                var toolCalls: [OpenAIToolCall] = []

                for block in blocks {
                    switch block {
                    case .text(let value):
                        text += value

                    case .toolUse(let id, let name, let input):
                        declaredToolUseIDs.insert(id)
                        toolCalls.append(OpenAIToolCall(
                            id: id,
                            type: "function",
                            function: OpenAIFunctionCall(
                                name: name,
                                arguments: input.jsonString()
                            )
                        ))

                    case .thinking:
                        droppedBlocks["thinking", default: 0] += 1

                    case .unknown(let type, _):
                        droppedBlocks[type, default: 0] += 1

                    case .image, .toolResult:
                        // Neither is legal on an assistant turn. Ignore rather
                        // than fail, so a malformed client still gets an answer.
                        droppedBlocks[block.typeName, default: 0] += 1
                    }
                }

                if text.isEmpty && toolCalls.isEmpty {
                    // An assistant turn with nothing in it upsets strict
                    // backends. Drop it instead of sending an empty message.
                    continue
                }

                messages.append(OpenAIMessage(
                    role: "assistant",
                    content: text.isEmpty ? nil : .text(text),
                    toolCalls: toolCalls.isEmpty ? nil : toolCalls
                ))
            } else {
                // Anthropic allows one user message to carry both tool results
                // and fresh text. OpenAI needs the tool results as their own
                // messages, and they must come first.
                var toolMessages: [OpenAIMessage] = []
                var parts: [OpenAIContentPart] = []
                var plainText = ""
                var hasImages = false

                for block in blocks {
                    switch block {
                    case .text(let value):
                        plainText += value
                        parts.append(.text(value))

                    case .image(let mediaType, let base64):
                        hasImages = true
                        parts.append(.image(dataURI: "data:\(mediaType);base64,\(base64)"))

                    case .toolResult(let toolUseID, let content, let isError):
                        if !declaredToolUseIDs.contains(toolUseID) { orphanToolResults += 1 }
                        let text = content.flattenedText
                        toolMessages.append(OpenAIMessage(
                            role: "tool",
                            content: .text(text.isEmpty && isError ? "Tool failed with no output." : text),
                            toolCallID: toolUseID
                        ))
                        splitToolResults += 1

                    case .thinking:
                        droppedBlocks["thinking", default: 0] += 1

                    case .unknown(let type, _):
                        droppedBlocks[type, default: 0] += 1

                    case .toolUse:
                        droppedBlocks["tool_use", default: 0] += 1
                    }
                }

                messages.append(contentsOf: toolMessages)

                if !plainText.isEmpty || hasImages {
                    // Plain text stays a bare string, which every backend
                    // accepts; only reach for the parts array when an image
                    // forces it.
                    let content: OpenAIMessageContent = hasImages
                        ? .parts(parts)
                        : .text(plainText)
                    messages.append(OpenAIMessage(role: "user", content: content))
                }
            }
        }

        // Every OpenAI-compatible backend expects at least one non-system turn,
        // and most reject a conversation that never addresses the model. A
        // conversation of assistant-only turns reaches here whenever the user
        // turns were empty and got dropped.
        if !messages.contains(where: { $0.role == "user" }) {
            messages.append(OpenAIMessage(role: "user", text: "Hello"))
            notes.append("no user content found; substituted a placeholder turn")
        }

        var tools: [OpenAITool]?
        if let sourceTools = source.tools, !sourceTools.isEmpty {
            tools = sourceTools.map { tool in
                OpenAITool(function: OpenAIFunctionDefinition(
                    name: tool.name,
                    description: tool.description,
                    parameters: tool.inputSchema
                ))
            }
        }

        let request = OpenAIChatRequest(
            model: source.model,
            messages: messages,
            maxTokens: source.maxTokens,
            temperature: source.temperature,
            topP: source.topP,
            stop: source.stopSequences,
            tools: tools,
            toolChoice: toolChoice(source.toolChoice),
            parallelToolCalls: parallelToolCalls(source.toolChoice),
            stream: source.stream,
            // Without this, OpenAI-compatible servers omit the final usage
            // chunk and the client's token accounting stays at zero.
            streamOptions: (source.stream == true) ? OpenAIStreamOptions(includeUsage: true) : nil
        )

        // `thinking` keeps its own sentence rather than joining the tally,
        // because it is the one block kind whose loss is not a formatting
        // detail: the model's own prior reasoning is what a thinking
        // conversation is made of, and the sentence says so.
        if let thinking = droppedBlocks["thinking"] {
            notes.append("\(thinking) thinking block(s) dropped — upstream has no equivalent")
        }
        let otherDropped = droppedBlocks.filter { $0.key != "thinking" }
        if !otherDropped.isEmpty {
            notes.append(
                "\(otherDropped.values.reduce(0, +)) block(s) dropped with no OpenAI "
                + "equivalent: \(Self.tally(otherDropped))"
            )
        }
        if splitToolResults > 0 {
            notes.append("\(splitToolResults) tool_result block(s) split into tool messages")
        }
        // The mirror of the reverse direction's orphan check, and the same
        // defect seen from the other side: a `tool_result` that names no
        // `tool_use` is a block a strict backend rejects, and the user's next
        // move is the same in both directions — find out why the transcript is
        // inconsistent.
        if orphanToolResults > 0 {
            notes.append(
                "\(orphanToolResults) tool_result block(s) name a tool_use this conversation "
                + "does not contain — some backends reject the turn for it"
            )
        }
        if source.thinking != nil {
            notes.append("thinking parameter dropped — enable reasoning in the model or its template instead")
        }
        if source.metadata != nil {
            notes.append("metadata dropped")
        }

        return TranslationResult(request: request, notes: notes)
    }

    /// Anthropic's four modes collapse onto OpenAI's three, plus the object form.
    static func toolChoice(_ choice: AnthropicToolChoice?) -> OpenAIToolChoice? {
        guard let choice else { return nil }
        switch choice.type {
        case "auto":  return .mode("auto")
        case "any":   return .mode("required")
        case "none":  return .mode("none")
        case "tool":
            guard let name = choice.name else { return .mode("required") }
            return .function(name: name)
        default:
            return .mode("auto")
        }
    }

    static func parallelToolCalls(_ choice: AnthropicToolChoice?) -> Bool? {
        guard let disable = choice?.disableParallelToolUse else { return nil }
        return !disable
    }

    /// Render a per-type tally as `1 server_tool_use, 2 thinking`.
    ///
    /// Sorted by type, so the same conversation always produces the same
    /// sentence. A note whose wording depends on dictionary iteration order is
    /// one a user cannot compare between two runs, and one no test can pin.
    static func tally(_ counts: [String: Int]) -> String {
        counts
            .sorted { $0.key < $1.key }
            .map { "\($0.value) \($0.key)" }
            .joined(separator: ", ")
    }

    // MARK: - Response: OpenAI -> Anthropic

    /// Convert a complete OpenAI response into an Anthropic one.
    public static func response(
        _ source: OpenAIChatResponse,
        requestedModel: String,
        inputTokens: Int? = nil
    ) -> AnthropicResponse {
        let choice = source.first
        let message = choice?.message

        var content: [AnthropicContentBlock] = []

        if let reasoning = message?.anyReasoning, !reasoning.isEmpty {
            // No signature, and deliberately not an empty one. Anthropic's
            // `signature` is an integrity check over the trace; a backend that
            // is not Anthropic has nothing to check it against, and inventing
            // `""` would assert an integrity nobody verified. An absent field
            // says "no signature" truthfully. Verified against llama-server
            // build 10150: its OpenAI wire carries `reasoning_content` and no
            // signature field at all.
            content.append(.thinking(text: reasoning, signature: nil))
        }

        let text = message?.content?.plainText ?? ""
        if !text.isEmpty {
            content.append(.text(text))
        }

        for call in message?.toolCalls ?? [] {
            content.append(.toolUse(
                id: call.id ?? newToolUseID(),
                name: call.function?.name ?? "",
                input: JSONValue.parse(call.function?.arguments ?? "{}")
            ))
        }

        if content.isEmpty {
            // Anthropic clients expect at least one block; an empty array can
            // make them render nothing at all and look like a hang.
            content.append(.text(""))
        }

        let promptTokens = source.usage?.promptTokens ?? inputTokens ?? 0
        let completionTokens = source.usage?.completionTokens ?? TokenEstimator.count(text)

        return AnthropicResponse(
            id: source.id ?? newMessageID(),
            model: requestedModel,
            content: content,
            stopReason: stopReason(
                finishReason: choice?.finishReason,
                hasToolUse: content.contains { block in
                    if case .toolUse = block { return true }
                    return false
                }
            ),
            usage: AnthropicUsage(
                inputTokens: promptTokens,
                outputTokens: completionTokens
            )
        )
    }

    /// Map OpenAI's `finish_reason` onto Anthropic's `stop_reason`.
    static func stopReason(finishReason: String?, hasToolUse: Bool) -> String {
        // Trust the content over the label. Several backends report `stop` even
        // when the turn ended in a tool call, and Claude Code only continues the
        // agent loop when it sees `tool_use`.
        if hasToolUse { return "tool_use" }

        switch finishReason {
        case "length":         return "max_tokens"
        case "tool_calls":     return "tool_use"
        case "function_call":  return "tool_use"
        case "content_filter": return "end_turn"
        default:               return "end_turn"
        }
    }

    public static func newMessageID() -> String {
        "msg_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))
    }

    static func newToolUseID() -> String {
        "toolu_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))
    }

    // MARK: - Streaming: OpenAI chunks -> Anthropic events

    /// Stateful translator for one streaming response.
    ///
    /// Anthropic's stream is a small state machine — `message_start`, then a
    /// sequence of `content_block_start` / `content_block_delta` /
    /// `content_block_stop` triples, then `message_delta` and `message_stop`.
    /// OpenAI's is a flat run of deltas with no explicit block boundaries, so
    /// this type synthesises the boundaries as it goes.
    ///
    /// The block index matters: the client keys its rendering off it, and a
    /// re-used or out-of-order index makes text appear in the wrong place or
    /// overwrite itself.
    ///
    /// **Call `finalize()` when the upstream stream ends** (on `[DONE]` or on
    /// EOF). Termination is deliberately *not* emitted on `finish_reason`,
    /// because with `stream_options.include_usage` the real token counts arrive
    /// in a later chunk with an empty `choices` array. Closing the message early
    /// throws those away and leaves the client's context accounting on an
    /// estimate forever.
    public struct StreamTranslator: Sendable {

        private enum OpenBlock: Sendable, Equatable {
            case text(Int)
            case thinking(Int)
            case tool(Int)

            var index: Int {
                switch self {
                case .text(let i), .thinking(let i), .tool(let i): return i
                }
            }
        }

        private let messageID: String
        private let model: String
        private let inputTokens: Int

        private var started = false
        private var finalized = false
        private var nextIndex = 0
        private var open: OpenBlock?

        /// Identifies each tool call across chunks and maps it onto the Anthropic
        /// block index it was assigned.
        ///
        /// The key is the `index` when the backend sends one, then the call's
        /// `id`, then its name — never a constant. Keying every index-less call
        /// alike made the second of two parallel calls read as a continuation of
        /// the first: its id and name dropped, its arguments appended to the
        /// other call's JSON.
        ///
        /// The id is kept beside the index so that a *changed* id at an index
        /// already in use is recognised as a distinct call rather than as another
        /// fragment of the previous one.
        private var toolBlocks: [String: (index: Int, id: String?)] = [:]
        private var sawToolUse = false
        private var outputCharacters = 0

        /// Set when `finish_reason` arrives, consumed by `finalize()`.
        private var pendingStopReason: String?
        private var reportedUsage: OpenAIUsage?

        public init(
            messageID: String = Translation.newMessageID(),
            model: String,
            inputTokens: Int
        ) {
            self.messageID = messageID
            self.model = model
            self.inputTokens = inputTokens
        }

        /// Feed one parsed upstream chunk, get back the frames to write.
        public mutating func consume(_ chunk: OpenAIChatResponse) -> [String] {
            // A chunk after finalize is either a duplicate terminator or a
            // usage-only trailer already accounted for. Ignore it rather than
            // emitting events outside a message.
            guard !finalized else { return [] }

            var out: [String] = []
            let choice = chunk.first

            if !started {
                started = true
                out.append(AnthropicSSE.messageStart(
                    messageID: messageID,
                    model: model,
                    inputTokens: chunk.usage?.promptTokens ?? inputTokens
                ))
            }

            if let usage = chunk.usage {
                reportedUsage = usage
            }

            // Reasoning first: a model that thinks before answering sends it
            // ahead of any content, and the block order should reflect that.
            if let reasoning = choice?.payload?.anyReasoning, !reasoning.isEmpty {
                out.append(contentsOf: appendThinking(reasoning))
            }

            if let text = choice?.payload?.content?.plainText, !text.isEmpty {
                out.append(contentsOf: appendText(text))
            }

            for call in choice?.payload?.toolCalls ?? [] {
                out.append(contentsOf: appendToolCall(call))
            }

            if let reason = choice?.finishReason {
                // No more deltas are coming for this choice, so the open block
                // can be closed now — but the message itself stays open until
                // the usage trailer has been seen.
                if let block = open {
                    out.append(AnthropicSSE.contentBlockStop(index: block.index))
                    open = nil
                }
                pendingStopReason = reason
            }

            return out
        }

        /// Close out the stream. Safe to call more than once; only the first
        /// call produces frames.
        ///
        /// Call this when the upstream connection ends even if no chunk carried
        /// a `finish_reason` — some backends just close the socket, and a client
        /// that never receives `message_stop` hangs forever.
        public mutating func finalize() -> [String] {
            guard started, !finalized else { return [] }
            finalized = true

            var out: [String] = []
            if let block = open {
                out.append(AnthropicSSE.contentBlockStop(index: block.index))
                open = nil
            }

            // The upstream's own count when it sent one; otherwise fall back to
            // a character-based estimate so the client never sees zero.
            let outputTokens = reportedUsage?.completionTokens
                ?? max(outputCharacters / 4, 1)

            out.append(AnthropicSSE.messageDelta(
                stopReason: Translation.stopReason(
                    finishReason: pendingStopReason,
                    hasToolUse: sawToolUse
                ),
                outputTokens: outputTokens,
                inputTokens: reportedUsage?.promptTokens
            ))
            out.append(AnthropicSSE.messageStop())
            return out
        }

        /// The model name to report, so the router and the log agree.
        public var reportedModel: String { model }

        // MARK: Block helpers

        private mutating func appendThinking(_ text: String) -> [String] {
            var out: [String] = []

            if case .thinking = open {
                // Same block, just more text.
            } else {
                if let block = open {
                    out.append(AnthropicSSE.contentBlockStop(index: block.index))
                }
                let index = nextIndex
                nextIndex += 1
                open = .thinking(index)
                out.append(AnthropicSSE.contentBlockStart(index: index, block: .object([
                    "type": .string("thinking"),
                    "thinking": .string(""),
                ])))
            }

            guard let block = open else { return out }
            outputCharacters += text.count
            out.append(AnthropicSSE.thinkingDelta(index: block.index, thinking: text))
            return out
        }

        private mutating func appendText(_ text: String) -> [String] {
            var out: [String] = []

            if case .text = open {
                // Same block, just more text.
            } else {
                if let block = open {
                    out.append(AnthropicSSE.contentBlockStop(index: block.index))
                }
                let index = nextIndex
                nextIndex += 1
                open = .text(index)
                out.append(AnthropicSSE.textBlockStart(index: index))
            }

            guard let block = open else { return out }
            outputCharacters += text.count
            out.append(AnthropicSSE.textDelta(index: block.index, text: text))
            return out
        }

        private mutating func appendToolCall(_ call: OpenAIToolCall) -> [String] {
            var out: [String] = []

            // How this call is recognised across chunks: `index` when the backend
            // sends one, otherwise the id, otherwise the name. Never a constant —
            // keying every index-less call alike is what made the second of two
            // parallel calls read as a continuation of the first.
            let key: String?
            if let index = call.index {
                key = "index:\(index)"
            } else if let id = call.id, !id.isEmpty {
                key = "id:\(id)"
            } else if let name = call.function?.name, !name.isEmpty {
                key = "name:\(name)"
            } else {
                key = nil
            }

            // A continuation, but only if the id agrees: a different id at an
            // index already in use is a different call, not another fragment of
            // the one before it.
            if let key, let known = toolBlocks[key],
               call.id == nil || call.id == known.id {
                // Only the argument fragment is new.
                if let fragment = call.function?.arguments, !fragment.isEmpty {
                    out.append(AnthropicSSE.inputJSONDelta(index: known.index, partialJSON: fragment))
                }
                return out
            }

            // First sighting of this tool call. A backend that omits `index`
            // entirely sends the whole call in one chunk, so the id or the name
            // is what marks the start of a new one.
            let isNewCall = call.id != nil || call.function?.name != nil
            guard isNewCall else {
                // Argument fragment with no index, no id and no preceding start
                // — attribute it to the most recent tool block rather than
                // dropping it, which would corrupt the arguments.
                if let last = toolBlocks.values.map({ $0.index }).max(),
                   let fragment = call.function?.arguments, !fragment.isEmpty {
                    out.append(AnthropicSSE.inputJSONDelta(index: last, partialJSON: fragment))
                }
                return out
            }

            if let block = open {
                out.append(AnthropicSSE.contentBlockStop(index: block.index))
                open = nil
            }

            let index = nextIndex
            nextIndex += 1
            open = .tool(index)
            if let key { toolBlocks[key] = (index: index, id: call.id) }
            sawToolUse = true

            out.append(AnthropicSSE.toolBlockStart(
                index: index,
                id: call.id ?? Translation.newToolUseID(),
                name: call.function?.name ?? ""
            ))

            if let fragment = call.function?.arguments, !fragment.isEmpty {
                out.append(AnthropicSSE.inputJSONDelta(index: index, partialJSON: fragment))
            }
            return out
        }
    }

    /// The upstream's own error, when a streaming chunk is one.
    ///
    /// An OpenAI-compatible server reports a failure *inside* the stream as a
    /// chunk carrying `error` and no `choices`. There is no status code left to
    /// carry it — the response head went out long ago — so the chunk is the
    /// only place the failure can be. `OpenAIChatResponse` requires `choices`,
    /// so such a chunk fails to decode and was swallowed by the same `try?`
    /// that exists to tolerate a malformed token delta. The stream then ended
    /// normally, `finalize()` wrote `message_stop`, and a client that asked a
    /// question was handed a successful empty answer.
    ///
    /// Returns the message to report, or `nil` for a chunk that is not an error.
    public static func streamError(inChunk data: Data) -> String? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let object) = value,
              let error = object["error"], error != .null else { return nil }
        if case .object(let fields) = error, let message = fields["message"]?.stringValue {
            return message
        }
        let flattened = error.flattenedText
        return flattened.isEmpty ? "the backend reported an error mid-stream" : flattened
    }

    // MARK: - Reverse direction

    /// Convert an Anthropic response into an OpenAI one.
    ///
    /// Only needed when an agent speaks OpenAI but the selected provider is
    /// natively Anthropic — the reverse of the usual direction.
    public static func openAIResponse(from source: AnthropicResponse) -> TranslatedResponse {
        var text = ""
        var reasoning: String?
        var toolCalls: [OpenAIToolCall] = []
        var droppedBlocks: [String: Int] = [:]
        var signaturesDropped = 0

        for block in source.content {
            switch block {
            case .text(let value):
                text += value

            case .thinking(let value, let signature):
                reasoning = (reasoning ?? "") + value
                if signature != nil { signaturesDropped += 1 }

            case .toolUse(let id, let name, let input):
                // The ordinal among tool calls, not the block's position in
                // `content`. An OpenAI client reads `index` to decide which call
                // a fragment belongs to; a block index counts thinking and text
                // blocks too, so a single tool call that followed a thinking
                // block arrived as `index: 1` and a client keying an array off
                // it found a hole at 0.
                toolCalls.append(OpenAIToolCall(
                    index: toolCalls.count,
                    id: id,
                    type: "function",
                    function: OpenAIFunctionCall(name: name, arguments: input.jsonString())
                ))

            case .image, .toolResult, .unknown:
                droppedBlocks[block.typeName, default: 0] += 1
            }
        }

        let finish: String
        switch source.stopReason {
        case "tool_use":   finish = "tool_calls"
        case "max_tokens": finish = "length"
        default:           finish = "stop"
        }

        var notes: [String] = []
        if !droppedBlocks.isEmpty {
            notes.append(
                "\(droppedBlocks.values.reduce(0, +)) block(s) dropped with no OpenAI "
                + "equivalent: \(tally(droppedBlocks))"
            )
        }
        if signaturesDropped > 0 {
            notes.append(
                "\(signaturesDropped) thinking signature(s) dropped — the OpenAI wire "
                + "has no field to carry an Anthropic signature"
            )
        }

        return TranslatedResponse(
            response: OpenAIChatResponse(
                id: source.id,
                object: "chat.completion",
                created: Int(Date().timeIntervalSince1970),
                model: source.model,
                choices: [OpenAIChoice(
                    index: 0,
                    message: OpenAIMessage(
                        role: "assistant",
                        content: .text(text),
                        toolCalls: toolCalls.isEmpty ? nil : toolCalls,
                        reasoningContent: reasoning
                    ),
                    finishReason: finish
                )],
                usage: OpenAIUsage(
                    promptTokens: source.usage.inputTokens,
                    completionTokens: source.usage.outputTokens,
                    totalTokens: source.usage.inputTokens + source.usage.outputTokens
                )
            ),
            notes: notes
        )
    }

    /// Re-frame a complete OpenAI response as the SSE chunk sequence a streaming
    /// caller expects.
    ///
    /// The mirror of `StreamTranslator`, for the one path where the answer has to
    /// be fetched whole: a caller that speaks OpenAI, pointed at a natively
    /// Anthropic provider. The router cannot forward the Anthropic event stream —
    /// the caller parses OpenAI chunks and would not understand
    /// `content_block_delta` — and it cannot hand back a buffered body either,
    /// because a client that asked for `stream: true` is reading SSE. So the
    /// request goes out with `stream: false` and the finished answer is framed
    /// here.
    ///
    /// Correct, and deliberately not incremental: the caller sees the whole
    /// answer arrive at once rather than token by token. The alternative on this
    /// path is a 500.
    ///
    /// The sequence is the one real OpenAI output uses, and it is three chunks
    /// rather than one for the same reason `StreamTranslator` does not close a
    /// message on `finish_reason`: the usage counts arrive in a *later* chunk
    /// with an empty `choices` array, and a client that asked for
    /// `stream_options.include_usage` reads them from there.
    public static func openAISSEFrames(from response: OpenAIChatResponse) -> [String] {
        let choice = response.first
        let id = response.id ?? newMessageID()
        let created = response.created ?? Int(Date().timeIntervalSince1970)
        let model = response.model ?? ""

        var delta: [String: JSONValue] = ["role": .string("assistant")]
        // Whatever the forward path reads back out of a delta has to be written
        // here: `StreamTranslator` looks for `anyReasoning`, so a reasoning
        // model's chain of thought survives this direction too.
        if let reasoning = choice?.payload?.anyReasoning, !reasoning.isEmpty {
            delta["reasoning_content"] = .string(reasoning)
        }
        if let text = choice?.payload?.content?.plainText, !text.isEmpty {
            delta["content"] = .string(text)
        }
        if let calls = choice?.payload?.toolCalls, !calls.isEmpty {
            delta["tool_calls"] = .array(calls.enumerated().map { offset, call in
                .object([
                    "index": .number(Double(call.index ?? offset)),
                    "id": .string(call.id ?? newToolUseID()),
                    "type": .string(call.type ?? "function"),
                    "function": .object([
                        "name": .string(call.function?.name ?? ""),
                        "arguments": .string(call.function?.arguments ?? "{}"),
                    ]),
                ])
            })
        }

        var frames = [
            OpenAISSE.chunk(id: id, created: created, model: model, delta: delta),
            OpenAISSE.chunk(
                id: id,
                created: created,
                model: model,
                delta: [:],
                finishReason: choice?.finishReason ?? "stop"
            ),
        ]

        if let reported = response.usage {
            frames.append(OpenAISSE.usageChunk(
                id: id,
                created: created,
                model: model,
                usage: .object([
                    "prompt_tokens": .number(Double(reported.promptTokens ?? 0)),
                    "completion_tokens": .number(Double(reported.completionTokens ?? 0)),
                    "total_tokens": .number(Double(reported.totalTokens ?? 0)),
                ])
            ))
        }

        frames.append(SSEWriter.done)
        return frames
    }

    /// Convert an Anthropic request into an OpenAI one for the reverse direction.
    ///
    /// Reuses the forward path; the field mapping is identical.
    public static func openAIRequest(from source: AnthropicRequest) -> OpenAIChatRequest {
        request(source).request
    }

    /// Convert an OpenAI request into an Anthropic one.
    ///
    /// Needed when an agent that speaks OpenAI — Codex, Gemini CLI, oh-my-pi —
    /// is pointed at a natively Anthropic provider. Three constraints from the
    /// target format shape this:
    ///
    ///  - `max_tokens` is **required** by Anthropic and optional in OpenAI, so a
    ///    default has to be supplied rather than passed through as nil.
    ///  - Messages must strictly alternate `user` / `assistant` and must begin
    ///    with `user`. OpenAI has no such rule, and a conversation that split
    ///    tool results out will violate it, so consecutive same-role messages
    ///    get merged.
    ///  - `tool` role messages have no Anthropic equivalent; they become
    ///    `tool_result` blocks collected into a single following `user` message.
    public static func anthropicRequest(from source: OpenAIChatRequest) -> AnthropicTranslationResult {
        var systemParts: [String] = []
        var messages: [AnthropicMessage] = []
        var pendingToolResults: [AnthropicContentBlock] = []
        var notes: [String] = []

        /// Tool-call ids from the most recent assistant turn that no `tool`
        /// message has claimed yet.
        ///
        /// Anthropic requires every `tool_result` to name a `tool_use` in the
        /// message immediately before it, so an id that matches nothing is a
        /// 400 that costs the user the whole turn. OpenAI clients are not
        /// obliged to send `tool_call_id` at all, and one that omits it used to
        /// produce a block reading `"tool_use_id": ""` — which matches nothing
        /// by construction.
        var unclaimedToolUseIDs: [String] = []
        var orphanedToolResults = 0
        var unmatchedToolResults = 0

        func flushToolResults() {
            guard !pendingToolResults.isEmpty else { return }
            appendMerging(
                AnthropicMessage(role: "user", content: .blocks(pendingToolResults)),
                into: &messages
            )
            pendingToolResults = []
        }

        for message in source.messages {
            switch message.role {
            case "system", "developer":
                let text = message.content?.plainText ?? ""
                if !text.isEmpty { systemParts.append(text) }

            case "tool":
                let text = message.content?.plainText ?? ""
                let claimed: String?
                if let id = message.toolCallID, !id.isEmpty {
                    claimed = id
                    if !unclaimedToolUseIDs.contains(id) { unmatchedToolResults += 1 }
                } else if unclaimedToolUseIDs.count == 1 {
                    // No id, but only one call to match it to. This is
                    // unambiguous, and the alternative is dropping output the
                    // model asked for.
                    claimed = unclaimedToolUseIDs[0]
                } else {
                    // No id and more than one candidate. Guessing is how a tool
                    // result ends up attached to the wrong call, which is worse
                    // than not sending it: the model then reads one tool's
                    // output as another's.
                    claimed = nil
                }

                guard let claimed else {
                    orphanedToolResults += 1
                    break
                }
                unclaimedToolUseIDs.removeAll { $0 == claimed }
                pendingToolResults.append(.toolResult(
                    toolUseID: claimed,
                    content: .string(text),
                    isError: false
                ))

            case "assistant":
                flushToolResults()
                // A new assistant turn replaces the set of ids a tool result
                // may name: the previous turn's calls are settled.
                unclaimedToolUseIDs.removeAll()
                var blocks: [AnthropicContentBlock] = []
                let text = message.content?.plainText ?? ""
                if !text.isEmpty { blocks.append(.text(text)) }
                for call in message.toolCalls ?? [] {
                    let id = call.id ?? newToolUseID()
                    unclaimedToolUseIDs.append(id)
                    blocks.append(.toolUse(
                        id: id,
                        name: call.function?.name ?? "",
                        input: JSONValue.parse(call.function?.arguments ?? "{}")
                    ))
                }
                guard !blocks.isEmpty else { continue }
                appendMerging(
                    AnthropicMessage(role: "assistant", content: .blocks(blocks)),
                    into: &messages
                )

            default:
                flushToolResults()
                var blocks: [AnthropicContentBlock] = []

                switch message.content {
                case .text(let text):
                    if !text.isEmpty { blocks.append(.text(text)) }

                case .parts(let parts):
                    for part in parts {
                        if let text = part.text, !text.isEmpty {
                            blocks.append(.text(text))
                        } else if let image = part.imageURL {
                            // Expect a data URI; a plain https URL has to be
                            // fetched, which the router will not do silently.
                            if let parsed = parseDataURI(image.url) {
                                blocks.append(.image(
                                    mediaType: parsed.mediaType,
                                    base64: parsed.base64
                                ))
                            } else {
                                blocks.append(.text("[image omitted: \(image.url)]"))
                            }
                        }
                    }

                case .none:
                    break
                }

                guard !blocks.isEmpty else { continue }
                appendMerging(
                    AnthropicMessage(role: "user", content: .blocks(blocks)),
                    into: &messages
                )
            }
        }

        flushToolResults()

        if messages.isEmpty {
            messages.append(AnthropicMessage(role: "user", text: "Hello"))
        }
        // Anthropic rejects a conversation that opens with an assistant turn.
        if messages.first?.role == "assistant" {
            messages.insert(AnthropicMessage(role: "user", text: "Continue."), at: 0)
        }

        var tools: [AnthropicTool]?
        if let sourceTools = source.tools, !sourceTools.isEmpty {
            tools = sourceTools.map { tool in
                AnthropicTool(
                    name: tool.function.name,
                    description: tool.function.description,
                    inputSchema: tool.function.parameters
                )
            }
        }

        if orphanedToolResults > 0 {
            notes.append(
                "\(orphanedToolResults) tool result(s) dropped — no tool_call_id, and "
                + "Anthropic refuses a tool_result that names no tool_use"
            )
        }
        if unmatchedToolResults > 0 {
            notes.append(
                "\(unmatchedToolResults) tool result(s) name a tool_use this conversation "
                + "does not contain — Anthropic will refuse the turn"
            )
        }

        return AnthropicTranslationResult(
            request: AnthropicRequest(
                model: source.model,
                // Required upstream, so a missing value becomes a sane default
                // rather than a 400 the user cannot act on.
                maxTokens: source.maxTokens ?? 8192,
                system: systemParts.isEmpty
                    ? nil
                    : .text(systemParts.joined(separator: "\n\n")),
                messages: messages,
                tools: tools,
                toolChoice: anthropicToolChoice(source.toolChoice),
                temperature: source.temperature,
                topP: source.topP,
                stopSequences: source.stop,
                stream: source.stream
            ),
            notes: notes
        )
    }

    /// Append, merging into the previous message when the roles match.
    ///
    /// Anthropic requires strict alternation, and merging is the only way to
    /// satisfy that without inventing filler turns that would confuse the model.
    private static func appendMerging(
        _ message: AnthropicMessage,
        into messages: inout [AnthropicMessage]
    ) {
        guard let last = messages.last, last.role == message.role else {
            messages.append(message)
            return
        }
        messages[messages.count - 1] = AnthropicMessage(
            role: last.role,
            content: .blocks(last.content.blocks + message.content.blocks)
        )
    }

    static func anthropicToolChoice(_ choice: OpenAIToolChoice?) -> AnthropicToolChoice? {
        guard let choice else { return nil }
        switch choice {
        case .mode(let mode):
            switch mode {
            case "required": return AnthropicToolChoice(type: "any")
            case "none":     return AnthropicToolChoice(type: "none")
            default:         return AnthropicToolChoice(type: "auto")
            }
        case .function(let name):
            return AnthropicToolChoice(type: "tool", name: name)
        }
    }

    /// Split a `data:<media-type>;base64,<payload>` URI.
    static func parseDataURI(_ uri: String) -> (mediaType: String, base64: String)? {
        guard uri.hasPrefix("data:"),
              let comma = uri.firstIndex(of: ",") else { return nil }
        let header = String(uri[uri.index(uri.startIndex, offsetBy: 5)..<comma])
        guard header.contains("base64") else { return nil }
        let mediaType = header
            .split(separator: ";")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? "image/png"
        let payload = String(uri[uri.index(after: comma)...])
        guard !payload.isEmpty else { return nil }
        return (mediaType.isEmpty ? "image/png" : mediaType, payload)
    }
}
