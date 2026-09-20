import Foundation

// MARK: - Request

/// A request in the shape most self-hosted backends accept.
///
/// This is the OpenAI Chat Completions format, which is the de-facto
/// interchange format: vLLM, LM Studio, llama-server, Ollama's compatibility
/// layer, OpenRouter, Together and most gateways all speak it.
public struct OpenAIChatRequest: Codable, Sendable {
    public var model: String
    public var messages: [OpenAIMessage]
    public var maxTokens: Int?
    public var temperature: Double?
    public var topP: Double?
    public var stop: [String]?
    public var tools: [OpenAITool]?
    public var toolChoice: OpenAIToolChoice?
    public var parallelToolCalls: Bool?
    public var stream: Bool?
    public var streamOptions: OpenAIStreamOptions?

    public init(
        model: String,
        messages: [OpenAIMessage],
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        stop: [String]? = nil,
        tools: [OpenAITool]? = nil,
        toolChoice: OpenAIToolChoice? = nil,
        parallelToolCalls: Bool? = nil,
        stream: Bool? = nil,
        streamOptions: OpenAIStreamOptions? = nil
    ) {
        self.model = model
        self.messages = messages
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.stop = stop
        self.tools = tools
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.stream = stream
        self.streamOptions = streamOptions
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stop, tools, stream
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case toolChoice = "tool_choice"
        case parallelToolCalls = "parallel_tool_calls"
        case streamOptions = "stream_options"
    }
}

public struct OpenAIMessage: Codable, Sendable {
    /// `system`, `user`, `assistant`, or `tool`.
    public var role: String
    public var content: OpenAIMessageContent?
    public var toolCalls: [OpenAIToolCall]?
    public var toolCallID: String?
    public var name: String?

    /// Chain-of-thought text from a reasoning model.
    ///
    /// vLLM's reasoning parsers, DeepSeek, and several gateways return this
    /// alongside `content`. It maps onto Anthropic's `thinking` blocks, which is
    /// what makes a reasoning model usable from Claude Code instead of having
    /// its reasoning silently discarded.
    public var reasoningContent: String?

    /// OpenRouter's spelling of the same thing.
    public var reasoning: String?

    public init(
        role: String,
        content: OpenAIMessageContent? = nil,
        toolCalls: [OpenAIToolCall]? = nil,
        toolCallID: String? = nil,
        name: String? = nil,
        reasoningContent: String? = nil,
        reasoning: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
        self.reasoningContent = reasoningContent
        self.reasoning = reasoning
    }

    /// Whichever reasoning field the backend populated.
    public var anyReasoning: String? {
        reasoningContent ?? reasoning
    }

    public init(role: String, text: String) {
        self.role = role
        self.content = .text(text)
    }

    /// Hand-written because `role` cannot be required on decode.
    ///
    /// Streaming deltas carry `role` only on the very first chunk — every later
    /// chunk is just `{"delta":{"content":"..."}}`. A synthesised decoder
    /// demands it and throws, and because a failed chunk is skipped rather than
    /// fatal, the symptom is a stream that stops after one token instead of an
    /// error. Some backends omit it in complete responses too.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decodeIfPresent(String.self, forKey: .role) ?? "assistant"
        self.content = try container.decodeIfPresent(OpenAIMessageContent.self, forKey: .content)
        self.toolCalls = try container.decodeIfPresent([OpenAIToolCall].self, forKey: .toolCalls)
        self.toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        self.reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
    }

    /// Always emit `content`, as JSON `null` when absent.
    ///
    /// An assistant turn that contains only tool calls has no text. Several
    /// backends reject the message outright when the key is missing rather than
    /// null, so this is written explicitly instead of relying on the
    /// synthesised encoder (which omits nil optionals).
    ///
    /// Note that `reasoningContent` / `reasoning` are decoded but deliberately
    /// never encoded. Echoing a model's chain of thought back to it is not
    /// wanted in a multi-turn conversation, and some backends reject it.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(name, forKey: .name)
    }

    enum CodingKeys: String, CodingKey {
        case role, content, name, reasoning
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case reasoningContent = "reasoning_content"
    }
}

