import XCTest
@testable import JXCodeCore

// MARK: - Helpers

/// Decode an upstream chunk from JSON so the tests exercise the wire types too,
/// rather than constructing structs that might not match what a real server sends.
private func upstreamChunk(_ json: String) throws -> OpenAIChatResponse {
    try JSONDecoder().decode(OpenAIChatResponse.self, from: Data(json.utf8))
}

/// Split an Anthropic SSE frame back into its event name and payload.
private func parseFrame(_ frame: String) -> (event: String?, payload: JSONValue)? {
    var event: String?
    var data = ""
    for line in frame.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("event: ") {
            event = String(line.dropFirst(7))
        } else if line.hasPrefix("data: ") {
            data += String(line.dropFirst(6))
        }
    }
    guard !data.isEmpty else { return nil }
    return (event, JSONValue.parse(data))
}

private func frames(_ output: [String]) -> [(event: String?, payload: JSONValue)] {
    output.compactMap { parseFrame($0) }
}

private func anthropicRequest(
    model: String = "claude-sonnet-4-5",
    system: AnthropicSystem? = nil,
    messages: [AnthropicMessage],
    tools: [AnthropicTool]? = nil,
    toolChoice: AnthropicToolChoice? = nil,
    stream: Bool? = nil
) -> AnthropicRequest {
    AnthropicRequest(
        model: model,
        maxTokens: 1024,
        system: system,
        messages: messages,
        tools: tools,
        toolChoice: toolChoice,
        stream: stream
    )
}

// MARK: - Request translation

final class TranslationRequestTests: XCTestCase {

    func testSystemStringBecomesLeadingSystemMessage() {
        let request = anthropicRequest(
            system: .text("You are terse."),
            messages: [AnthropicMessage(role: "user", text: "hi")]
        )
        let result = Translation.request(request)

        XCTAssertEqual(result.request.messages.first?.role, "system")
        XCTAssertEqual(result.request.messages.first?.content?.plainText, "You are terse.")
        XCTAssertEqual(result.request.messages.count, 2)
    }

    func testSystemBlockArrayIsFlattenedAndNoted() {
        let request = anthropicRequest(
            system: .blocks([
                .text("First."),
                .text("Second."),
            ]),
            messages: [AnthropicMessage(role: "user", text: "hi")]
        )
        let result = Translation.request(request)

        let system = result.request.messages.first
        XCTAssertEqual(system?.role, "system")
        XCTAssertEqual(system?.content?.plainText, "First.\n\nSecond.")
        // cache_control lives on blocks and has nowhere to go upstream.
        XCTAssertTrue(result.notes.contains { $0.contains("cache_control") })
    }

    func testAbsentSystemProducesNoSystemMessage() {
        let request = anthropicRequest(messages: [AnthropicMessage(role: "user", text: "hi")])
        let result = Translation.request(request)
        XCTAssertFalse(result.request.messages.contains { $0.role == "system" })
    }

    /// The ordering rule that matters most: OpenAI requires `tool` messages to
    /// follow the assistant turn that requested them, and Anthropic puts the
    /// results at the *start* of the next user message alongside any new text.
    func testToolResultsPrecedeUserTextInTheSameTurn() {
        let request = anthropicRequest(messages: [
            AnthropicMessage(role: "user", text: "read the file"),
            AnthropicMessage(role: "assistant", content: .blocks([
                .toolUse(id: "toolu_1", name: "read", input: .object(["path": .string("/a.txt")])),
            ])),
            AnthropicMessage(role: "user", content: .blocks([
                .toolResult(toolUseID: "toolu_1", content: .string("file contents"), isError: false),
                .text("now summarise it"),
            ])),
        ])

        let messages = Translation.request(request).request.messages
        XCTAssertEqual(messages.map(\.role), ["user", "assistant", "tool", "user"])

        let tool = messages[2]
        XCTAssertEqual(tool.toolCallID, "toolu_1")
        XCTAssertEqual(tool.content?.plainText, "file contents")

        XCTAssertEqual(messages[3].content?.plainText, "now summarise it")
    }

    func testToolUseBecomesToolCallWithStringifiedArguments() {
        let request = anthropicRequest(messages: [
            AnthropicMessage(role: "user", text: "go"),
            AnthropicMessage(role: "assistant", content: .blocks([
                .toolUse(id: "toolu_9", name: "search", input: .object([
                    "query": .string("swift"),
                    "limit": .number(3),
                ])),
            ])),
        ])

        let messages = Translation.request(request).request.messages
        let call = try? XCTUnwrap(messages.last?.toolCalls?.first)
        XCTAssertEqual(call?.id, "toolu_9")
        XCTAssertEqual(call?.type, "function")
        XCTAssertEqual(call?.function?.name, "search")

        // Arguments must be a JSON *string*, not an object — that asymmetry is
        // the whole reason the round trip needs care.
        let arguments = call?.function?.arguments ?? ""
        let parsed = JSONValue.parse(arguments)
        XCTAssertEqual(parsed.objectValue?["query"]?.stringValue, "swift")
        XCTAssertEqual(parsed.objectValue?["limit"]?.intValue, 3)
    }

