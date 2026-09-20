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

        var droppedThinking = 0
        var unknownBlocks = 0
        var splitToolResults = 0

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
                        toolCalls.append(OpenAIToolCall(
                            id: id,
                            type: "function",
                            function: OpenAIFunctionCall(
                                name: name,
                                arguments: input.jsonString()
                            )
                        ))

                    case .thinking:
                        droppedThinking += 1

                    case .unknown:
                        unknownBlocks += 1

                    case .image, .toolResult:
                        // Neither is legal on an assistant turn. Ignore rather
                        // than fail, so a malformed client still gets an answer.
                        unknownBlocks += 1
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
                        let text = content.flattenedText
                        toolMessages.append(OpenAIMessage(
                            role: "tool",
                            content: .text(text.isEmpty && isError ? "Tool failed with no output." : text),
                            toolCallID: toolUseID
                        ))
                        splitToolResults += 1

                    case .thinking:
                        droppedThinking += 1

                    case .unknown:
                        unknownBlocks += 1

                    case .toolUse:
                        unknownBlocks += 1
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

        if droppedThinking > 0 {
            notes.append("\(droppedThinking) thinking block(s) dropped — upstream has no equivalent")
        }
        if unknownBlocks > 0 {
            notes.append("\(unknownBlocks) unsupported block(s) dropped")
        }
        if splitToolResults > 0 {
            notes.append("\(splitToolResults) tool_result block(s) split into tool messages")
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
            content.append(.thinking(reasoning))
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

        /// Maps an OpenAI `tool_calls[].index` onto the Anthropic block index it
        /// was assigned. Backends reuse that index across argument fragments, so
        /// without this every fragment would start a new tool call.
        private var toolBlockIndex: [Int: Int] = [:]
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
            let callIndex = call.index ?? 0

            if let blockIndex = toolBlockIndex[callIndex] {
                // A continuation: only the argument fragment is new.
                if let fragment = call.function?.arguments, !fragment.isEmpty {
                    out.append(AnthropicSSE.inputJSONDelta(index: blockIndex, partialJSON: fragment))
                }
                return out
            }

            // First sighting of this tool call. A backend that omits `index`
            // entirely sends the whole call in one chunk, so treat the id or
            // name as the signal that a new call has begun.
            let isNewCall = call.id != nil || call.function?.name != nil
            guard isNewCall else {
                // Argument fragment with no index and no preceding start —
                // attribute it to the most recent tool block rather than
                // dropping it, which would corrupt the arguments.
                if let last = toolBlockIndex.values.max(),
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
            toolBlockIndex[callIndex] = index
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

    // MARK: - Reverse direction

    /// Convert an Anthropic response into an OpenAI one.
    ///
    /// Only needed when an agent speaks OpenAI but the selected provider is
    /// natively Anthropic — the reverse of the usual direction.
    public static func openAIResponse(from source: AnthropicResponse) -> OpenAIChatResponse {
        var text = ""
        var reasoning: String?
        var toolCalls: [OpenAIToolCall] = []

        for (offset, block) in source.content.enumerated() {
            switch block {
            case .text(let value):
                text += value
            case .thinking(let value):
                reasoning = (reasoning ?? "") + value
            case .toolUse(let id, let name, let input):
                toolCalls.append(OpenAIToolCall(
                    index: offset,
                    id: id,
                    type: "function",
                    function: OpenAIFunctionCall(name: name, arguments: input.jsonString())
                ))
            case .image, .toolResult, .unknown:
                break
            }
        }

        let finish: String
        switch source.stopReason {
        case "tool_use":   finish = "tool_calls"
        case "max_tokens": finish = "length"
        default:           finish = "stop"
        }

        return OpenAIChatResponse(
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
    public static func anthropicRequest(from source: OpenAIChatRequest) -> AnthropicRequest {
        var systemParts: [String] = []
        var messages: [AnthropicMessage] = []
        var pendingToolResults: [AnthropicContentBlock] = []

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
                pendingToolResults.append(.toolResult(
                    toolUseID: message.toolCallID ?? "",
                    content: .string(message.content?.plainText ?? ""),
                    isError: false
                ))

            case "assistant":
                flushToolResults()
                var blocks: [AnthropicContentBlock] = []
                let text = message.content?.plainText ?? ""
                if !text.isEmpty { blocks.append(.text(text)) }
                for call in message.toolCalls ?? [] {
                    blocks.append(.toolUse(
                        id: call.id ?? newToolUseID(),
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

        return AnthropicRequest(
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