public enum OpenAIMessageContent: Codable, Sendable, Hashable {
    case text(String)
    case parts([OpenAIContentPart])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
            return
        }
        self = .parts(try container.decode([OpenAIContentPart].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):   try container.encode(text)
        case .parts(let parts): try container.encode(parts)
        }
    }

    public var plainText: String {
        switch self {
        case .text(let text):
            return text
        case .parts(let parts):
            return parts.compactMap(\.text).joined()
        }
    }
}

public struct OpenAIContentPart: Codable, Sendable, Hashable {
    /// `text` or `image_url`.
    public var type: String
    public var text: String?
    public var imageURL: OpenAIImageURL?

    public init(type: String, text: String? = nil, imageURL: OpenAIImageURL? = nil) {
        self.type = type
        self.text = text
        self.imageURL = imageURL
    }

    public static func text(_ value: String) -> OpenAIContentPart {
        OpenAIContentPart(type: "text", text: value)
    }

    public static func image(dataURI: String) -> OpenAIContentPart {
        OpenAIContentPart(type: "image_url", imageURL: OpenAIImageURL(url: dataURI))
    }

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }
}

public struct OpenAIImageURL: Codable, Sendable, Hashable {
    public var url: String

    public init(url: String) {
        self.url = url
    }
}

public struct OpenAITool: Codable, Sendable {
    public var type: String
    public var function: OpenAIFunctionDefinition

    public init(function: OpenAIFunctionDefinition) {
        self.type = "function"
        self.function = function
    }
}

public struct OpenAIFunctionDefinition: Codable, Sendable {
    public var name: String
    public var description: String?
    public var parameters: JSONValue

    public init(name: String, description: String? = nil, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// Either a bare mode string or a specific function.
///
/// Anthropic has four modes (`auto`, `any`, `tool`, `none`) and OpenAI has
/// three (`auto`, `required`, `none`) plus the object form — the asymmetry is
/// why this is an enum rather than a string.
public enum OpenAIToolChoice: Codable, Sendable, Hashable {
    case mode(String)
    case function(name: String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let mode = try? container.decode(String.self) {
            self = .mode(mode)
            return
        }
        struct Wrapper: Codable {
            struct Inner: Codable { var name: String }
            var function: Inner
        }
        let wrapper = try container.decode(Wrapper.self)
        self = .function(name: wrapper.function.name)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .mode(let mode):
            try container.encode(mode)
        case .function(let name):
            try container.encode([
                "type": JSONValue.string("function"),
                "function": .object(["name": .string(name)]),
            ])
        }
    }
}

public struct OpenAIStreamOptions: Codable, Sendable {
    public var includeUsage: Bool?

    public init(includeUsage: Bool? = true) {
        self.includeUsage = includeUsage
    }

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

// MARK: - Response

/// Covers both a complete response and a streaming chunk — the only difference
/// is whether `choices[].message` or `choices[].delta` is populated.
public struct OpenAIChatResponse: Codable, Sendable {
    public var id: String?
    public var object: String?
    public var created: Int?
    public var model: String?
    public var choices: [OpenAIChoice]
    public var usage: OpenAIUsage?

    public init(
        id: String? = nil,
        object: String? = nil,
        created: Int? = nil,
        model: String? = nil,
        choices: [OpenAIChoice],
        usage: OpenAIUsage? = nil
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
    }

    public var first: OpenAIChoice? { choices.first }
}

public struct OpenAIChoice: Codable, Sendable {
    public var index: Int?
    /// Present on a complete response.
    public var message: OpenAIMessage?
    /// Present on a streaming chunk.
    public var delta: OpenAIMessage?
    public var finishReason: String?

