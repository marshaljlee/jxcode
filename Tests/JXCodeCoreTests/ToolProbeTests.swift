import XCTest
@testable import JXCodeCore

/// The live tool-calling probe.
///
/// This suite is the difference between a claim and an observation. Every other
/// tool-calling signal in the repo is an inference over a document — the GGUF's
/// chat template, or `/props`'s capability block — and the failure both of them
/// share is that they can be *right about the format and wrong about the
/// model*. `RealLlamaServerTests` caught a real file where the template
/// rendered `tool_calls` in full and never read `tools`, so llama.cpp reported
/// `supports_tool_calls=true, supports_tools=false` and the model answered an
/// agent in prose.
///
/// So the tests below are mostly about the reply shapes the probe has to tell
/// apart, and about the request it sends: a probe that asked the wrong question
/// and read the answer correctly would be worse than no probe, because it would
/// be trusted.
final class ToolProbeTests: XCTestCase {

    private var server: StubServer!

    override func setUpWithError() throws {
        server = try StubServer()
        try server.start()
    }

    override func tearDownWithError() throws {
        server?.stop()
    }

    private func provider(_ kind: ProviderKind = .openAICompatible) -> Provider {
        Provider(name: "Test", kind: kind, baseURL: server.baseURL)
    }

    /// A chat completion carrying one tool call.
    ///
    /// `arguments` is a JSON *string* holding JSON, which is what the wire
    /// actually carries, so it has to be escaped on the way in. Interpolating
    /// it raw produced a body no decoder would accept — and the probe reported
    /// `malformed` for a perfectly good reply, which is the fixture being
    /// wrong rather than the code under test.
    private static func toolCall(_ name: String, arguments: String = #"{"text":"ping"}"#) -> String {
        let escaped = arguments
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {"id":"chatcmpl-1","object":"chat.completion","choices":[{
          "index":0,
          "message":{"role":"assistant","content":null,"tool_calls":[
            {"id":"call_1","type":"function","function":{"name":"\(name)","arguments":"\(escaped)"}}
          ]},
          "finish_reason":"tool_calls"
        }]}
        """
    }

    /// A chat completion with no tool call.
    private static func prose(_ text: String, finish: String = "stop") -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {"id":"chatcmpl-2","object":"chat.completion","choices":[{
          "index":0,
          "message":{"role":"assistant","content":"\(escaped)"},
          "finish_reason":"\(finish)"
        }]}
        """
    }

    private func probe() -> ToolProbe { ToolProbe(timeout: 5) }

    // MARK: - The verdicts

    func testAToolCallIsTheOnlyThingCalledVerified() async throws {
        server.routes["/v1/chat/completions"] = .json(Self.toolCall("echo"))

        let outcome = await probe().run(provider: provider(), model: "test-model")

        XCTAssertEqual(outcome.verdict, .verified)
        XCTAssertTrue(outcome.isVerified)
        XCTAssertTrue(outcome.namedTheExpectedTool)
        XCTAssertEqual(outcome.calledTools, ["echo"])
        XCTAssertEqual(outcome.mark, "✓")
    }

    func testProseIsReportedWithWhatTheModelSaidInstead() async throws {
        server.routes["/v1/chat/completions"] = .json(
            Self.prose("I don't have access to an echo tool.")
        )

        let outcome = await probe().run(provider: provider(), model: "test-model")

        XCTAssertEqual(outcome.verdict, .proseInstead)
        XCTAssertFalse(outcome.isVerified)
        // The prose is the diagnosis. A verdict of "it did not work" without
        // what the model actually said leaves nothing to act on.
        XCTAssertEqual(outcome.prose, "I don't have access to an echo tool.")
        XCTAssertEqual(outcome.mark, "✗")
    }

    func testACallByAnotherNameIsStillAStructuredCall() async throws {
        // The template can emit a call, which is the question the probe asks.
        // Whether the model picked the right tool is a different question, and
        // the outcome keeps the two apart rather than collapsing them.
        server.routes["/v1/chat/completions"] = .json(Self.toolCall("get_weather"))

        let outcome = await probe().run(provider: provider(), model: "test-model")

        XCTAssertEqual(outcome.verdict, .verified)
        XCTAssertEqual(outcome.calledTools, ["get_weather"])
        XCTAssertFalse(outcome.namedTheExpectedTool, "a different tool was called")
    }

    func testAnEmptyToolNameIsNotACall() async throws {
        // Some quantised models emit the tool-call envelope with the name left
        // blank. Counting that as verified would turn the probe into a rubber
        // stamp for exactly the models it exists to catch.
        server.routes["/v1/chat/completions"] = .json("""
        {"choices":[{"index":0,"message":{"role":"assistant","tool_calls":[
          {"id":"call_1","type":"function","function":{"name":"","arguments":"{}"}}
        ]},"finish_reason":"tool_calls"}]}
        """)

        let outcome = await probe().run(provider: provider(), model: "test-model")

        XCTAssertEqual(outcome.verdict, .proseInstead)
        XCTAssertTrue(outcome.calledTools.isEmpty)
    }

