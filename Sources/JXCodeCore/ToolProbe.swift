import Foundation

// MARK: - Asking the backend whether it can call tools
//
// Everything else in this app that answers "can this model call tools?" answers
// it from a *document*: `ChatTemplateLibrary` reads the template stored in the
// GGUF, `ServerProps` reads `chat_template_caps` out of `/props`. Both are
// inferences about a format. Neither is an observation.
//
// That distinction has a cost, and the cost is the worst kind of failure this
// app can produce: a template that looks like it handles tools, a `/props` that
// agrees, and an agent that answers every tool request in prose. There is no
// error, no crash and no log line — the agent simply narrates. Two integration
// tests in this repo found exactly that shape (`RealLlamaServerTests`), which is
// why the prediction is now checked against the server at all.
//
// This goes one step further and removes the inference. It sends the same kind
// of request an agent sends — one user message and one JSON-Schema tool — and
// looks at what comes back. llama.cpp turns that schema into a GBNF grammar and
// then into a PEG, so the probe exercises the real decode path rather than a
// description of it. "We asked the model to call a tool and it did" is a
// stronger claim than any header parse, and it is the one worth making.

/// One live tool-calling probe against a running backend.
///
/// Deliberately a value with an `init` that takes a session, so a test can hand
/// it a stub server and assert what it sent as well as what it made of the
/// reply.
public struct ToolProbe: Sendable {

    /// The tool the probe offers.
    ///
    /// `echo` rather than something the model has an opinion about. The first
    /// draft used `get_weather`, and that is a trap: a model that knows the
    /// weather in a named city will happily answer in prose without calling
    /// anything, which makes a working model look broken. A tool whose only
    /// possible answer is the string it was given removes the model's
    /// opportunity to know better.
    public static let toolName = "echo"

    /// The prompt. One instruction, and the instruction is the whole test.
    public static let prompt = "Use the echo tool to echo the text \"ping\". Do not answer in prose."

    /// How much room the model gets to decide.
    ///
    /// Generous on purpose. A thinking model spends its budget on the trace
    /// before it emits anything, and a probe that cuts it off would report
    /// "answered in prose" for a model that was about to call the tool — a
    /// false negative in the one place this app is trying to stop guessing.
    /// `Verdict.truncated` exists so that case can be reported as itself.
    public static let defaultMaxTokens = 512

    /// What the probe concluded.
    public enum Verdict: String, Sendable, Equatable, Codable {
        /// A structured tool call came back. This is the only claim the probe
        /// is willing to call a pass.
        case verified
        /// The server answered normally with no tool call. Either the template
        /// cannot inject tool definitions, or the model chose not to use them —
        /// the probe cannot tell those apart, and does not pretend to.
        case proseInstead
        /// The model ran out of budget before deciding. Not a verdict about the
        /// model, so it is not reported as one.
        case truncated
        /// The request never completed.
        case unreachable
        /// The server answered non-2xx.
        case rejected
        /// A 2xx whose body was not a chat completion.
        case malformed
        /// This backend does not speak the wire the probe speaks.
        case unsupported
    }

    /// What happened, in enough detail to act on.
    public struct Outcome: Sendable, Equatable, Codable {
        public let verdict: Verdict
        public let model: String
        public let endpoint: String
        public let expectedTool: String
        /// Every tool name the reply contained. A call naming something else
        /// still proves the template can emit a structured call, which is the
        /// question the probe is asking — so it is recorded rather than
        /// discarded, and `namedTheExpectedTool` is what a caller checks when
        /// it wants the stricter claim.
        public let calledTools: [String]
        /// What the model said instead, when it said something instead.
        public let prose: String?
        public let detail: String
        public let elapsed: TimeInterval

        public init(
            verdict: Verdict,
            model: String,
            endpoint: String = "",
            expectedTool: String = ToolProbe.toolName,
            calledTools: [String] = [],
            prose: String? = nil,
            detail: String,
            elapsed: TimeInterval = 0
        ) {
            self.verdict = verdict
            self.model = model
            self.endpoint = endpoint
            self.expectedTool = expectedTool
            self.calledTools = calledTools
            self.prose = prose
            self.detail = detail
            self.elapsed = elapsed
        }

        public var isVerified: Bool { verdict == .verified }

