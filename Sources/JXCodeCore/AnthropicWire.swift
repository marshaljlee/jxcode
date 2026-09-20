import Foundation

// MARK: - Request

/// A request in the shape Claude Code sends.
///
/// Modelled on the Anthropic Messages API. Only the fields a router has to
/// understand are declared; anything unrecognised is ignored rather than
/// rejected, so a newer client does not break the proxy.
public struct AnthropicRequest: Codable, Sendable {
    public var model: String
    public var maxTokens: Int
    public var system: AnthropicSystem?
    public var messages: [AnthropicMessage]
    public var tools: [AnthropicTool]?
    public var toolChoice: AnthropicToolChoice?
    public var temperature: Double?
    public var topP: Double?
    public var stopSequences: [String]?
    public var stream: Bool?
    public var metadata: [String: JSONValue]?
    public var thinking: AnthropicThinking?

    public init(
        model: String,
        maxTokens: Int,
        system: AnthropicSystem? = nil,
        messages: [AnthropicMessage],
        tools: [AnthropicTool]? = nil,
        toolChoice: AnthropicToolChoice? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        stopSequences: [String]? = nil,
        stream: Bool? = nil,
        metadata: [String: JSONValue]? = nil,
        thinking: AnthropicThinking? = nil
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.temperature = temperature
        self.topP = topP
        self.stopSequences = stopSequences
        self.stream = stream
        self.metadata = metadata
        self.thinking = thinking
    }

    enum CodingKeys: String, CodingKey {
        case model, system, messages, tools, temperature, stream, metadata, thinking
        case maxTokens = "max_tokens"
        case toolChoice = "tool_choice"
        case topP = "top_p"
        case stopSequences = "stop_sequences"
    }
}

/// `system` is either a bare string or an array of content blocks.
///
/// Both forms are in active use, and the block form is what carries
/// `cache_control` — which OpenAI-compatible backends have no equivalent for.
public enum AnthropicSystem: Codable, Sendable, Hashable {
    case text(String)
    case blocks([AnthropicContentBlock])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
            return
        }
        self = .blocks(try container.decode([AnthropicContentBlock].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):   try container.encode(text)
        case .blocks(let blocks): try container.encode(blocks)
        }
    }

    /// All text blocks joined. `cache_control` and other block metadata are lost
    /// here, deliberately — there is nowhere to put them upstream.
    public var plainText: String {
        switch self {
        case .text(let text):
            return text
        case .blocks(let blocks):
            return blocks.compactMap { block -> String? in
                if case .text(let text) = block { return text }
                return nil
            }.joined(separator: "\n\n")
        }
    }
}

public struct AnthropicMessage: Codable, Sendable, Hashable {
    /// `user` or `assistant`.
    public var role: String
    public var content: AnthropicMessageContent

    public init(role: String, content: AnthropicMessageContent) {
        self.role = role
        self.content = content
    }

    public init(role: String, text: String) {
        self.role = role
        self.content = .text(text)
    }
}

public enum AnthropicMessageContent: Codable, Sendable, Hashable {
    case text(String)
    case blocks([AnthropicContentBlock])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
            return
        }
        self = .blocks(try container.decode([AnthropicContentBlock].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):     try container.encode(text)
        case .blocks(let blocks): try container.encode(blocks)
        }
    }

    public var blocks: [AnthropicContentBlock] {
        switch self {
        case .text(let text):     return [.text(text)]
        case .blocks(let blocks): return blocks
        }
    }

    public var plainText: String {
        blocks.compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }.joined()
    }
}

