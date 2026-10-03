import XCTest
@testable import JXCodeCore

// MARK: - Fixtures

/// A body in the shape Claude Code sends, chosen for the fields the router's own
/// request model does not carry.
///
/// Every one of these is dropped by a decode/encode round trip through
/// `AnthropicRequest`, and each has a distinct consequence:
///
///   - `cache_control` on the system block and on the tool definition: prompt
///     caching stops working, and the user pays for it with no message.
///   - `signature` on the thinking block: Anthropic requires it back on the
///     following turn, so a thinking conversation breaks on turn two.
///   - `context_management` and `anthropic_beta`: top-level fields added after
///     the struct was written.
private let claudeCodeBody = """
{
  "model": "claude-sonnet-4-5",
  "max_tokens": 4096,
  "stream": false,
  "system": [
    {"type": "text", "text": "You are a coding agent.",
     "cache_control": {"type": "ephemeral"}}
  ],
  "messages": [
    {"role": "user", "content": "what is 2+2"},
    {"role": "assistant", "content": [
      {"type": "thinking", "thinking": "trivial", "signature": "EqQBCgIYAhIM"},
      {"type": "text", "text": "4"}
    ]}
  ],
  "tools": [
    {"name": "echo", "description": "echo back", "input_schema": {"type": "object"},
     "cache_control": {"type": "ephemeral"}}
  ],
  "thinking": {"type": "enabled", "budget_tokens": 1024},
  "metadata": {"user_id": "u-1"},
  "context_management": {"edits": []},
  "anthropic_beta": ["thinking-binding-controls-2026-08-01"]
}
"""

/// The same request, streamed.
private let streamingClaudeCodeBody = claudeCodeBody.replacingOccurrences(
    of: #""stream": false"#,
    with: #""stream": true"#
)

/// The event sequence the translator emits for the fake upstream's OpenAI
/// frames. Native frames are asserted against their own bytes instead.
private let translatedSequence = [
    "message_start",
    "content_block_start",
    "content_block_delta",
    "content_block_delta",
    "content_block_stop",
    "message_delta",
    "message_stop",
]

private func eventNames(in transcript: String) -> [String] {
    var names: [String] = []
    for line in transcript.split(separator: "\n") {
        guard line.hasPrefix("event: ") else { continue }
        names.append(String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces))
    }
    return names
}

private func decode(_ text: String) throws -> [String: JSONValue] {
    try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)).objectValue)
}

// MARK: - The route

final class AnthropicPassthroughTests: XCTestCase {

    /// llama-server serves `/v1/messages` itself, so an agent that speaks
    /// Anthropic should reach the model without the router rewriting anything.
    func testALocalGGUFBackendIsSentTheAnthropicBodyItself() async throws {
        let harness = try RouterHarness(kind: .localGGUF)
        let (_, response) = try await harness.post("/v1/messages", body: claudeCodeBody)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(harness.upstream.requests.count, 1)
        XCTAssertEqual(
            harness.upstream.requests[0].path,
            "/v1/messages",
            "the OpenAI path would be /chat/completions — the trap this route was built to avoid"
        )
    }