    public init(
        index: Int? = nil,
        message: OpenAIMessage? = nil,
        delta: OpenAIMessage? = nil,
        finishReason: String? = nil
    ) {
        self.index = index
        self.message = message
        self.delta = delta
        self.finishReason = finishReason
    }

    /// Whichever of `message` / `delta` this chunk carries.
    public var payload: OpenAIMessage? { message ?? delta }

    enum CodingKeys: String, CodingKey {
        case index, message, delta
        case finishReason = "finish_reason"
    }
}

public struct OpenAIUsage: Codable, Sendable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

/// A tool call, in either complete or streaming form.
///
/// When streaming, the id and name arrive on the first chunk for an index and
/// the arguments arrive as a sequence of fragments that must be concatenated.
public struct OpenAIToolCall: Codable, Sendable, Hashable {
    public var index: Int?
    public var id: String?
    public var type: String?
    public var function: OpenAIFunctionCall?

    public init(
        index: Int? = nil,
        id: String? = nil,
        type: String? = "function",
        function: OpenAIFunctionCall? = nil
    ) {
        self.index = index
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct OpenAIFunctionCall: Codable, Sendable, Hashable {
    public var name: String?
    public var arguments: String?

    public init(name: String? = nil, arguments: String? = nil) {
        self.name = name
        self.arguments = arguments
    }
}

/// The model list envelope. Shared by OpenAI, Anthropic and llama-server, which
/// all use `{"data":[{"id":...}]}`; Ollama differs and is handled separately.
public struct OpenAIModelList: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var id: String
        public var object: String?
        public var created: Int?
        public var ownedBy: String?

        enum CodingKeys: String, CodingKey {
            case id, object, created
            case ownedBy = "owned_by"
        }
    }

    public var data: [Entry]
}

/// Ollama's native model list.
public struct OllamaTagList: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var name: String
        public var model: String?
    }

    public var models: [Entry]
}

// MARK: - Server-sent events

/// Frames OpenAI streaming chunks.
///
/// The mirror of `AnthropicSSE`, and in the same place relative to its own wire
/// types. `SSEWriter.frame` writes the `data: …\n\n` envelope; this supplies the
/// chunk bodies.
public enum OpenAISSE {

    /// One `chat.completion.chunk`.
    ///
    /// `delta` carries only what changed, which is OpenAI's own convention and
    /// what every client's parser expects. `finish_reason` is written explicitly
    /// as null on every chunk but the last: a missing key and a null one are not
    /// the same thing to a strict client.
    public static func chunk(
        id: String,
        created: Int,
        model: String,
        delta: [String: JSONValue],
        finishReason: String? = nil
    ) -> String {
        SSEWriter.frame(data: JSONValue.object([
            "id": .string(id),
            "object": .string("chat.completion.chunk"),
            "created": .number(Double(created)),
            "model": .string(model),
            "choices": .array([
                .object([
                    "index": .number(0),
                    "delta": .object(delta),
                    "finish_reason": finishReason.map { JSONValue.string($0) } ?? .null,
                ])
            ]),
        ]).jsonString())
    }

    /// The trailing usage-only chunk: an empty `choices` array and the counts.
    ///
    /// Real OpenAI output sends this after the `finish_reason` chunk, which is
    /// exactly why `StreamTranslator` refuses to close a message on
    /// `finish_reason` alone. A client that asked for
    /// `stream_options.include_usage` takes its token counts from here, so
    /// omitting it leaves its context accounting on an estimate for the rest of
    /// the session.
    public static func usageChunk(
        id: String,
        created: Int,
        model: String,
        usage: JSONValue
    ) -> String {
        SSEWriter.frame(data: JSONValue.object([
            "id": .string(id),
            "object": .string("chat.completion.chunk"),
            "created": .number(Double(created)),
            "model": .string(model),
            "choices": .array([]),
            "usage": usage,
        ]).jsonString())
    }
}