/// A content block, discriminated by its `type` field.
public enum AnthropicContentBlock: Codable, Sendable, Hashable {
    case text(String)
    case image(mediaType: String, base64: String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: JSONValue, isError: Bool)
    case thinking(String)
    /// Recognised but not forwarded — most upstreams have no slot for it.
    case unknown(type: String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? "unknown"

        switch type {
        case "text":
            self = .text(try container.decodeIfPresent(String.self, forKey: .text) ?? "")

        case "image":
            let source = try container.decodeIfPresent(ImageSource.self, forKey: .source)
            self = .image(
                mediaType: source?.mediaType ?? "image/png",
                base64: source?.data ?? ""
            )

        case "tool_use":
            self = .toolUse(
                id: try container.decodeIfPresent(String.self, forKey: .id) ?? "",
                name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
                input: try container.decodeIfPresent(JSONValue.self, forKey: .input) ?? .object([:])
            )

        case "tool_result":
            self = .toolResult(
                toolUseID: try container.decodeIfPresent(String.self, forKey: .toolUseID) ?? "",
                content: try container.decodeIfPresent(JSONValue.self, forKey: .content) ?? .null,
                isError: try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            )

        case "thinking":
            self = .thinking(try container.decodeIfPresent(String.self, forKey: .thinking) ?? "")

        default:
            self = .unknown(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)

        case .image(let mediaType, let base64):
            try container.encode("image", forKey: .type)
            try container.encode(
                ImageSource(type: "base64", mediaType: mediaType, data: base64),
                forKey: .source
            )

        case .toolUse(let id, let name, let input):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)

        case .toolResult(let toolUseID, let content, let isError):
            try container.encode("tool_result", forKey: .type)
            try container.encode(toolUseID, forKey: .toolUseID)
            try container.encode(content, forKey: .content)
            if isError { try container.encode(true, forKey: .isError) }

        case .thinking(let thinking):
            try container.encode("thinking", forKey: .type)
            try container.encode(thinking, forKey: .thinking)

        case .unknown(let type):
            try container.encode(type, forKey: .type)
        }
    }

    /// Plain text, for the block kinds that carry any.
    public var textValue: String? {
        switch self {
        case .text(let text):        return text
        case .thinking(let thinking): return thinking
        default:                     return nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, text, source, id, name, input, content, thinking, data
        case toolUseID = "tool_use_id"
        case isError = "is_error"
    }

    struct ImageSource: Codable, Hashable {
        var type: String
        var mediaType: String
        var data: String

        enum CodingKeys: String, CodingKey {
            case type, data
            case mediaType = "media_type"
        }
    }
}

public struct AnthropicTool: Codable, Sendable, Hashable {
    public var name: String
    public var description: String?
    public var inputSchema: JSONValue

    public init(name: String, description: String? = nil, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
}

public struct AnthropicToolChoice: Codable, Sendable, Hashable {
    /// `auto`, `any`, `tool`, or `none`.
    public var type: String
    public var name: String?
    public var disableParallelToolUse: Bool?

    public init(type: String, name: String? = nil, disableParallelToolUse: Bool? = nil) {
        self.type = type
        self.name = name
        self.disableParallelToolUse = disableParallelToolUse
    }

    enum CodingKeys: String, CodingKey {
        case type, name
        case disableParallelToolUse = "disable_parallel_tool_use"
    }
}

public struct AnthropicThinking: Codable, Sendable, Hashable {
    public var type: String
    public var budgetTokens: Int?

    public init(type: String, budgetTokens: Int? = nil) {
        self.type = type
        self.budgetTokens = budgetTokens
    }

    enum CodingKeys: String, CodingKey {
        case type
        case budgetTokens = "budget_tokens"
    }
}

// MARK: - Response

public struct AnthropicResponse: Codable, Sendable {
    public var id: String
    public var type: String
    public var role: String
    public var model: String
    public var content: [AnthropicContentBlock]
    public var stopReason: String?
    public var stopSequence: String?
    public var usage: AnthropicUsage

    public init(
        id: String,
        type: String = "message",
        role: String = "assistant",
        model: String,
        content: [AnthropicContentBlock],
        stopReason: String? = nil,
        stopSequence: String? = nil,
        usage: AnthropicUsage
    ) {
        self.id = id
        self.type = type
        self.role = role
        self.model = model
        self.content = content
        self.stopReason = stopReason
        self.stopSequence = stopSequence
        self.usage = usage
    }

    enum CodingKeys: String, CodingKey {
        case id, type, role, model, content, usage
        case stopReason = "stop_reason"
        case stopSequence = "stop_sequence"
    }
}

public struct AnthropicUsage: Codable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

public struct AnthropicCountTokensResponse: Codable, Sendable {
    public var inputTokens: Int

    public init(inputTokens: Int) {
        self.inputTokens = inputTokens
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
    }
}

/// Anthropic's error envelope. Claude Code reads `error.message` to decide
/// whether to retry, so errors must be shaped like this rather than sent as a
/// bare status code.
public struct AnthropicErrorEnvelope: Codable, Sendable {
    public struct Body: Codable, Sendable {
        public var type: String
        public var message: String
    }
    public var type: String = "error"
    public var error: Body