    /// The headline claim of the whole upgrade: nothing is lost on the way
    /// through. Each assertion here names a field the translation path cannot
    /// carry, so a regression points at the consequence rather than the field.
    func testTheNativeRouteKeepsEveryFieldTheRouterCannotModel() async throws {
        let harness = try RouterHarness(kind: .localGGUF)
        _ = try await harness.post("/v1/messages", body: claudeCodeBody)

        let sent = try decode(try XCTUnwrap(harness.upstream.bodyTexts.last))

        let system = try XCTUnwrap(sent["system"]?.arrayValue?.first?.objectValue)
        XCTAssertNotNil(system["cache_control"], "prompt caching on the system block was dropped")

        let tool = try XCTUnwrap(sent["tools"]?.arrayValue?.first?.objectValue)
        XCTAssertNotNil(tool["cache_control"], "prompt caching on the tool definition was dropped")

        let blocks = try XCTUnwrap(
            sent["messages"]?.arrayValue?.dropFirst().first?.objectValue?["content"]?.arrayValue
        )
        let thinking = try XCTUnwrap(blocks.first?.objectValue)
        XCTAssertEqual(thinking["type"]?.stringValue, "thinking")
        XCTAssertEqual(
            thinking["signature"]?.stringValue,
            "EqQBCgIYAhIM",
            "without its signature a thinking block cannot be sent back on the next turn"
        )

        XCTAssertEqual(sent["thinking"]?.objectValue?["budget_tokens"]?.intValue, 1024)
        XCTAssertEqual(sent["metadata"]?.objectValue?["user_id"]?.stringValue, "u-1")
        XCTAssertNotNil(sent["context_management"], "a top-level field the router has never heard of")
        XCTAssertEqual(
            sent["anthropic_beta"]?.arrayValue?.first?.stringValue,
            "thinking-binding-controls-2026-08-01"
        )
    }

    /// Why the native route forwards bytes rather than re-encoding its own model
    /// of them.
    ///
    /// This is a tripwire, not a complaint: `AnthropicRequest` is allowed to be
    /// lossy, because the translator rebuilds the request in another shape
    /// anyway. What is not allowed is a *passthrough* that promises fidelity and
    /// then routes through it. If the decoded model ever becomes faithful, this
    /// fails and the raw-body path can be reconsidered.
    ///
    /// **It fired.** Widening the translation to the current event set taught the
    /// block model to keep a thinking block's `signature`, and this test went red
    /// on that one line. The reconsideration it demanded was made and the answer
    /// is to keep the raw-body path: `cache_control`, `anthropic_beta` and
    /// `context_management` are still dropped, and re-encoding would still cost
    /// prompt caching on every turn. The assertion below is therefore *positive*
    /// now — it pins the field that was fixed, so a future change that loses it
    /// again is caught here rather than only in the translator's tests.
    func testTheDecodedRequestIsNotAFaithfulCarrierOfTheClientBody() throws {
        let decoded = try JSONDecoder().decode(AnthropicRequest.self, from: Data(claudeCodeBody.utf8))
        let text = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)

        XCTAssertFalse(text.contains("cache_control"))
        XCTAssertFalse(text.contains("anthropic_beta"))
        XCTAssertFalse(text.contains("context_management"))