    func testAssistantTurnCarryingOnlyToolCallsHasNullContent() throws {
        let request = anthropicRequest(messages: [
            AnthropicMessage(role: "user", text: "go"),
            AnthropicMessage(role: "assistant", content: .blocks([
                .toolUse(id: "toolu_1", name: "ls", input: .object([:])),
            ])),
        ])

        let assistant = Translation.request(request).request.messages.last
        XCTAssertNil(assistant?.content)
        XCTAssertEqual(assistant?.toolCalls?.count, 1)

        // And it must still serialise `content` as an explicit null, because
        // several backends reject the message when the key is absent.
        let encoded = try JSONEncoder().encode(assistant)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertTrue(object.keys.contains("content"))
        XCTAssertTrue(object["content"] is NSNull)
    }

    func testThinkingBlocksAreDroppedAndCounted() {
        let request = anthropicRequest(messages: [
            AnthropicMessage(role: "user", text: "think"),
            AnthropicMessage(role: "assistant", content: .blocks([
                .thinking("secret reasoning"),
                .text("the answer"),
            ])),
        ])

        let result = Translation.request(request)
        let assistant = result.request.messages.last
        XCTAssertEqual(assistant?.content?.plainText, "the answer")
        XCTAssertTrue(result.notes.contains { $0.contains("1 thinking block") })
    }

    func testAssistantTurnWithOnlyThinkingIsDroppedEntirely() {
        let request = anthropicRequest(messages: [
            AnthropicMessage(role: "user", text: "hi"),
            AnthropicMessage(role: "assistant", content: .blocks([.thinking("...")])),
        ])

        let messages = Translation.request(request).request.messages
        XCTAssertEqual(messages.map(\.role), ["user"])
    }

    func testImageBlockBecomesDataURI() {
        let request = anthropicRequest(messages: [
            AnthropicMessage(role: "user", content: .blocks([
                .text("what is this"),
                .image(mediaType: "image/png", base64: "AAAA"),
            ])),
        ])

        let message = Translation.request(request).request.messages.last
        guard case .parts(let parts) = message?.content else {
            return XCTFail("expected a content parts array when an image is present")
        }
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].text, "what is this")
        XCTAssertEqual(parts[1].type, "image_url")
        XCTAssertEqual(parts[1].imageURL?.url, "data:image/png;base64,AAAA")
    }

    func testTextOnlyMessageStaysABareString() {
        let request = anthropicRequest(messages: [
            AnthropicMessage(role: "user", content: .blocks([.text("one"), .text("two")])),
        ])
        let message = Translation.request(request).request.messages.last
        guard case .text(let value) = message?.content else {
            return XCTFail("expected a bare string, which every backend accepts")
        }
        XCTAssertEqual(value, "onetwo")
    }

    func testToolDefinitionsMapSchemaToParameters() {
        let request = anthropicRequest(
            messages: [AnthropicMessage(role: "user", text: "hi")],
            tools: [AnthropicTool(
                name: "read_file",
                description: "Read a file",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ])
            )]
        )

        let tool = Translation.request(request).request.tools?.first
        XCTAssertEqual(tool?.type, "function")
        XCTAssertEqual(tool?.function.name, "read_file")
        XCTAssertEqual(tool?.function.description, "Read a file")
        XCTAssertEqual(tool?.function.parameters.objectValue?["type"]?.stringValue, "object")
    }

    func testToolChoiceModesMapOntoOpenAIVocabulary() {
        XCTAssertEqual(Translation.toolChoice(AnthropicToolChoice(type: "auto")), .mode("auto"))
        // Anthropic's `any` means "must call something"; OpenAI spells that `required`.
        XCTAssertEqual(Translation.toolChoice(AnthropicToolChoice(type: "any")), .mode("required"))
        XCTAssertEqual(Translation.toolChoice(AnthropicToolChoice(type: "none")), .mode("none"))
        XCTAssertEqual(
            Translation.toolChoice(AnthropicToolChoice(type: "tool", name: "search")),
            .function(name: "search")
        )
        XCTAssertNil(Translation.toolChoice(nil))
    }

    func testDisableParallelToolUseBecomesParallelToolCallsFalse() {
        let request = anthropicRequest(
            messages: [AnthropicMessage(role: "user", text: "hi")],
            toolChoice: AnthropicToolChoice(type: "auto", disableParallelToolUse: true)
        )
        XCTAssertEqual(Translation.request(request).request.parallelToolCalls, false)
    }

    func testStreamingRequestsAskForUsageInTheTrailer() {
        let request = anthropicRequest(
            messages: [AnthropicMessage(role: "user", text: "hi")],
            stream: true
        )
        let result = Translation.request(request)
        XCTAssertEqual(result.request.stream, true)
        // Without include_usage the real token counts never arrive.
        XCTAssertEqual(result.request.streamOptions?.includeUsage, true)
    }

    func testNonStreamingRequestOmitsStreamOptions() {
        let request = anthropicRequest(messages: [AnthropicMessage(role: "user", text: "hi")])
        XCTAssertNil(Translation.request(request).request.streamOptions)
    }

    func testConversationWithNoUserContentGetsAPlaceholderTurn() {
        let request = anthropicRequest(messages: [
            AnthropicMessage(role: "assistant", content: .blocks([.text("orphan")])),
        ])
        let result = Translation.request(request)
        XCTAssertTrue(result.request.messages.contains { $0.role == "user" })
        XCTAssertTrue(result.notes.contains { $0.contains("placeholder") })
    }

    func testTemperatureTopPAndStopPassThrough() {
        var request = anthropicRequest(messages: [AnthropicMessage(role: "user", text: "hi")])
        request.temperature = 0.3
        request.topP = 0.9
        request.stopSequences = ["STOP", "END"]

        let result = Translation.request(request).request
        XCTAssertEqual(result.temperature, 0.3)
        XCTAssertEqual(result.topP, 0.9)
        XCTAssertEqual(result.stop, ["STOP", "END"])
        XCTAssertEqual(result.maxTokens, 1024)
    }
}