    public init(type: String, message: String) {
        self.error = Body(type: type, message: message)
    }

    public init(message: String) {
        self.error = Body(type: "api_error", message: message)
    }
}

// MARK: - Server-sent events

/// Frames Anthropic streaming events.
///
/// The wire format is `event: <name>\ndata: <json>\n\n`. Getting the blank line
/// wrong makes the client buffer forever, so it is generated in one place.
public enum AnthropicSSE {

    public static func frame(event: String, payload: JSONValue) -> String {
        "event: \(event)\ndata: \(payload.jsonString())\n\n"
    }

    public static func messageStart(
        messageID: String,
        model: String,
        inputTokens: Int
    ) -> String {
        frame(event: "message_start", payload: .object([
            "type": .string("message_start"),
            "message": .object([
                "id": .string(messageID),
                "type": .string("message"),
                "role": .string("assistant"),
                "model": .string(model),
                "content": .array([]),
                "stop_reason": .null,
                "stop_sequence": .null,
                "usage": .object([
                    "input_tokens": .number(Double(inputTokens)),
                    "output_tokens": .number(0),
                ]),
            ]),
        ]))
    }

    public static func contentBlockStart(index: Int, block: JSONValue) -> String {
        frame(event: "content_block_start", payload: .object([
            "type": .string("content_block_start"),
            "index": .number(Double(index)),
            "content_block": block,
        ]))
    }

    public static func textBlockStart(index: Int) -> String {
        contentBlockStart(index: index, block: .object([
            "type": .string("text"),
            "text": .string(""),
        ]))
    }

    public static func toolBlockStart(index: Int, id: String, name: String) -> String {
        contentBlockStart(index: index, block: .object([
            "type": .string("tool_use"),
            "id": .string(id),
            "name": .string(name),
            "input": .object([:]),
        ]))
    }

    public static func textDelta(index: Int, text: String) -> String {
        frame(event: "content_block_delta", payload: .object([
            "type": .string("content_block_delta"),
            "index": .number(Double(index)),
            "delta": .object([
                "type": .string("text_delta"),
                "text": .string(text),
            ]),
        ]))
    }

    public static func thinkingDelta(index: Int, thinking: String) -> String {
        frame(event: "content_block_delta", payload: .object([
            "type": .string("content_block_delta"),
            "index": .number(Double(index)),
            "delta": .object([
                "type": .string("thinking_delta"),
                "thinking": .string(thinking),
            ]),
        ]))
    }

    public static func inputJSONDelta(index: Int, partialJSON: String) -> String {
        frame(event: "content_block_delta", payload: .object([
            "type": .string("content_block_delta"),
            "index": .number(Double(index)),
            "delta": .object([
                "type": .string("input_json_delta"),
                "partial_json": .string(partialJSON),
            ]),
        ]))
    }

    public static func contentBlockStop(index: Int) -> String {
        frame(event: "content_block_stop", payload: .object([
            "type": .string("content_block_stop"),
            "index": .number(Double(index)),
        ]))
    }

    /// The closing event pair's first half.
    ///
    /// `inputTokens` is included when the upstream reported a real count, which
    /// arrives in a usage-only chunk *after* `finish_reason` — too late for
    /// `message_start`. Anthropic's own format carries it here too, so this is
    /// the one place a late-arriving prompt count can still reach the client.
    public static func messageDelta(
        stopReason: String,
        outputTokens: Int,
        inputTokens: Int? = nil
    ) -> String {
        var usage: [String: JSONValue] = [
            "output_tokens": .number(Double(outputTokens)),
        ]
        if let inputTokens {
            usage["input_tokens"] = .number(Double(inputTokens))
        }
        return frame(event: "message_delta", payload: .object([
            "type": .string("message_delta"),
            "delta": .object([
                "stop_reason": .string(stopReason),
                "stop_sequence": .null,
            ]),
            "usage": .object(usage),
        ]))
    }

    public static func messageStop() -> String {
        frame(event: "message_stop", payload: .object([
            "type": .string("message_stop"),
        ]))
    }

    public static func ping() -> String {
        frame(event: "ping", payload: .object(["type": .string("ping")]))
    }
}