        /// The stricter claim: it called the tool we offered, by name.
        public var namedTheExpectedTool: Bool { calledTools.contains(expectedTool) }

        /// A one-character verdict for a list, where the sentence will not fit.
        ///
        /// `?` rather than `✗` for the two inconclusive outcomes: a probe that
        /// could not run has not failed, and drawing it the same way as a
        /// refusal would teach the user to ignore both.
        public var mark: String {
            switch verdict {
            case .verified:                          return "✓"
            case .proseInstead, .rejected, .malformed: return "✗"
            case .truncated, .unreachable, .unsupported: return "?"
            }
        }

        public var summary: String {
            switch verdict {
            case .verified:
                let extra = namedTheExpectedTool ? "" : " (but not by the name offered)"
                return "verified — the model called \(calledTools.joined(separator: ", "))\(extra)"
            case .proseInstead:  return "not verified — the model answered in prose"
            case .truncated:     return "inconclusive — the model ran out of budget before deciding"
            case .unreachable:   return "inconclusive — the backend could not be reached"
            case .rejected:      return "not verified — the backend refused the request"
            case .malformed:     return "inconclusive — the reply was not a chat completion"
            case .unsupported:   return "not applicable — this backend does not speak the wire the probe uses"
            }
        }
    }

    private let session: URLSession
    private let timeout: TimeInterval
    private let maxTokens: Int

    /// Extra `chat_template_kwargs` to send.
    ///
    /// The probe must ask in the environment the *server was started in*, not in
    /// the one a bare client would create. A template that gates its tool
    /// handling behind `enable_thinking` behaves differently depending on this
    /// field, so a server started with `--chat-template-kwargs` has to be probed
    /// with the same field — or the probe measures an environment no agent will
    /// ever be in.
    ///
    /// `nil` is a real answer and not a missing one. On a build that has
    /// `--reasoning`, the server is told to reason by its own command line and
    /// `enable_thinking` through this field is the deprecated spelling of that
    /// same request — build 10150 says so at startup, and two servers with one
    /// variable between them confirmed it. So the plan's `templateKwargs` is
    /// deliberately nil there, and passing it through unchanged is what keeps the
    /// probe in step with the server rather than one release behind it.
    private let templateKwargs: [String: JSONValue]?

    public init(
        timeout: TimeInterval = 60,
        maxTokens: Int = ToolProbe.defaultMaxTokens,
        templateKwargs: [String: JSONValue]? = nil
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        // A probe result is about a server as it is running now. A cached reply
        // would report the previous model's capabilities.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
        self.timeout = timeout
        self.maxTokens = maxTokens
        self.templateKwargs = templateKwargs
    }

    // MARK: - Running it

    /// Ask a backend whether it calls tools, and report what it did.
    ///
    /// Never throws. A probe that could not run is a *result* — the point is to
    /// replace a guess with an observation, and "we could not observe" is a
    /// third answer that must not be dressed up as either of the other two.
    public func run(provider: Provider, model: String) async -> Outcome {
        let started = Date()

        // The probe speaks OpenAI's chat-completions wire, because that is the
        // one wire every backend in the provider list supports — llama-server,
        // Ollama, vLLM, LM Studio and the hosted APIs. The Anthropic-native
        // wire is a different request and a different reply, and probing it
        // would answer a question nobody asked: a hosted Anthropic model calls
        // tools. A native-Anthropic *local* backend is reached through the
        // router, which serves the OpenAI wire on the same port.
        guard provider.kind != .anthropic else {
            return Outcome(
                verdict: .unsupported,
                model: model,
                endpoint: provider.normalizedBaseURL,
                detail: "\(provider.kind.displayName) backends speak the Messages wire, and this "
                    + "probe speaks the chat-completions wire every other backend shares. Route the "
                    + "agent through jxcode first and probe the router's port instead.",
                elapsed: Date().timeIntervalSince(started)
            )
        }

        guard let url = provider.chatURL else {
            return Outcome(
                verdict: .malformed,
                model: model,
                endpoint: provider.baseURL,
                detail: "'\(provider.baseURL)' is not a usable URL.",
                elapsed: Date().timeIntervalSince(started)
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in provider.kind.authHeaders(apiKey: provider.apiKey) {
            request.setValue(value, forHTTPHeaderField: name)
        }

        do {
            request.httpBody = try JSONEncoder().encode(body(model: model))
        } catch {
            return Outcome(
                verdict: .malformed,
                model: model,
                endpoint: url.absoluteString,
                detail: "could not build the probe request: \(error)",
                elapsed: Date().timeIntervalSince(started)
            )
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return Outcome(
                verdict: .unreachable,
                model: model,
                endpoint: url.absoluteString,
                detail: "\(url.absoluteString) did not answer: \(error.localizedDescription)",
                elapsed: Date().timeIntervalSince(started)
            )
        }

        let elapsed = Date().timeIntervalSince(started)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: data, as: UTF8.self)

        guard (200..<300).contains(status) else {
            return Outcome(
                verdict: .rejected,
                model: model,
                endpoint: url.absoluteString,
                detail: "HTTP \(status): \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))",
                elapsed: elapsed
            )
        }

        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return Outcome(
                verdict: .malformed,
                model: model,
                endpoint: url.absoluteString,
                detail: "the reply was not JSON: \(text.prefix(200))",
                elapsed: elapsed
            )
        }

        return interpret(json, model: model, endpoint: url.absoluteString, elapsed: elapsed)
    }