// MARK: - Response translation

final class TranslationResponseTests: XCTestCase {

    func testTextResponseBecomesTextBlock() throws {
        let upstream = try upstreamChunk("""
        {"id":"chatcmpl-1","model":"qwen","choices":[
          {"index":0,"message":{"role":"assistant","content":"Hello there"},"finish_reason":"stop"}
        ],"usage":{"prompt_tokens":11,"completion_tokens":3,"total_tokens":14}}
        """)

        let response = Translation.response(upstream, requestedModel: "claude-sonnet-4-5")

        XCTAssertEqual(response.type, "message")
        XCTAssertEqual(response.role, "assistant")
        XCTAssertEqual(response.model, "claude-sonnet-4-5")
        XCTAssertEqual(response.content.count, 1)
        XCTAssertEqual(response.content[0].textValue, "Hello there")
        XCTAssertEqual(response.stopReason, "end_turn")
        XCTAssertEqual(response.usage.inputTokens, 11)
        XCTAssertEqual(response.usage.outputTokens, 3)
    }

    func testToolCallResponseBecomesToolUseBlockWithParsedInput() throws {
        let upstream = try upstreamChunk("""
        {"id":"c2","choices":[{"index":0,"message":{"role":"assistant","content":null,
          "tool_calls":[{"id":"call_7","type":"function",
            "function":{"name":"read_file","arguments":"{\\"path\\":\\"/etc/hosts\\"}"}}]},
          "finish_reason":"tool_calls"}],"usage":{"prompt_tokens":5,"completion_tokens":9}}
        """)

        let response = Translation.response(upstream, requestedModel: "m")
        guard case .toolUse(let id, let name, let input) = response.content.first else {
            return XCTFail("expected a tool_use block")
        }
        XCTAssertEqual(id, "call_7")
        XCTAssertEqual(name, "read_file")
        XCTAssertEqual(input.objectValue?["path"]?.stringValue, "/etc/hosts")
        XCTAssertEqual(response.stopReason, "tool_use")
    }

    /// Some backends report `stop` even when the turn ended in a tool call.
    /// Claude Code only continues the agent loop on `tool_use`, so the content
    /// has to win over the label.
    func testToolUseContentOverridesAStopFinishReason() throws {
        let upstream = try upstreamChunk("""
        {"choices":[{"index":0,"message":{"role":"assistant","content":"",
          "tool_calls":[{"id":"call_1","type":"function",
            "function":{"name":"ls","arguments":"{}"}}]},"finish_reason":"stop"}]}
        """)

        let response = Translation.response(upstream, requestedModel: "m")
        XCTAssertEqual(response.stopReason, "tool_use")
    }

    func testReasoningBecomesThinkingBlockAheadOfText() throws {
        let upstream = try upstreamChunk("""
        {"choices":[{"index":0,"message":{"role":"assistant",
          "reasoning_content":"let me think","content":"answer"},"finish_reason":"stop"}]}
        """)

        let response = Translation.response(upstream, requestedModel: "m")
        XCTAssertEqual(response.content.count, 2)
        XCTAssertEqual(response.content[0].textValue, "let me think")
        XCTAssertEqual(response.content[1].textValue, "answer")
    }

    func testOpenRouterReasoningSpellingIsAlsoRecognised() throws {
        let upstream = try upstreamChunk("""
        {"choices":[{"index":0,"message":{"role":"assistant",
          "reasoning":"thought","content":"answer"},"finish_reason":"stop"}]}
        """)
        let response = Translation.response(upstream, requestedModel: "m")
        XCTAssertEqual(response.content[0].textValue, "thought")
    }

    func testEmptyResponseStillCarriesOneBlock() throws {
        let upstream = try upstreamChunk("""
        {"choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"stop"}]}
        """)
        let response = Translation.response(upstream, requestedModel: "m")
        XCTAssertEqual(response.content.count, 1)
        XCTAssertEqual(response.content[0].textValue, "")
    }

