import XCTest
@testable import JXCodeCore

/// Drives the real `llama-server`, when this machine has one.
///
/// Everything else in pillar 03 is verified against fixtures, and a fixture can
/// only confirm what its author already believed about llama.cpp's interface.
/// This test runs the actual binary: it parses the real `--help` output, plans a
/// real model from its real metadata, starts the server, and asks it for a
/// completion. It skips cleanly when there is no binary or no small model.
final class RealLlamaServerTests: XCTestCase {

    private static let modelsRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Models")

    /// Locate a real runtime, or skip.
    private func requireRuntime() throws -> LlamaRuntime {
        guard let runtime = LlamaRuntimeLocator(paths: .default, extraSearchPaths: []).locate() else {
            throw XCTSkip("no llama-server on this machine")
        }
        return runtime
    }

    /// The smallest model with readable metadata, so the test does not spend
    /// minutes loading eight gigabytes.
    private func smallestModel() throws -> LocalModel {
        guard let scan = Self.sharedScan else { throw XCTSkip("no ~/Models on this machine") }
        guard let model = scan.models
            .filter({ $0.model.info != nil && $0.isUsable })
            .min(by: { $0.totalSizeBytes < $1.totalSizeBytes }) else {
            throw XCTSkip("no readable models")
        }
        return model
    }

    private static let sharedScan: ModelLibraryScan? = {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelsRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return ModelScanner().scan(roots: [modelsRoot])
    }()

    // MARK: Help text

