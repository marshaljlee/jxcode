import XCTest
@testable import JXCodeCore

/// The whole chain an agent actually uses, against a real model.
///
/// Every other test covers one link: `RouterEndToEndTests` drives the router
/// against a fake upstream it controls, and `RealLlamaServerTests` drives
/// llama-server directly. Neither exercises **router → real llama-server**,
/// which is the configuration a user ends up in after `serve --register` and
/// the only one where the two halves have to agree about the wire format.
///
/// It is worth the seconds it costs, because the seams are where this breaks:
/// the router normalises the base URL, decides which endpoint to call, and
/// translates in both directions, while llama-server independently decides what
/// its own template can express.
///
/// Skips cleanly when there is no runtime or no model with a tool-capable
/// template.
final class RealRouterChainTests: XCTestCase {

    private static let modelsRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Models")

    private func requireRuntime() throws -> LlamaRuntime {
        guard let runtime = LlamaRuntimeLocator(paths: .default, extraSearchPaths: []).locate() else {
            throw XCTSkip("no llama-server on this machine")
        }
        return runtime
    }

    /// A model whose template handles tools, since the point of the test is the
    /// tool-call translation.
    private func toolCapableModel() throws -> LocalModel {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: Self.modelsRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw XCTSkip("no ~/Models on this machine")
        }
        let scan = ModelScanner().scan(roots: [Self.modelsRoot])
        let capable = scan.models
            .filter { $0.model.info != nil && $0.isUsable }
            .filter { model in
                guard let info = model.model.info else { return false }
                return ChatTemplateLibrary.resolve(
                    architecture: info.architecture,
                    embeddedTemplate: info.chatTemplate,
                    vocabularySize: info.vocabularySize
                ).toolCalling == .supported
            }
            .sorted { $0.totalSizeBytes < $1.totalSizeBytes }