    func testStopReasonTable() {
        XCTAssertEqual(Translation.stopReason(finishReason: "stop", hasToolUse: false), "end_turn")
        XCTAssertEqual(Translation.stopReason(finishReason: "length", hasToolUse: false), "max_tokens")
        XCTAssertEqual(Translation.stopReason(finishReason: "tool_calls", hasToolUse: false), "tool_use")
        XCTAssertEqual(Translation.stopReason(finishReason: "content_filter", hasToolUse: false), "end_turn")
        XCTAssertEqual(Translation.stopReason(finishReason: nil, hasToolUse: false), "end_turn")
        XCTAssertEqual(Translation.stopReason(finishReason: "stop", hasToolUse: true), "tool_use")
    }

    func testMissingUsageFallsBackToAnEstimate() throws {
        let upstream = try upstreamChunk("""
        {"choices":[{"index":0,"message":{"role":"assistant","content":"abcdefghij"},"finish_reason":"stop"}]}
        """)
        let response = Translation.response(upstream, requestedModel: "m", inputTokens: 42)
        XCTAssertEqual(response.usage.inputTokens, 42)
        XCTAssertGreaterThan(response.usage.outputTokens, 0)
    }
}

// MARK: - Streaming

final class TranslationStreamTests: XCTestCase {

    func testTextStreamProducesAWellFormedEventSequence() throws {
        var translator = Translation.StreamTranslator(model: "m", inputTokens: 7)

        var output = translator.consume(try upstreamChunk("""
        {"choices":[{"index":0,"delta":{"role":"assistant","content":"Hel"}}]}
        """))
        output += translator.consume(try upstreamChunk("""
        {"choices":[{"index":0,"delta":{"content":"lo"}}]}
        """))
        output += translator.consume(try upstreamChunk("""
        {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
        """))
        output += translator.consume(try upstreamChunk("""
        {"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":2}}
        """))
        output += translator.finalize()

        let events = frames(output).map(\.event)
        XCTAssertEqual(events, [
            "message_start",
            "content_block_start",
            "content_block_delta",
            "content_block_delta",
            "content_block_stop",
            "message_delta",
            "message_stop",
        ])

        let deltas = frames(output).filter { $0.event == "content_block_delta" }
        XCTAssertEqual(deltas.count, 2)
        XCTAssertEqual(
            deltas[0].payload.objectValue?["delta"]?.objectValue?["text"]?.stringValue,
            "Hel"
        )
    }

    func testBlockIndexIsStableAcrossDeltas() throws {
        var translator = Translation.StreamTranslator(model: "m", inputTokens: 1)
        var output = translator.consume(try upstreamChunk("""
        {"choices":[{"index":0,"delta":{"content":"a"}}]}
        """))
        output += translator.consume(try upstreamChunk("""
        {"choices":[{"index":0,"delta":{"content":"b"}}]}
        """))
        output += translator.consume(try upstreamChunk("""
        {"choices":[{"index":0,"delta":{"content":"c"}}]}
        """))
        output += translator.finalize()

        // One start, three deltas on index 0, one stop — not a start per delta,
        // which would make the client render three separate bubbles.
        XCTAssertEqual(frames(output).filter { $0.event == "content_block_start" }.count, 1)
        let indices = frames(output)
            .filter { $0.event == "content_block_delta" }
            .compactMap { $0.payload.objectValue?["index"]?.intValue }
        XCTAssertEqual(indices, [0, 0, 0])
    }

    /// Tool arguments arrive as a sequence of fragments that must be
    /// concatenated. Re-using the block index is what makes that work.
    func testToolArgumentsAccumulateAcrossChunks() throws {
        var translator = Translation.StreamTranslator(model: "m", inputTokens: 1)
        var output = translator.consume(try upstreamChunk("""
        {"choices":[{"index":0,"delta":{"tool_calls":[
          {"index":0,"id":"call_1","type":"function","function":{"name":"write","arguments":""}}]}}]}
        """))
        output += translator.consume(try upstreamChunk("""
        {"choices":[{"index":0,"delta":{"tool_calls":[
          {"index":0,"function":{"arguments":"{\\"pa"}}]}}]}
        """))
        output += translator.consume(try upstreamChunk("""
        {"choices":[{"index":0,"delta":{"tool_calls":[
          {"index":0,"function":{"arguments":"th\\":\\"x\\"}"}}]}}]}
        """))
        output += translator.consume(try upstreamChunk("""
        {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
        """))
        output += translator.finalize()

        let events = frames(output)
        XCTAssertEqual(events.filter { $0.event == "content_block_start" }.count, 1)

        let start = events.first { $0.event == "content_block_start" }
        let block = start?.payload.objectValue?["content_block"]?.objectValue
        XCTAssertEqual(block?["type"]?.stringValue, "tool_use")
        XCTAssertEqual(block?["name"]?.stringValue, "write")
        XCTAssertEqual(block?["id"]?.stringValue, "call_1")

        // Reassembling the fragments must yield valid JSON.
        let fragments = events
            .filter { $0.event == "content_block_delta" }
            .compactMap { $0.payload.objectValue?["delta"]?.objectValue?["partial_json"]?.stringValue }
        XCTAssertEqual(fragments.count, 2)
        let reassembled = fragments.joined()
        XCTAssertEqual(JSONValue.parse(reassembled).objectValue?["path"]?.stringValue, "x")

        let stop = events.first { $0.event == "message_delta" }
        XCTAssertEqual(
            stop?.payload.objectValue?["delta"]?.objectValue?["stop_reason"]?.stringValue,
            "tool_use"
        )
    }