    func testRunningOutOfBudgetIsNotAVerdictAboutTheModel() async throws {
        // A thinking model spends its budget on the trace first. Reporting
        // "answered in prose" here would be a false negative in the one place
        // this app is trying to stop guessing.
        server.routes["/v1/chat/completions"] = .json(
            Self.prose("Let me think about this. The user wants me to", finish: "length")
        )

        let outcome = await probe().run(provider: provider(), model: "test-model")

        XCTAssertEqual(outcome.verdict, .truncated)
        XCTAssertEqual(outcome.mark, "?", "an inconclusive probe must not be drawn as a failure")
        XCTAssertTrue(outcome.detail.contains("512"))
    }

    func testANonSuccessStatusIsRejectedRatherThanUnreachable() async throws {
        server.routes["/v1/chat/completions"] = .json(
            #"{"error":{"message":"model 'nope' not found"}}"#,
            status: 404
        )

        let outcome = await probe().run(provider: provider(), model: "nope")

        XCTAssertEqual(outcome.verdict, .rejected)
        XCTAssertTrue(outcome.detail.contains("404"))
        XCTAssertTrue(outcome.detail.contains("not found"), "the server's own words must survive")
    }

    func testABodyThatIsNotAChatCompletionIsMalformed() async throws {
        // A gateway or a login page answering 200 is the case that would
        // otherwise read as "no tool calling".
        server.routes["/v1/chat/completions"] = .text("<html>sign in</html>")

        let outcome = await probe().run(provider: provider(), model: "test-model")

        XCTAssertEqual(outcome.verdict, .malformed)
    }