        guard let model = capable.first else {
            throw XCTSkip("no model on this machine has a tool-capable chat template")
        }
        return model
    }

    /// A real llama-server and a real router in front of it, torn down when the
    /// body returns.
    ///
    /// Extracted so a second test can make a claim about the *route* rather than
    /// about the answer. Both claims need a live server, and starting one is the
    /// expensive part.
    ///
    /// `kind` decides which route the router takes. `localGGUF` is the native
    /// one — llama-server serves `/v1/messages` itself — and `openAICompatible`
    /// forces the translator, which is the configuration a user with an older
    /// llama-server, or any OpenAI-only backend, actually has.
    private func withRealChain(
        kind: ProviderKind = .localGGUF,
        _ body: (LlamaServer, ModelRouter, URL, OptimizationPlan) async throws -> Void
    ) async throws {
        let runtime = try requireRuntime()
        let model = try toolCapableModel()

        // A throwaway sandbox, so nothing here touches the user's real one.
        let sandboxRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chain-\(UUID().uuidString)", isDirectory: true)
        let paths = SandboxPaths(root: sandboxRoot)
        try paths.createDirectories()
        defer { try? FileManager.default.removeItem(at: sandboxRoot) }

        // --- The model server, started from our own plan. ---
        let plan = try ModelOptimizer(hardware: .current(), policy: .safe).plan(for: model)
        let modelPort = try XCTUnwrap(PortAllocator.firstFree(from: 49_100))

        let server = LlamaServer(
            configuration: LlamaServerConfiguration(
                binary: runtime.binary,
                plan: plan,
                port: modelPort,
                logURL: paths.logs.appendingPathComponent("llama-server.log"),
                capabilities: LlamaServerCapabilities.parse(helpText: realHelpText(runtime)),
                startupTimeout: 180
            ),
            paths: paths
        )
        do {
            try await server.start()
        } catch {
            throw XCTSkip("llama-server did not start: \(error)")
        }
        defer { server.stop() }

        // --- The router, pointed at it. ---
        let provider = Provider(
            name: "Local",
            kind: kind,
            baseURL: "http://127.0.0.1:\(modelPort)",
            models: [model.model.url.lastPathComponent]
        )
        let state = RouterState(RouterConfiguration(provider: provider, model: "local"))
        let router = ModelRouter(state: state)
        try router.start(preferredPort: 0)
        defer { router.stop() }

        let base = URL(string: "http://127.0.0.1:\(router.port)")!
        try await body(server, router, base, plan)
    }

    private func realHelpText(_ runtime: LlamaRuntime) -> String {
        let process = Process()
        process.executableURL = runtime.binary
        process.arguments = ["--help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return "" }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
    }

    private func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    private func post(_ url: URL, body: String, timeout: TimeInterval = 180) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    private func streamPost(_ url: URL, body: String) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 180
        let (bytes, _) = try await URLSession.shared.bytes(for: request)
        var collected = Data()
        for try await byte in bytes { collected.append(byte) }
        return String(decoding: collected, as: UTF8.self)
    }

    func testAnAgentReachesARealModelThroughTheRouter() async throws {
        try await withRealChain { _, _, base, plan in

            // 1. The model list an agent fetches on startup.
            let (modelsData, modelsResponse) = try await get(base.appendingPathComponent("v1/models"))
            XCTAssertEqual(modelsResponse.statusCode, 200, String(decoding: modelsData, as: UTF8.self))
            XCTAssertTrue(String(decoding: modelsData, as: UTF8.self).contains("data"))

            // 2. `/props` proxied through the router to the real server. This is the
            //    path that would 404 if the router guessed `/v1/props`, and the
            //    decoded result must describe the model that is actually loaded.
            let (propsData, propsResponse) = try await get(base.appendingPathComponent("props"))
            XCTAssertEqual(
                propsResponse.statusCode, 200,
                "/props through the router: \(String(decoding: propsData, as: UTF8.self).prefix(300))"
            )
            let props = try XCTUnwrap(
                ServerProps(data: propsData),
                "the router's /props did not forward a decodable body"
            )
            XCTAssertEqual(props.totalSlots, 1)
            XCTAssertEqual(props.contextLength, plan.contextLength)

            // 3. A non-streaming Anthropic request **with tools**, which is what
            //    Claude Code sends. The tool definition arrives in Anthropic's
            //    shape, has to become OpenAI's, and the answer has to come back as
            //    an Anthropic `tool_use` block.
            let anthropicBody = """
            {
              "model": "claude-sonnet-4-5-20250929",
              "max_tokens": 256,
              "tools": [{
                "name": "get_weather",
                "description": "Get the weather for a city",
                "input_schema": {
                  "type": "object",
                  "properties": {"city": {"type": "string"}},
                  "required": ["city"]
                }
              }],
              "messages": [{"role": "user", "content": "What is the weather in Paris? Use the tool."}]
            }
            """
            let (messageData, messageResponse) = try await post(
                base.appendingPathComponent("v1/messages"),
                body: anthropicBody
            )
            let messageText = String(decoding: messageData, as: UTF8.self)
            XCTAssertEqual(messageResponse.statusCode, 200, messageText)

            // Anthropic shape, not OpenAI's: the agent cannot read `tool_calls`.
            XCTAssertTrue(
                messageText.contains("\"tool_use\""),
                "the tool call did not come back as an Anthropic tool_use block:\n\(messageText.prefix(600))"
            )
            XCTAssertTrue(messageText.contains("get_weather"), messageText)
            XCTAssertFalse(
                messageText.contains("\"tool_calls\""),
                "OpenAI's shape leaked through to the agent:\n\(messageText.prefix(600))"
            )

            // 4. The same request streamed, since that is what an agent uses by
            //    default. A well-formed Anthropic stream is bracketed by
            //    message_start and message_stop, and carries the tool call as a
            //    content block.
            let streamed = try await streamPost(
                base.appendingPathComponent("v1/messages"),
                body: anthropicBody.replacingOccurrences(
                    of: "\"max_tokens\": 256",
                    with: "\"max_tokens\": 256, \"stream\": true"
                )
            )

            XCTAssertTrue(streamed.contains("event: message_start"), streamed.prefix(400).description)
            XCTAssertTrue(streamed.contains("event: message_stop"), "the stream never terminated")
            XCTAssertTrue(streamed.contains("event: content_block_start"), streamed.prefix(600).description)
            XCTAssertTrue(
                streamed.contains("tool_use"),
                "the streamed tool call was not framed as an Anthropic block:\n\(streamed.prefix(800))"
            )
        }
    }

    /// 2.3's claim, against a real server: the count is the backend's own, and
    /// it is not what the estimate would have said.
    ///
    /// Both halves are needed. That the route answers a positive number is
    /// already covered against a fake upstream; what only a real tokenizer can
    /// show is that the number is *different*. The whole reason to ask is that
    /// the estimate cannot see the chat template, so a test that accepted any
    /// positive number would pass on the estimate it exists to have replaced.
    func testATokenCountIsMeasuredByARealLlamaServer() async throws {
        try await withRealChain { _, router, base, _ in
            // A body with a tool definition, because that is where the two
            // answers diverge most: the schema is most of the work the template
            // does and none of the characters the estimate can see.
            let body = """
            {
              "model": "claude-sonnet-4-5-20250929",
              "max_tokens": 256,
              "system": "You are a helpful assistant.",
              "messages": [{"role": "user", "content": "Hello, how are you today?"}],
              "tools": [{
                "name": "read_file",
                "description": "Read a file from disk",
                "input_schema": {"type": "object", "properties": {"path": {"type": "string"}}}
              }]
            }
            """

            let (data, response) = try await post(
                base.appendingPathComponent("v1/messages/count_tokens"),
                body: body
            )
            XCTAssertEqual(response.statusCode, 200, String(decoding: data, as: UTF8.self))

            let payload = try JSONDecoder().decode(JSONValue.self, from: data)
            let measured = try XCTUnwrap(payload.objectValue?["input_tokens"]?.intValue)
            XCTAssertGreaterThan(measured, 0)

            let request = try JSONDecoder().decode(AnthropicRequest.self, from: Data(body.utf8))
            let estimate = TokenEstimator.estimate(request)
            XCTAssertNotEqual(
                measured, estimate,
                "the route answered with the estimate, so the real backend was "
                + "never asked"
            )

            XCTAssertTrue(
                router.log.snapshot().contains { $0.contains("(measured)") },
                "the log does not say the count was measured:\n"
                + router.log.snapshot().joined(separator: "\n")
            )
        }
    }

    /// 2.1's claim, against a real server: an Anthropic-speaking agent is served
    /// on llama-server's own `/v1/messages` instead of through the translator.
    ///
    /// The distinction cannot be read off the reply — a fallback produces a
    /// perfectly good Anthropic answer too, which is the whole point of it being
    /// silent — so it is asserted on the router's own account of the request.
    /// Without this, the test above would keep passing if llama-server stopped
    /// serving the route tomorrow, and nobody would know the translation had
    /// quietly come back.
    func testAnAnthropicRequestIsServedNativelyByARealLlamaServer() async throws {
        try await withRealChain { _, router, base, _ in
            // A Claude Code shaped body, carrying the fields the router's own
            // request model cannot hold: `cache_control` on a system block, and
            // a top-level field it has never heard of.
            let body = """
            {
              "model": "claude-sonnet-4-5-20250929",
              "max_tokens": 64,
              "system": [{"type": "text", "text": "Answer in one word.",
                          "cache_control": {"type": "ephemeral"}}],
              "messages": [{"role": "user", "content": "Say the word: banana"}],
              "anthropic_beta": ["thinking-binding-controls-2026-08-01"]
            }
            """

            let (data, response) = try await post(
                base.appendingPathComponent("v1/messages"),
                body: body
            )
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertEqual(response.statusCode, 200, text)

            let log = router.log.snapshot()
            XCTAssertTrue(
                log.contains { $0.contains("wire=native") },
                "the request did not take the native route. Log tail:\n\(log.suffix(8).joined(separator: "\n"))"
            )
            XCTAssertFalse(
                log.contains { $0.contains("does not serve") },
                "the native route was attempted and this server refused it, so this "
                + "test proved nothing about it. Log tail:\n\(log.suffix(8).joined(separator: "\n"))"
            )

            let reply = try JSONDecoder().decode(AnthropicResponse.self, from: data)
            XCTAssertEqual(reply.type, "message", text)
            XCTAssertFalse(reply.content.isEmpty, text)

            // The same route, streamed, which is what an agent uses by default.
            let streamed = try await streamPost(
                base.appendingPathComponent("v1/messages"),
                body: body.replacingOccurrences(
                    of: #""max_tokens": 64,"#,
                    with: #""max_tokens": 64, "stream": true,"#
                )
            )
            XCTAssertTrue(
                streamed.contains("event: message_start"),
                streamed.prefix(400).description
            )
            XCTAssertTrue(
                streamed.contains("event: message_stop"),
                "the native stream never terminated:\n\(streamed.suffix(300))"
            )
            XCTAssertFalse(
                router.log.snapshot().contains { $0.contains("does not serve") },
                "the streaming request fell back, so the native stream was never exercised"
            )
        }
    }

    /// The *translated* route, against a real model, carrying the blocks the
    /// current Anthropic wire defines.
    ///
    /// 2.1's native route means a llama-server never reaches the translator, so
    /// the translation only meets a real model when the provider is declared
    /// OpenAI-compatible — which is exactly the configuration a user with an
    /// older llama-server, or any other OpenAI-only backend, has. Nothing else in
    /// the suite exercises that combination, and the whole point of the notes is
    /// that they are what the user reads when it drops something.
    func testTheTranslatedRouteReportsWhatItCannotCarryToARealModel() async throws {
        try await withRealChain(kind: .openAICompatible) { _, router, base, _ in
            let body = """
            {
              "model": "local",
              "max_tokens": 64,
              "messages": [
                {"role": "user", "content": "search for the answer"},
                {"role": "assistant", "content": [
                   {"type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search",
                    "input": {"query": "x"}},
                   {"type": "thinking", "thinking": "a prior trace", "signature": ""},
                   {"type": "text", "text": "done"}]},
                {"role": "user", "content": "thanks"}
              ]
            }
            """

            let (data, response) = try await post(
                base.appendingPathComponent("v1/messages"),
                body: body
            )
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertEqual(response.statusCode, 200, text)

            let notes = router.log.lastTranslation
            XCTAssertFalse(notes.isEmpty, "the translation dropped blocks and said nothing")
            XCTAssertTrue(
                notes.contains { $0.contains("server_tool_use") },
                "the server-tool block was not named:\n\(notes)"
            )
            XCTAssertTrue(
                notes.contains { $0.contains("thinking") },
                "the thinking block was not named:\n\(notes)"
            )
            XCTAssertTrue(
                router.log.snapshot().contains { $0.contains("translation (anthropic→openai)") },
                "the notes never reached the log the pane reads"
            )
        }
    }
}