    func testTwoToolCallsGetDistinctBlockIndices() throws {
        var translator = Translation.StreamTranslator(model: "m", inputTokens: 1)
        var output = translator.consume(try upstreamChunk("""
        {"choices":[{"index":0,"delta":{"tool_calls":[
          {"index":0,"id":"a","function":{"name":"one","arguments":"{}"}},
          {"index":1,"id":"b","function":{"name":"two","arguments":"{}"}}]}}]}
        """))
        output += translator.finalize()

        let starts = frames(output).filter { $0.event == "content_block_start" }
        XCTAssertEqual(starts.count, 2)
        let indices = starts.compactMap { $0.payload.objectValue?["index"]?.intValue }
        XCTAssertEqual(indices, [0, 1])
    }

    func testThinkingThenTextProducesTwoOrderedBlocks() throws {
        var translator = Translation.StreamTranslator(model: "m", inputTokens: 1)
        var output = translator.consume(try upstreamChunk("""
        {"choices":[{"index":0,"delta":{"reasoning_content":"hmm"}}]}
        """))
        output += translator.consume(try upstreamChunk("""
        {"choices":[{"index":0,"delta":{"content":"answer"}}]}
        """))
        output += translator.finalize()

        let events = frames(output)
        let starts = events.filter { $0.event == "content_block_start" }
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(
            starts[0].payload.objectValue?["content_block"]?.objectValue?["type"]?.stringValue,
            "thinking"
        )
        XCTAssertEqual(
            starts[1].payload.objectValue?["content_block"]?.objectValue?["type"]?.stringValue,
            "text"
        )
        // Switching blocks must close the previous one.
        XCTAssertEqual(events.filter { $0.event == "content_block_stop" }.count, 2)
    }

    /// The usage trailer arrives after `finish_reason`. Finalising early would
    /// throw it away and leave the client's context accounting on a guess.
    func testUsageFromTrailerChunkReachesMessageDelta() throws {
        var translator = Translation.StreamTranslator(model: "m", inputTokens: 1)
        var output = translator.consume(try upstreamChunk("""
        {"choices":[{"index":0,"delta":{"content":"hi"}}]}
        """))
        output += translator.consume(try upstreamChunk("""
        {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
        """))
        output += translator.consume(try upstreamChunk("""
        {"choices":[],"usage":{"prompt_tokens":123,"completion_tokens":45}}
        """))
        output += translator.finalize()

        let delta = frames(output).first { $0.event == "message_delta" }
        XCTAssertEqual(delta?.payload.objectValue?["usage"]?.objectValue?["output_tokens"]?.intValue, 45)
        XCTAssertEqual(delta?.payload.objectValue?["usage"]?.objectValue?["input_tokens"]?.intValue, 123)
    }

    func testFinalizeIsIdempotent() throws {
        var translator = Translation.StreamTranslator(model: "m", inputTokens: 1)
        _ = translator.consume(try upstreamChunk("""
        {"choices":[{"index":0,"delta":{"content":"x"}}]}
        """))
        let first = translator.finalize()
        let second = translator.finalize()

        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(second.isEmpty, "a second finalize must not emit a second message_stop")
    }

    /// Some backends just close the socket without ever sending a
    /// `finish_reason`. The client still has to be let go.
    func testFinalizeWithoutFinishReasonStillTerminates() throws {
        var translator = Translation.StreamTranslator(model: "m", inputTokens: 1)
        _ = translator.consume(try upstreamChunk("""
        {"choices":[{"index":0,"delta":{"content":"truncated"}}]}
        """))
        let output = translator.finalize()

        let events = frames(output)
        XCTAssertEqual(events.last?.event, "message_stop")
        XCTAssertEqual(
            events.first { $0.event == "message_delta" }?
                .payload.objectValue?["delta"]?.objectValue?["stop_reason"]?.stringValue,
            "end_turn"
        )
    }

    func testChunksAfterFinalizeAreIgnored() throws {
        var translator = Translation.StreamTranslator(model: "m", inputTokens: 1)
        _ = translator.consume(try upstreamChunk("""
        {"choices":[{"index":0,"delta":{"content":"x"}}]}
        """))
        _ = translator.finalize()
        let late = translator.consume(try upstreamChunk("""
        {"choices":[{"index":0,"delta":{"content":"should not appear"}}]}
        """))
        XCTAssertTrue(late.isEmpty)
    }