    // MARK: - Reading the reply

    /// Turn a chat completion into a verdict.
    ///
    /// Split out from `run` so the shape handling is testable without a socket,
    /// and so the *reading* is in one place: the envelope is the same for every
    /// OpenAI-compatible backend including Ollama, whose native `/api/chat`
    /// answers with the same `message.tool_calls` field.
    func interpret(
        _ json: JSONValue,
        model: String,
        endpoint: String,
        elapsed: TimeInterval
    ) -> Outcome {
        guard case .object(let root) = json,
              let choices = root["choices"]?.arrayValue,
              let first = choices.first,
              case .object(let choice) = first,
              case .object(let message) = choice["message"] ?? .null
        else {
            return Outcome(
                verdict: .malformed,
                model: model,
                endpoint: endpoint,
                detail: "the reply had no choices[0].message, so there was nothing to read a tool "
                    + "call out of. A gateway in front of the backend may have reshaped it.",
                elapsed: elapsed
            )
        }

        var names: [String] = []
        for call in message["tool_calls"]?.arrayValue ?? [] {
            guard case .object(let callObject) = call,
                  case .object(let function) = callObject["function"] ?? .null,
                  let name = function["name"]?.stringValue,
                  !name.isEmpty
            else { continue }
            names.append(name)
        }

        let prose = message["content"]?.stringValue
        let finishReason = choice["finish_reason"]?.stringValue

        if !names.isEmpty {
            return Outcome(
                verdict: .verified,
                model: model,
                endpoint: endpoint,
                calledTools: names,
                prose: prose,
                detail: "the model returned a structured tool call, so the chat template in use can "
                    + "both pass tool definitions to the model and render a call back out. Tool "
                    + "calling works on this backend as configured.",
                elapsed: elapsed
            )
        }

        // Running out of budget is not a verdict about the template. Reported
        // as its own outcome so a small `max_tokens` cannot masquerade as a
        // model that refuses to call tools.
        if finishReason == "length" {
            return Outcome(
                verdict: .truncated,
                model: model,
                endpoint: endpoint,
                prose: prose,
                detail: "the reply hit the \(maxTokens)-token limit before the model decided, so "
                    + "this probe says nothing either way. A thinking model needs room for its "
                    + "trace first — raise the limit and probe again.",
                elapsed: elapsed
            )
        }

        let trimmed = (prose ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Outcome(
            verdict: .proseInstead,
            model: model,
            endpoint: endpoint,
            prose: prose,
            detail: "the model answered with text and no tool call"
                + (trimmed.isEmpty ? ", and the text was empty" : "")
                + ". Either its chat template cannot pass tool definitions to it, or it chose not "
                + "to use them. Check the template with --chat-template, and check that the model "
                + "was built for tool use at all.",
            elapsed: elapsed
        )
    }

    // MARK: - The request

    /// The body an agent would send, with one tool in it.
    func body(model: String) -> JSONValue {
        var root: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array([
                .object([
                    "role": .string("user"),
                    "content": .string(Self.prompt),
                ])
            ]),
            "tools": .array([
                .object([
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(Self.toolName),
                        "description": .string(
                            "Echo a string back to the caller. This is the only way to answer."
                        ),
                        "parameters": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "text": .object([
                                    "type": .string("string"),
                                    "description": .string("the text to echo"),
                                ])
                            ]),
                            "required": .array([.string("text")]),
                        ]),
                    ]),
                ])
            ]),
            // `auto`, not `required`. A forced call would make the grammar emit
            // something for a template that cannot express tools, turning the
            // probe into a test of llama.cpp rather than of the model. Agents
            // send `auto`, so the probe sends `auto`.
            "tool_choice": .string("auto"),
            // Non-streaming on purpose. Streaming a tool call exercises
            // `input_json_delta` reassembly, which is a different question from
            // whether the template can emit a call at all — and mixing them
            // means a streaming bug reads as "no tool calling". The streaming
            // path has its own tests.
            "stream": .bool(false),
            // Greedy. A probe that flips verdicts between runs is worse than no
            // probe, because the user learns to re-run it until it agrees.
            "temperature": .number(0),
            "max_tokens": .number(Double(maxTokens)),
        ]

        if let templateKwargs {
            root["chat_template_kwargs"] = .object(templateKwargs)
        }
        return .object(root)
    }
}