    func testA200WithNoChoicesIsMalformedRatherThanProse() async throws {
        server.routes["/v1/chat/completions"] = .json(#"{"object":"chat.completion"}"#)

        let outcome = await probe().run(provider: provider(), model: "test-model")

        XCTAssertEqual(outcome.verdict, .malformed)
    }

    func testADeadBackendIsUnreachableNotBroken() async throws {
        // A port nothing listens on. The distinction matters: "the backend is
        // down" and "the backend cannot call tools" call for opposite actions.
        let dead = Provider(
            name: "Dead",
            kind: .openAICompatible,
            baseURL: "http://127.0.0.1:1"
        )

        let outcome = await probe().run(provider: dead, model: "test-model")

        XCTAssertEqual(outcome.verdict, .unreachable)
        XCTAssertEqual(outcome.mark, "?")
    }

    func testAnAnthropicBackendIsRefusedWithTheReason() async throws {
        let outcome = await probe().run(provider: provider(.anthropic), model: "claude")

        XCTAssertEqual(outcome.verdict, .unsupported)
        XCTAssertTrue(outcome.detail.contains("router"), "the way out must be in the message")
        XCTAssertTrue(server.hits.isEmpty, "nothing should have been sent")
    }

    // MARK: - What the probe actually sends

    func testTheRequestCarriesTheToolItClaimsToOffer() async throws {
        // The assertion that stops the suite agreeing with a broken probe. If
        // the body lost its `tools` array, every other test here would still
        // pass against a stub that ignores the request.
        server.routes["/v1/chat/completions"] = .json(Self.toolCall("echo"))

        _ = await probe().run(provider: provider(), model: "qwen3-coder")

        let hit = try XCTUnwrap(server.hits.first)
        XCTAssertEqual(hit.path, "/v1/chat/completions")
        XCTAssertEqual(hit.header("Content-Type"), "application/json")

        let root = try XCTUnwrap(hit.json?.objectValue)
        XCTAssertEqual(root["model"]?.stringValue, "qwen3-coder")

        let tool = try XCTUnwrap(root["tools"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(tool["type"]?.stringValue, "function")
        let function = try XCTUnwrap(tool["function"]?.objectValue)
        XCTAssertEqual(function["name"]?.stringValue, ToolProbe.toolName)

        // The schema has to be real: llama.cpp compiles it into a GBNF grammar,
        // so a probe with no parameters would exercise a different decode path
        // than an agent does.
        let parameters = try XCTUnwrap(function["parameters"]?.objectValue)
        XCTAssertEqual(parameters["type"]?.stringValue, "object")
        XCTAssertEqual(parameters["required"]?.arrayValue?.first?.stringValue, "text")

        // `auto`, not `required`. A forced call would make the grammar produce
        // something for a template that cannot express tools, turning this into
        // a test of llama.cpp rather than of the model.
        XCTAssertEqual(root["tool_choice"]?.stringValue, "auto")
        XCTAssertEqual(root["stream"]?.boolValue, false)
        XCTAssertEqual(root["temperature"]?.numberValue, 0)
        XCTAssertEqual(root["max_tokens"]?.numberValue, Double(ToolProbe.defaultMaxTokens))

        let message = try XCTUnwrap(root["messages"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(message["role"]?.stringValue, "user")
        XCTAssertEqual(message["content"]?.stringValue, ToolProbe.prompt)
    }

    func testTheTemplateKwargsAreSentOnlyWhenTheServerWasConfiguredWithThem() async throws {
        // A plan that emits `--chat-template-kwargs` has to be able to say so,
        // or the probe measures an environment no agent will ever be in.
        server.routes["/v1/chat/completions"] = .json(Self.toolCall("echo"))

        _ = await ToolProbe(timeout: 5, templateKwargs: ["enable_thinking": .bool(false)])
            .run(provider: provider(), model: "test-model")

        let root = try XCTUnwrap(server.hits.first?.json?.objectValue)
        let kwargs = try XCTUnwrap(root["chat_template_kwargs"]?.objectValue)
        XCTAssertEqual(kwargs["enable_thinking"]?.boolValue, false)

        server.routes["/v1/chat/completions"] = .json(Self.toolCall("echo"))
        _ = await probe().run(provider: provider(), model: "test-model")

        let second = try XCTUnwrap(server.hits.last?.json?.objectValue)
        XCTAssertNil(
            second["chat_template_kwargs"],
            "the field must be absent, not null — some servers reject an empty object"
        )
    }

    func testOllamaIsProbedOnItsOwnPath() async throws {
        // Ollama's native chat API answers with the same `message.tool_calls`
        // field, so one request shape covers it — but the path differs, and a
        // probe that POSTed to /v1/chat/completions would get a 404 and report
        // "rejected" for a server that works.
        server.routes["/api/chat"] = .json(Self.toolCall("echo"))

        let outcome = await probe().run(provider: provider(.ollama), model: "llama3:8b")

        XCTAssertEqual(outcome.verdict, .verified)
        XCTAssertEqual(server.hits.first?.path, "/api/chat")
    }

    // MARK: - The report

    func testTheReportShowsThePredictionBesideTheObservation() async throws {
        server.routes["/v1/chat/completions"] = .json(Self.toolCall("echo"))
        let outcome = await probe().run(provider: provider(), model: "test-model")

        let report = ModelReport.toolProbe(outcome, prediction: .supported)

        XCTAssertTrue(report.contains("predicted"))
        XCTAssertTrue(report.contains("observed"))
        XCTAssertTrue(report.contains("test-model"))
        XCTAssertTrue(report.contains("✓"))
    }

    func testAgreementAddsNoSentence() async throws {
        // A line saying "these match" on every probe trains the reader to skip
        // the section, and then the one time it matters they miss it.
        server.routes["/v1/chat/completions"] = .json(Self.toolCall("echo"))
        let outcome = await probe().run(provider: provider(), model: "test-model")

        let report = ModelReport.toolProbe(outcome, prediction: .supported)

        XCTAssertFalse(report.contains("did not"))
        XCTAssertFalse(report.contains("worked"))
    }

    func testAPredictionOfSupportedThatFailedIsNamedAsTheFinding() async throws {
        // The case the probe exists for: a template that reads as tool-capable
        // and answers in prose.
        server.routes["/v1/chat/completions"] = .json(Self.prose("Sure, I'll echo that."))
        let outcome = await probe().run(provider: provider(), model: "test-model")

        let report = ModelReport.toolProbe(outcome, prediction: .supported)

        XCTAssertTrue(report.contains("predicted tool calling would work and it did not"))
        XCTAssertTrue(report.contains("\"Sure, I'll echo that.\""), "what it said instead is the diagnosis")
    }

    func testAnUnreadableTemplateThatWorksIsReportedAsGoodNews() async throws {
        // `unknown` is what a built-in preset gets, because its body lives in
        // llama.cpp. The probe is the only thing that can resolve it.
        server.routes["/v1/chat/completions"] = .json(Self.toolCall("echo"))
        let outcome = await probe().run(provider: provider(), model: "test-model")

        let report = ModelReport.toolProbe(outcome, prediction: .unknown)

        XCTAssertTrue(report.contains("An unreadable template is not a broken one"))
    }

    func testTheProseIsNotQuotedWhenTheCallWorked() async throws {
        // A model may emit both a call and a preamble. Quoting the preamble
        // under the heading "instead" would read as a failure.
        server.routes["/v1/chat/completions"] = .json("""
        {"choices":[{"index":0,"message":{"role":"assistant","content":"Echoing now.",
          "tool_calls":[{"id":"c1","type":"function","function":{"name":"echo","arguments":"{}"}}]},
          "finish_reason":"tool_calls"}]}
        """)

        let outcome = await probe().run(provider: provider(), model: "test-model")
        let report = ModelReport.toolProbe(outcome)

        XCTAssertEqual(outcome.verdict, .verified)
        XCTAssertFalse(report.contains("instead"))
        XCTAssertFalse(report.contains("predicted"), "no prediction was supplied")
    }
}