    func testMessageStartCarriesTheEstimatedInputCount() throws {
        var translator = Translation.StreamTranslator(model: "m", inputTokens: 777)
        let output = translator.consume(try upstreamChunk("""
        {"choices":[{"index":0,"delta":{"content":"x"}}]}
        """))

        let start = frames(output).first { $0.event == "message_start" }
        let message = start?.payload.objectValue?["message"]?.objectValue
        XCTAssertEqual(message?["id"]?.stringValue?.hasPrefix("msg_"), true)
        XCTAssertEqual(message?["model"]?.stringValue, "m")
        XCTAssertEqual(message?["usage"]?.objectValue?["input_tokens"]?.intValue, 777)
    }
}

// MARK: - SSE framing

final class SSEParserTests: XCTestCase {

    func testEventsSplitAcrossChunksAreReassembled() {
        var parser = SSEParser()

        XCTAssertTrue(parser.feed("data: {\"a\":").isEmpty)
        let events = parser.feed("1}\n\n")

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "{\"a\":1}")
    }

    func testMultipleEventsInOneChunk() {
        var parser = SSEParser()
        let events = parser.feed("data: one\n\ndata: two\n\n")
        XCTAssertEqual(events.map(\.data), ["one", "two"])
    }

    func testEventNameAndMultipleDataLines() {
        var parser = SSEParser()
        let events = parser.feed("event: content_block_delta\ndata: {\"x\":\ndata: 2}\n\n")

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].name, "content_block_delta")
        XCTAssertEqual(events[0].data, "{\"x\":\n2}")
    }

    func testCommentsAreIgnored() {
        var parser = SSEParser()
        XCTAssertTrue(parser.feed(": keep-alive\n\n").isEmpty)
        XCTAssertEqual(parser.feed("data: real\n\n").first?.data, "real")
    }

    func testCRLFIsTolerated() {
        var parser = SSEParser()
        let events = parser.feed("event: ping\r\ndata: {}\r\n\r\n")
        XCTAssertEqual(events.first?.name, "ping")
        XCTAssertEqual(events.first?.data, "{}")
    }

    /// Some backends omit the final blank line. Dropping the last event would
    /// lose the `message_delta` carrying `stop_reason`.
    func testFlushEmitsATrailingUnterminatedEvent() {
        var parser = SSEParser()
        XCTAssertTrue(parser.feed("data: last").isEmpty)
        XCTAssertEqual(parser.flush().first?.data, "last")
    }

    func testDoneSentinelIsRecognised() {
        var parser = SSEParser()
        let events = parser.feed("data: [DONE]\n\n")
        XCTAssertTrue(events.first?.isDone == true)
    }

    func testOneOptionalSpaceAfterColonIsStripped() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed("data:no-space\n\n").first?.data, "no-space")
        XCTAssertEqual(parser.feed("data:  two-spaces\n\n").first?.data, " two-spaces")
    }

    func testWriterProducesTheBlankLineTerminator() {
        let frame = SSEWriter.frame(name: "message_stop", data: "{\"type\":\"message_stop\"}")
        XCTAssertEqual(frame, "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
    }
}

// MARK: - Token estimation

final class TokenEstimatorTests: XCTestCase {

    func testEmptyStringIsZero() {
        XCTAssertEqual(TokenEstimator.count(""), 0)
    }

    func testLatinTextIsRoughlyFourCharsPerToken() {
        let text = String(repeating: "a", count: 400)
        let tokens = TokenEstimator.count(text)
        XCTAssertGreaterThan(tokens, 80)
        XCTAssertLessThan(tokens, 140)
    }

    /// One token per CJK character, so Chinese text must cost noticeably more
    /// than the same character count of Latin text.
    func testCJKCostsMorePerCharacterThanLatin() {
        let chinese = String(repeating: "中", count: 100)
        let latin = String(repeating: "a", count: 100)
        XCTAssertGreaterThan(TokenEstimator.count(chinese), TokenEstimator.count(latin))
        XCTAssertEqual(TokenEstimator.count(chinese), 100)
    }

    func testImageBlocksUseAFlatEstimate() {
        XCTAssertEqual(
            TokenEstimator.count(block: .image(mediaType: "image/png", base64: "AAAA")),
            1600
        )
    }

    func testToolResultIsCountedFromItsFlattenedText() {
        let tokens = TokenEstimator.count(block: .toolResult(
            toolUseID: "t",
            content: .string(String(repeating: "x", count: 300)),
            isError: false
        ))
        XCTAssertGreaterThan(tokens, 50)
    }

    func testRequestEstimateGrowsWithContent() {
        let small = anthropicRequest(messages: [AnthropicMessage(role: "user", text: "hi")])
        let large = anthropicRequest(messages: [
            AnthropicMessage(role: "user", text: String(repeating: "word ", count: 500)),
        ])
        XCTAssertGreaterThan(TokenEstimator.estimate(large), TokenEstimator.estimate(small))
    }

    func testEstimateIsNeverZero() {
        let empty = anthropicRequest(messages: [])
        XCTAssertGreaterThan(TokenEstimator.estimate(empty), 0)
    }
}

// MARK: - Reverse direction

final class ReverseTranslationTests: XCTestCase {

    private func openAIRequest(_ json: String) throws -> OpenAIChatRequest {
        try JSONDecoder().decode(OpenAIChatRequest.self, from: Data(json.utf8))
    }