// MARK: - Rendering

public extension ModelReport {

    /// The probe result beside the prediction it replaces.
    ///
    /// Both are printed, and that is the point rather than a courtesy to the
    /// old code. The prediction is what the *plan* believes; the probe is what
    /// the *server* did. Where they disagree, the disagreement is the finding —
    /// a template that reads as tool-capable and answers in prose is a real
    /// model defect, and a prediction of "unknown" that turns out verified is
    /// good news the user would otherwise never hear.
    static func toolProbe(
        _ outcome: ToolProbe.Outcome,
        prediction: ChatTemplateLibrary.ToolCallingSupport? = nil
    ) -> String {
        var lines: [String] = []

        lines.append("tool calling")
        if let prediction {
            lines.append("  \(pad("predicted", to: 14))\(describe(prediction))")
        }
        lines.append("  \(pad("observed", to: 14))\(outcome.mark) \(outcome.summary)")
        lines.append("  \(pad("model", to: 14))\(outcome.model)")

        if let prose = outcome.prose?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prose.isEmpty, outcome.verdict == .proseInstead {
            // Quoted, because "what it said instead" is the whole diagnosis and
            // a truncated paraphrase of it is not.
            lines.append("  \(pad("instead", to: 14))\"\(prose.prefix(400))\"")
        }

        lines.append("")
        lines.append("  \(outcome.detail)")

        if let prediction, let disagreement = disagreement(outcome, prediction) {
            lines.append("")
            lines.append("  \(disagreement)")
        }

        return lines.joined(separator: "\n")
    }

    private static func describe(_ prediction: ChatTemplateLibrary.ToolCallingSupport) -> String {
        switch prediction {
        case .supported:   return "supported — the model's own template handles tools"
        case .unsupported: return "unsupported — the template contains no tool handling"
        case .unknown:     return "unknown — nothing readable said either way"
        }
    }

    /// A sentence when the prediction and the observation differ, `nil` when
    /// they agree.
    ///
    /// Silence is the right output for agreement: a line saying "these match"
    /// on every probe trains the reader to skip the section.
    private static func disagreement(
        _ outcome: ToolProbe.Outcome,
        _ prediction: ChatTemplateLibrary.ToolCallingSupport
    ) -> String? {
        switch (prediction, outcome.verdict) {
        case (.supported, .proseInstead):
            return "The plan predicted tool calling would work and it did not. The template reads as "
                + "tool-capable, which is why the prediction exists — this is the case a text search "
                + "cannot catch, and the reason the probe is worth running."

        case (.unsupported, .verified):
            return "The plan predicted tool calling would fail and it worked. The template does not "
                + "mention the fields the prediction looks for, but the model called the tool anyway "
                + "— so the warning the Models pane shows for this file is wrong."

        case (.unknown, .verified):
            return "The plan could not tell either way and the server did: tool calling works here. "
                + "An unreadable template is not a broken one."

        case (.unknown, .proseInstead):
            return "The plan could not tell either way and the server did: tool calling does not "
                + "work here. Point the model at a template that handles tools with --chat-template."

        default:
            return nil
        }
    }
}