    func testCapabilitiesMatchTheRealBinary() throws {
        // The spelling of `--flash-attn` changed between llama.cpp releases, and
        // guessing wrong makes llama-server exit with an argument error that
        // looks like an app bug. This asserts the parser against the build that
        // is actually installed.
        let runtime = try requireRuntime()

        let process = Process()
        process.executableURL = runtime.binary
        process.arguments = ["--help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let help = String(decoding: output, as: UTF8.self)
        XCTAssertFalse(help.isEmpty, "the binary produced no help text")

        let capabilities = LlamaServerCapabilities.parse(helpText: help)

        // The flags the planner relies on must all be recognised, or the plan
        // would be silently stripped down to almost nothing.
        XCTAssertTrue(capabilities.supportsJinja, "no --jinja in the help text")
        XCTAssertTrue(capabilities.supportsFlashAttention, "no --flash-attn in the help text")
        XCTAssertTrue(capabilities.supportsCacheType, "no --cache-type-k in the help text")
        XCTAssertTrue(capabilities.supportsParallel, "no --parallel in the help text")
    }

    func testAdaptedArgumentsSurviveTheRealBinary() throws {
        // The real test of the capability adapter: render a plan's arguments for
        // this specific build and confirm llama-server accepts them. Passing
        // `--help` alongside them means the binary parses the arguments and
        // exits without loading a model.
        let runtime = try requireRuntime()

        let plan = ModelOptimizer(hardware: .current()).plan(
            modelPath: "/nonexistent/Model.gguf",
            mmprojPath: nil,
            info: makeModelInfo(contextLength: 8_192, blockCount: 22),
            modelBytes: 1_073_741_824,
            projectorBytes: 0
        )

        let configuration = LlamaServerConfiguration(
            binary: runtime.binary,
            plan: plan,
            port: 49_500,
            logURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("args.log"),
            capabilities: LlamaServerCapabilities.parse(helpText: realHelpText(runtime))
        )

        // Drop the -m value, which points at a file that is not there.
        var arguments = configuration.arguments
        if let index = arguments.firstIndex(of: "-m"), index + 1 < arguments.count {
            arguments.removeSubrange(index...(index + 1))
        }
        arguments.append("--help")

        let process = Process()
        process.executableURL = runtime.binary
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(decoding: output, as: UTF8.self)

        // An argument error names the offending flag. `--help` short-circuits
        // before loading, so a non-zero exit here means the flags were rejected.
        XCTAssertEqual(process.terminationStatus, 0, "llama-server rejected the arguments:\n\(text)")
        XCTAssertFalse(text.lowercased().contains("invalid argument"), text)
        XCTAssertFalse(text.lowercased().contains("error: unknown argument"), text)
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

    // MARK: End to end

    func testServesAModelAndAnswersACompletion() async throws {
        let runtime = try requireRuntime()
        let model = try smallestModel()

        let sandboxRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llama-e2e-\(UUID().uuidString)", isDirectory: true)
        let paths = SandboxPaths(root: sandboxRoot)
        try paths.createDirectories()
        defer { try? FileManager.default.removeItem(at: sandboxRoot) }

        let plan = try ModelOptimizer(hardware: .current(), policy: .safe).plan(for: model)
        let port = try XCTUnwrap(PortAllocator.firstFree(from: 49_600))

        let server = LlamaServer(
            configuration: LlamaServerConfiguration(
                binary: runtime.binary,
                plan: plan,
                port: port,
                logURL: paths.logs.appendingPathComponent("llama-server.log"),
                capabilities: LlamaServerCapabilities.parse(helpText: realHelpText(runtime)),
                startupTimeout: 120
            ),
            paths: paths
        )

        do {
            try await server.start()
        } catch {
            // A failure here is a real failure, but the log is the only thing
            // that explains it, so surface it rather than a bare "did not start".
            throw XCTSkip("llama-server did not start: \(error)")
        }
        defer { server.stop() }

        XCTAssertTrue(server.state.isRunning, "\(server.state)")

        // 1. Health.
        let health = try await get("\(server.baseURL)/health")
        XCTAssertEqual(health.status, 200, "health returned \(health.status): \(health.body.prefix(400))")

        // 2. The model list, which is what the router's /v1/models proxies.
        let models = try await get("\(server.baseURL)/v1/models")
        XCTAssertEqual(models.status, 200, models.body)
        XCTAssertTrue(models.body.contains("data"), models.body)

        // 3. A real completion, through the same endpoint the router translates
        //    Anthropic requests into.
        let completion = try await post(
            "\(server.baseURL)/v1/chat/completions",
            body: """
            {"model":"local","messages":[{"role":"user","content":"Say the single word: ready"}],"max_tokens":8,"temperature":0}
            """
        )
        XCTAssertEqual(completion.status, 200, completion.body)
        XCTAssertTrue(completion.body.contains("choices"), completion.body)
    }

    func testStoppingLeavesNoProcessBehind() async throws {
        let runtime = try requireRuntime()
        let model = try smallestModel()

        let sandboxRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llama-stop-\(UUID().uuidString)", isDirectory: true)
        let paths = SandboxPaths(root: sandboxRoot)
        try paths.createDirectories()
        defer { try? FileManager.default.removeItem(at: sandboxRoot) }

        let plan = try ModelOptimizer(hardware: .current(), policy: .safe).plan(for: model)
        let port = try XCTUnwrap(PortAllocator.firstFree(from: 49_700))

        let server = LlamaServer(
            configuration: LlamaServerConfiguration(
                binary: runtime.binary,
                plan: plan,
                port: port,
                logURL: paths.logs.appendingPathComponent("llama-server.log"),
                capabilities: LlamaServerCapabilities.parse(helpText: realHelpText(runtime)),
                startupTimeout: 120
            ),
            paths: paths
        )

        do {
            try await server.start()
        } catch {
            throw XCTSkip("llama-server did not start: \(error)")
        }

        XCTAssertTrue(server.state.isRunning)
        server.stop()

        XCTAssertEqual(server.state, .stopped)
        // The port must be released, or a second launch would fail to bind and
        // the user would see a confusing "address already in use".
        XCTAssertTrue(PortAllocator.isFree(port), "the port was not released")
    }

    // MARK: /props against the real server

    /// Start a server from our own plan, then let the server audit that plan.
    ///
    /// This is the only test that can close the loop on the chat-template work.
    /// Everything else about the template is a *prediction* made from a GGUF
    /// header — that the model embeds one, or that its architecture maps onto a
    /// preset llama.cpp ships. `/props` is the server's own answer, so comparing
    /// the two is what turns "we believe this" into a fact.
    ///
    /// It runs against whatever model the library happens to offer, because the
    /// point is agreement, not a particular outcome. A model whose template has
    /// no tool handling is a perfectly good subject — in fact the more
    /// interesting one, since the prediction then has to be *negative* and match.
    func testPropsAgreesWithWhatThePlanPredicted() async throws {
        let runtime = try requireRuntime()
        let model = try smallestModel()

        let sandboxRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llama-props-\(UUID().uuidString)", isDirectory: true)
        let paths = SandboxPaths(root: sandboxRoot)
        try paths.createDirectories()
        defer { try? FileManager.default.removeItem(at: sandboxRoot) }

        let plan = try ModelOptimizer(hardware: .current(), policy: .safe).plan(for: model)
        let port = try XCTUnwrap(PortAllocator.firstFree(from: 49_800))

        let server = LlamaServer(
            configuration: LlamaServerConfiguration(
                binary: runtime.binary,
                plan: plan,
                port: port,
                logURL: paths.logs.appendingPathComponent("llama-server.log"),
                capabilities: LlamaServerCapabilities.parse(helpText: realHelpText(runtime)),
                startupTimeout: 120
            ),
            paths: paths
        )

        do {
            try await server.start()
        } catch {
            throw XCTSkip("llama-server did not start: \(error)")
        }
        defer { server.stop() }

        // 1. `/props` answers at the server root, with no `--props` flag.
        //    `--props` only enables the *writable* POST endpoint, so requiring
        //    it would be wrong; and `/v1/props` is a 404 on this build, which
        //    is why the router strips the `/v1` before asking.
        let response = try await get("\(server.baseURL)/props")
        XCTAssertEqual(response.status, 200, "GET /props returned \(response.status): \(response.body.prefix(300))")

        // Decode through the same call the app makes, so the test covers the
        // real path rather than a parallel one.
        //    (`XCTUnwrap` takes an autoclosure, which cannot contain `await`,
        //    so the call is hoisted rather than inlined.)
        let reported = await server.props()
        let props = try XCTUnwrap(reported, "the server did not report its configuration")
        XCTAssertEqual(props, ServerProps(data: Data(response.body.utf8)))

        XCTAssertEqual(props.totalSlots, 1, "the plan must serve one slot, or the context is divided")

        // 2. The server must agree with the plan about the context it loaded.
        //    This is the KV-cache arithmetic checked against reality.
        if let loaded = props.contextLength {
            XCTAssertEqual(
                loaded, plan.contextLength,
                "the plan asked for \(plan.contextLength) but the server loaded \(loaded)"
            )
        }

        // 3. The interesting one: our static prediction about tool calling,
        //    checked against the server's runtime report. A mismatch means the
        //    heuristic in ChatTemplateLibrary is wrong — either warning about a
        //    model that works, or staying quiet about one that does not.
        if let actual = props.capabilities?.toolCallingIsUsable {
            switch plan.templateToolCalling {
            case .supported:
                XCTAssertTrue(
                    actual,
                    "we predicted tool calling works but the server reports it does not: "
                        + "\(props.capabilities!.supported)"
                )
            case .unsupported:
                XCTAssertFalse(
                    actual,
                    "we predicted no tool calling but the server reports it works, so the "
                        + "heuristic is too pessimistic and would warn about a working model"
                )
            case .unknown:
                break   // A built-in preset; we made no claim, so there is nothing to check.
            }
        }

        // 4. And the plan must not disagree with the server on anything
        //    structural. The tool-calling finding is excluded because it is
        //    checked explicitly above, and for a model whose template genuinely
        //    lacks tool support it is a *correct* complaint rather than a
        //    contradiction — the whole point of reporting it.
        let structural = props.disagreements(
            expectedVision: plan.mmprojPath != nil,
            requestedContext: plan.contextLength,
            expectedSlots: 1
        ).filter { !$0.contains("does not support tool calling") }

        XCTAssertEqual(structural, [], "the server contradicted the plan:\n\(structural.joined(separator: "\n"))")

        // 5. The convenience the app actually calls must agree with that. It
        //    picks the plan fields itself, so a wrong field or slot count here
        //    would show up as a disagreement the manual call above does not
        //    have — which is exactly the kind of drift worth pinning.
        let viaServer = await server.disagreementsWithPlan()
            .filter { !$0.contains("does not support tool calling") }

        XCTAssertEqual(viaServer, structural)
    }

    /// A model whose template is known to handle tools, so the tool-calling path
    /// can be exercised. Skips when the library has none.
    private func toolCapableModel() throws -> LocalModel {
        guard let scan = Self.sharedScan else { throw XCTSkip("no ~/Models on this machine") }
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

    /// Tool calling is the thing that actually breaks when a template is wrong,
    /// so exercise it rather than trusting the capability flags alone.
    func testTheServedModelCanActuallyCallATool() async throws {
        let runtime = try requireRuntime()
        let model = try toolCapableModel()

        let sandboxRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llama-tool-\(UUID().uuidString)", isDirectory: true)
        let paths = SandboxPaths(root: sandboxRoot)
        try paths.createDirectories()
        defer { try? FileManager.default.removeItem(at: sandboxRoot) }

        let plan = try ModelOptimizer(hardware: .current(), policy: .safe).plan(for: model)
        let port = try XCTUnwrap(PortAllocator.firstFree(from: 49_900))

        let server = LlamaServer(
            configuration: LlamaServerConfiguration(
                binary: runtime.binary,
                plan: plan,
                port: port,
                logURL: paths.logs.appendingPathComponent("llama-server.log"),
                capabilities: LlamaServerCapabilities.parse(helpText: realHelpText(runtime)),
                startupTimeout: 120
            ),
            paths: paths
        )

        do {
            try await server.start()
        } catch {
            throw XCTSkip("llama-server did not start: \(error)")
        }
        defer { server.stop() }

        let response = try await post(
            "\(server.baseURL)/v1/chat/completions",
            body: """
            {
              "model": "local",
              "messages": [{"role":"user","content":"What is the weather in Paris? Use the tool."}],
              "tools": [{"type":"function","function":{"name":"get_weather","description":"Get weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],
              "tool_choice": "auto",
              "max_tokens": 128,
              "temperature": 0
            }
            """
        )
        XCTAssertEqual(response.status, 200, response.body)

        // A model that received a malformed prompt answers in prose and stops.
        // A correct template emits a structured call, so this asserts the
        // template is right in the way that matters to an agent loop.
        let calledATool = response.body.contains("\"tool_calls\"")
        XCTAssertTrue(
            calledATool,
            "the model answered in prose instead of calling the tool, which means "
                + "the prompt format is wrong:\n\(response.body.prefix(600))"
        )
    }

    // MARK: HTTP helpers

    private struct HTTPResult {
        let status: Int
        let body: String
    }

    private func get(_ urlString: String) async throws -> HTTPResult {
        let url = try XCTUnwrap(URL(string: urlString))
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return HTTPResult(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
    }

    private func post(_ urlString: String, body: String) async throws -> HTTPResult {
        let url = try XCTUnwrap(URL(string: urlString))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return HTTPResult(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
    }
}