    func testSystemMessagesJoinIntoTheSystemField() throws {
        let source = try openAIRequest("""
        {"model":"gpt-4o","messages":[
          {"role":"system","content":"Be brief."},
          {"role":"system","content":"Be accurate."},
          {"role":"user","content":"hi"}]}
        """)

        let result = Translation.anthropicRequest(from: source)
        XCTAssertEqual(result.system?.plainText, "Be brief.\n\nBe accurate.")
        XCTAssertFalse(result.messages.contains { $0.role == "system" })
    }

    /// Anthropic requires strict alternation; OpenAI does not. Without merging,
    /// a conversation that split tool results out would be rejected outright.
    func testConsecutiveSameRoleMessagesAreMerged() throws {
        let source = try openAIRequest("""
        {"model":"m","messages":[
          {"role":"user","content":"one"},
          {"role":"user","content":"two"}]}
        """)

        let result = Translation.anthropicRequest(from: source)
        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages[0].content.blocks.count, 2)
        XCTAssertEqual(result.messages[0].content.plainText, "onetwo")
    }

    func testToolMessagesBecomeToolResultBlocksInAUserTurn() throws {
        let source = try openAIRequest("""
        {"model":"m","messages":[
          {"role":"user","content":"read it"},
          {"role":"assistant","content":null,"tool_calls":[
            {"id":"call_1","type":"function","function":{"name":"read","arguments":"{\\"p\\":1}"}}]},
          {"role":"tool","tool_call_id":"call_1","content":"contents"}]}
        """)

        let result = Translation.anthropicRequest(from: source)
        XCTAssertEqual(result.messages.map(\.role), ["user", "assistant", "user"])

        guard case .toolUse(let id, let name, let input) = result.messages[1].content.blocks[0] else {
            return XCTFail("expected a tool_use block on the assistant turn")
        }
        XCTAssertEqual(id, "call_1")
        XCTAssertEqual(name, "read")
        XCTAssertEqual(input.objectValue?["p"]?.intValue, 1)

        guard case .toolResult(let toolUseID, let content, _) = result.messages[2].content.blocks[0] else {
            return XCTFail("expected a tool_result block")
        }
        XCTAssertEqual(toolUseID, "call_1")
        XCTAssertEqual(content.flattenedText, "contents")
    }

    /// `max_tokens` is required by Anthropic and optional in OpenAI, so a
    /// missing value has to become a default rather than a 400.
    func testMissingMaxTokensGetsADefault() throws {
        let source = try openAIRequest("""
        {"model":"m","messages":[{"role":"user","content":"hi"}]}
        """)
        XCTAssertEqual(Translation.anthropicRequest(from: source).maxTokens, 8192)
    }

    func testExplicitMaxTokensIsPreserved() throws {
        let source = try openAIRequest("""
        {"model":"m","max_tokens":256,"messages":[{"role":"user","content":"hi"}]}
        """)
        XCTAssertEqual(Translation.anthropicRequest(from: source).maxTokens, 256)
    }

    func testConversationOpeningWithAssistantGetsAUserPrefix() throws {
        let source = try openAIRequest("""
        {"model":"m","messages":[{"role":"assistant","content":"hello"}]}
        """)
        let result = Translation.anthropicRequest(from: source)
        XCTAssertEqual(result.messages.first?.role, "user")
    }

    func testToolChoiceModesMapBackToAnthropicVocabulary() {
        XCTAssertEqual(
            Translation.anthropicToolChoice(.mode("required"))?.type,
            "any"
        )
        XCTAssertEqual(
            Translation.anthropicToolChoice(.mode("none"))?.type,
            "none"
        )
        let specific = Translation.anthropicToolChoice(.function(name: "search"))
        XCTAssertEqual(specific?.type, "tool")
        XCTAssertEqual(specific?.name, "search")
    }

    func testDataURIIsSplitIntoMediaTypeAndPayload() {
        let parsed = Translation.parseDataURI("data:image/jpeg;base64,/9j/4AAQ")
        XCTAssertEqual(parsed?.mediaType, "image/jpeg")
        XCTAssertEqual(parsed?.base64, "/9j/4AAQ")

        XCTAssertNil(Translation.parseDataURI("https://example.com/a.png"))
        XCTAssertNil(Translation.parseDataURI("data:image/png,notbase64"))
    }

    func testNonDataImageURLBecomesAPlaceholderNote() throws {
        let source = try openAIRequest("""
        {"model":"m","messages":[{"role":"user","content":[
          {"type":"text","text":"look"},
          {"type":"image_url","image_url":{"url":"https://example.com/a.png"}}]}]}
        """)
        let result = Translation.anthropicRequest(from: source)
        let texts = result.messages[0].content.blocks.compactMap(\.textValue)
        XCTAssertTrue(texts.contains { $0.contains("image omitted") })
    }

    func testAnthropicResponseRoundTripsToOpenAI() throws {
        let anthropic = AnthropicResponse(
            id: "msg_1",
            model: "claude-sonnet-4-5",
            content: [
                .thinking("hmm"),
                .text("here you go"),
                .toolUse(id: "toolu_1", name: "read", input: .object(["path": .string("/x")])),
            ],
            stopReason: "tool_use",
            usage: AnthropicUsage(inputTokens: 10, outputTokens: 4)
        )

        let openAI = Translation.openAIResponse(from: anthropic)
        let choice = openAI.choices.first
        XCTAssertEqual(choice?.finishReason, "tool_calls")
        XCTAssertEqual(choice?.message?.content?.plainText, "here you go")
        XCTAssertEqual(choice?.message?.reasoningContent, "hmm")
        XCTAssertEqual(choice?.message?.toolCalls?.first?.id, "toolu_1")
        XCTAssertEqual(openAI.usage?.promptTokens, 10)
        XCTAssertEqual(openAI.usage?.totalTokens, 14)
    }
}