        XCTAssertTrue(
            text.contains("signature"),
            "the signature is carried now; if this regresses the raw-body path is "
            + "the only thing left keeping a thinking conversation alive on turn two"
        )
    }

    /// The model name is rewritten and nothing else moves — asserted over the
    /// whole tree, so a field quietly dropped anywhere in it fails the test.
    func testOnlyTheModelNameIsRewritten() async throws {
        let harness = try RouterHarness(model: "served-model", kind: .localGGUF)
        _ = try await harness.post("/v1/messages", body: claudeCodeBody)

        let sent = try decode(try XCTUnwrap(harness.upstream.bodyTexts.last))
        XCTAssertEqual(sent["model"]?.stringValue, "served-model")

        var expected = try decode(claudeCodeBody)
        expected["model"] = .string("served-model")
        XCTAssertEqual(JSONValue.object(sent), JSONValue.object(expected))
    }

    /// When the client already asks for the model it will get, the original
    /// bytes are forwarded without even a parse. That is the common case for an
    /// agent bound to this router, and it means no number, escape or key order
    /// in the body can change shape on the way through.
    func testTheClientsBytesGoOutUnchangedWhenTheModelAlreadyMatches() async throws {
        let harness = try RouterHarness(model: "claude-sonnet-4-5", kind: .localGGUF)
        _ = try await harness.post("/v1/messages", body: claudeCodeBody)

        XCTAssertEqual(harness.upstream.bodyTexts.last, claudeCodeBody)
    }

    /// The translator is still the route for a backend that has no Anthropic
    /// endpoint, and it still produces an OpenAI body.
    func testAnOpenAIOnlyBackendIsStillTranslated() async throws {
        let harness = try RouterHarness(kind: .openAICompatible)
        let (_, response) = try await harness.post("/v1/messages", body: claudeCodeBody)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(harness.upstream.requests.count, 1)
        XCTAssertEqual(harness.upstream.requests[0].path, "/v1/chat/completions")

        let sent = try decode(try XCTUnwrap(harness.upstream.bodyTexts.last))
        XCTAssertNil(sent["system"], "an OpenAI body has no top-level system field")
        XCTAssertEqual(sent["messages"]?.arrayValue?.first?.objectValue?["role"]?.stringValue, "system")
    }

    // MARK: Streaming

    /// A native stream is forwarded frame for frame. The `signature_delta` is
    /// the clearest case: no translation can invent one, and a client rejects a
    /// thinking block that arrives without it.
    func testANativeStreamIsForwardedEventForEvent() async throws {
        let harness = try RouterHarness(kind: .localGGUF)
        let frames = [
            "event: message_start\ndata: {\"type\":\"message_start\",\"message\":"
                + "{\"id\":\"msg_1\",\"model\":\"served\",\"usage\":{\"input_tokens\":7,\"output_tokens\":0}}}\n\n",
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,"
                + "\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,"
                + "\"delta\":{\"type\":\"signature_delta\",\"signature\":\"EqQBCgIYAhIM\"}}\n\n",
            "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
        ]
        harness.upstream.rawStreamFrames = frames

        let transcript = try await harness.streamPost("/v1/messages", body: streamingClaudeCodeBody)

        XCTAssertEqual(harness.upstream.requests.count, 1)
        XCTAssertEqual(harness.upstream.requests[0].path, "/v1/messages")
        XCTAssertEqual(transcript, frames.joined(), "the frames were not forwarded byte for byte")
    }

    // MARK: The fallback

    /// A llama-server build that predates the Anthropic route must not break the
    /// turn. The route is probed by asking it, so the answer is the server's, not
    /// a version table's.
    func testAMissingMessagesRouteFallsBackToTranslation() async throws {
        let harness = try RouterHarness(kind: .localGGUF)
        harness.upstream.messagesRouteStatus = 404

        let (data, response) = try await harness.post("/v1/messages", body: claudeCodeBody)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(
            harness.upstream.requests.count, 2,
            "expected the native attempt and then the translated retry"
        )
        XCTAssertEqual(harness.upstream.requests[0].path, "/v1/messages")
        XCTAssertEqual(harness.upstream.requests[1].path, "/v1/chat/completions")

        // Answered in the shape the client speaks, so the fallback is invisible.
        let reply = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        XCTAssertEqual(reply.type, "message")
        XCTAssertEqual(reply.content.first?.textValue, "hello from upstream")

        XCTAssertTrue(
            harness.router.log.snapshot().contains { $0.contains("does not serve") },
            "a silent fallback is a performance mystery nobody can diagnose"
        )
    }

    /// The same, on a stream — which is the case that matters, because the
    /// response head has already been sent by the time the upstream answers.
    func testAMissingMessagesRouteFallsBackMidStream() async throws {
        let harness = try RouterHarness(kind: .localGGUF)
        harness.upstream.messagesRouteStatus = 404

        let transcript = try await harness.streamPost("/v1/messages", body: streamingClaudeCodeBody)

        XCTAssertEqual(harness.upstream.requests.count, 2)
        XCTAssertEqual(harness.upstream.requests[1].path, "/v1/chat/completions")
        // One coherent translated stream, not an error event spliced in front of
        // one. This holds only because the passthrough checks the upstream's
        // status before forwarding a byte.
        XCTAssertFalse(transcript.contains("event: error"), transcript)
        XCTAssertEqual(eventNames(in: transcript), translatedSequence)
    }

    /// 405 is the same claim as 404 — this endpoint is not what you think it is —
    /// and a proxy in front of the backend answers one or the other depending on
    /// its own routing.
    func testAMethodNotAllowedIsTreatedAsAMissingRoute() async throws {
        let harness = try RouterHarness(kind: .localGGUF)
        harness.upstream.messagesRouteStatus = 405

        let (_, response) = try await harness.post("/v1/messages", body: claudeCodeBody)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(harness.upstream.requests.count, 2)
    }

    /// A 400 means the backend understood the request and refused it. Retrying it
    /// in another shape turns one error into two, and hides the first.
    func testARefusedRequestIsNotRetriedOnAnotherWire() async throws {
        let harness = try RouterHarness(kind: .localGGUF)
        harness.upstream.messagesRouteStatus = 400

        let (data, response) = try await harness.post("/v1/messages", body: claudeCodeBody)

        XCTAssertEqual(response.statusCode, 400)
        XCTAssertEqual(
            harness.upstream.requests.count, 1,
            "a 400 was retried — the backend's own error was discarded"
        )
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("unknown endpoint"))
    }

    /// Anthropic has no OpenAI route to fall back to, so a 404 from it is the
    /// user's endpoint being wrong and must be reported. Falling back would post
    /// a translated body to `/v1/messages` — the same mistake in the other
    /// direction.
    func testAnAnthropicBackendIsNotRetriedOnAnotherWire() async throws {
        let harness = try RouterHarness(kind: .anthropic)
        harness.upstream.messagesRouteStatus = 404

        let (_, response) = try await harness.post("/v1/messages", body: claudeCodeBody)

        XCTAssertEqual(response.statusCode, 404)
        XCTAssertEqual(
            harness.upstream.requests.count, 1,
            "a retry would have sent a translated body to an endpoint that does not speak it"
        )
    }

    func testAnAnthropicBackendReportsAMissingRouteInsteadOfTranslating() async throws {
        let harness = try RouterHarness(kind: .anthropic)
        harness.upstream.messagesRouteStatus = 404

        let transcript = try await harness.streamPost("/v1/messages", body: streamingClaudeCodeBody)

        XCTAssertEqual(harness.upstream.requests.count, 1)
        XCTAssertTrue(transcript.contains("event: error"), transcript)
        XCTAssertTrue(transcript.contains("upstream error"), transcript)
    }

    // MARK: A recorded asymmetry

    /// The two routes report the model name differently, and that is a decision
    /// rather than an oversight.
    ///
    /// The translator echoes the alias the client asked for, because the client
    /// keys its context-window table off that name. The native route hands the
    /// backend's reply back untouched, so the name in it is the backend's. That
    /// is already how the Anthropic passthrough behaved before this change;
    /// making the two agree means editing a body the router promised not to
    /// touch, which is 2.2's subject and not something to slip in here.
    func testTheTwoRoutesReportTheModelNameDifferently() async throws {
        let translated = try RouterHarness(kind: .openAICompatible)
        let (translatedData, _) = try await translated.post("/v1/messages", body: claudeCodeBody)
        XCTAssertEqual(
            try JSONDecoder().decode(AnthropicResponse.self, from: translatedData).model,
            "claude-sonnet-4-5",
            "the translator reports the alias the client asked for"
        )

        let native = try RouterHarness(kind: .localGGUF)
        native.upstream.anthropicCompletionBody = """
        {"id":"msg_1","type":"message","role":"assistant","model":"local_model.gguf",
         "content":[{"type":"text","text":"hi"}],
         "stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
        """
        let (nativeData, _) = try await native.post("/v1/messages", body: claudeCodeBody)
        XCTAssertEqual(
            try JSONDecoder().decode(AnthropicResponse.self, from: nativeData).model,
            "local_model.gguf",
            "the native route forwards the backend's own reply, name included"
        )
    }
}