// MARK: - Anthropic content blocks
//
// Coverage found the image and tool_result halves of this codec never
// executing on either side. That is the half that matters for tool calling:
// `tool_result` is how a tool's output travels back to Claude, so an encoder
// that drops it looks like the model ignoring its own tool use.

final class AnthropicContentBlockTests: XCTestCase {

    private func object(_ block: AnthropicContentBlock) throws -> [String: Any] {
        let data = try JSONEncoder().encode(block)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func roundTrip(_ block: AnthropicContentBlock) throws -> AnthropicContentBlock {
        try JSONDecoder().decode(AnthropicContentBlock.self, from: JSONEncoder().encode(block))
    }

    func testToolResultSurvivesARoundTrip() throws {
        let block = AnthropicContentBlock.toolResult(
            toolUseID: "toolu_01", content: .string("42"), isError: false
        )
        let json = try object(block)
        XCTAssertEqual(json["type"] as? String, "tool_result")
        XCTAssertEqual(json["tool_use_id"] as? String, "toolu_01")
        XCTAssertEqual(try roundTrip(block), block)
    }

    /// A failed tool must reach the model marked as failed. Losing this flag
    /// turns an error into a confident wrong answer.
    func testAnErroredToolResultKeepsItsFlag() throws {
        let block = AnthropicContentBlock.toolResult(
            toolUseID: "toolu_02", content: .string("boom"), isError: true
        )
        XCTAssertEqual(try object(block)["is_error"] as? Bool, true, "is_error was dropped")
        XCTAssertEqual(try roundTrip(block), block)
    }

    /// The flag is only written when true: Anthropic reads a present
    /// `is_error` as meaningful, and omitting it is the documented default.
    func testAFalseErrorFlagIsOmitted() throws {
        let block = AnthropicContentBlock.toolResult(
            toolUseID: "toolu_03", content: .null, isError: false
        )
        XCTAssertNil(try object(block)["is_error"])
    }

    func testImageBlocksRoundTripThroughTheBase64Envelope() throws {
        let block = AnthropicContentBlock.image(mediaType: "image/jpeg", base64: "QUJD")
        let json = try object(block)
        XCTAssertEqual(json["type"] as? String, "image")
        let source = try XCTUnwrap(json["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(source["data"] as? String, "QUJD")
        XCTAssertEqual(try roundTrip(block), block)
    }

    /// A block kind we do not model must survive as its own type rather than
    /// failing the whole response — an unknown block in a long conversation
    /// should not cost the user the turn.
    func testAnUnknownBlockKindIsPreservedByType() throws {
        let block = AnthropicContentBlock.unknown(type: "server_tool_use")
        XCTAssertEqual(try object(block)["type"] as? String, "server_tool_use")
        XCTAssertEqual(try roundTrip(block), block)
    }

    /// A missing `type` is decoded as `unknown` rather than throwing, so a
    /// malformed block degrades instead of failing the response.
    func testABlockWithNoTypeIsTreatedAsUnknown() throws {
        let decoded = try JSONDecoder().decode(
            AnthropicContentBlock.self, from: Data(#"{"text":"hi"}"#.utf8)
        )
        XCTAssertEqual(decoded, .unknown(type: "unknown"))
    }

    /// `system` is either a bare string or an array of blocks. Both are in use,
    /// and the block form is what carries `cache_control`.
    func testASystemPromptIsEitherAStringOrBlocks() throws {
        let bare = try JSONDecoder().decode(
            AnthropicSystem.self, from: Data(#""be brief""#.utf8)
        )
        XCTAssertEqual(bare, .text("be brief"))
        XCTAssertEqual(bare.plainText, "be brief")

        let blocks = try JSONDecoder().decode(
            AnthropicSystem.self,
            from: Data(#"[{"type":"text","text":"one"},{"type":"text","text":"two"}]"#.utf8)
        )
        XCTAssertEqual(blocks.plainText, "one\n\ntwo")
    }

    /// A bare string must re-encode as a bare string, not as a one-element
    /// array: backends that never saw a block form reject the array.
    func testABareSystemStringReEncodesAsAString() throws {
        let encoded = try JSONEncoder().encode(AnthropicSystem.text("be brief"))
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #""be brief""#)
    }
}
