import Foundation

// MARK: - One-click routing activation
//
// Getting a model in front of the agents used to be a sequence of separate
// buttons whose order mattered and whose failure modes were invisible:
//
//   a registered API backend — add it, fetch models, pick one, start the
//   router, then bind the agents;
//   a local GGUF — serve it, register it as a backend, switch to the other
//   pane, select it, start the router, then bind the agents.
//
// Five or six presses across two sheets, and not one of them said whether the
// chain had actually worked. The symptom of getting it wrong is not an error:
// it is a user with a model loaded and a router listening whose agents are
// still quietly talking to Anthropic.
//
// This type is the whole chain expressed once, as a list of named steps with a
// remedy attached to each failure, so that:
//
//   - the app and `jxcode activate` run the *same* sequence rather than two
//     that drift, and
//   - "it did not work" comes with the specific reason and the specific fix
//     instead of a spinner that stops.
//
// The side effects are injected. The GUI's handles wrap `AppState` (which owns
// the running router, the supervised llama-server and the published UI state);
// the CLI's handles build those objects directly. Everything that decides what
// happens, what it is called, and what to do when it fails lives here.

/// What the user pointed one click at.
public enum ActivationSource: Sendable, Equatable {
    /// A backend already registered, optionally with a model chosen.
    case registered(id: UUID?, model: String?)
    /// A GGUF file on disk, to be loaded and served before anything else.
    case localModel(path: String, memory: MemoryPolicy, cache: CachePolicy, sampling: SamplingPreset)
}

/// A local model that is now loaded and answering.
public struct ServedLocalModel: Sendable {
    public var displayName: String
    public var filename: String
    public var port: Int
    /// The server's own answer for the window, when it reported one.
    public var contextLength: Int?
    /// Things worth saying but not worth stopping for — other llama-server
    /// processes sharing unified memory, a context that was clamped, and so on.
    public var warnings: [String]

    public init(
        displayName: String,
        filename: String,
        port: Int,
        contextLength: Int? = nil,
        warnings: [String] = []
    ) {
        self.displayName = displayName
        self.filename = filename
        self.port = port
        self.contextLength = contextLength
        self.warnings = warnings
    }
}

/// One hop of the chain, and whether it is standing.
public struct ActivationStep: Identifiable, Sendable, Equatable {
    public enum Status: String, Sendable {
        case pass, warn, fail, skipped
    }

    public let id: String
    public let title: String
    public let status: Status
    public let detail: String
    /// What to do about it. Present whenever the status is not `.pass`, because
    /// a failure with no next move is the thing this replaces.
    public let remedy: String?

    public init(
        id: String,
        title: String,
        status: Status,
        detail: String,
        remedy: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.remedy = remedy
    }
}

/// The outcome of one activation, as something the UI and the terminal can both
/// render without either inventing its own wording.
public struct ActivationReport: Sendable, Equatable {
    public let source: String
    public let routerURL: String?
    public let steps: [ActivationStep]

    public init(source: String, routerURL: String?, steps: [ActivationStep]) {
        self.source = source
        self.routerURL = routerURL
        self.steps = steps
    }

    public var failures: [ActivationStep] { steps.filter { $0.status == .fail } }
    public var warnings: [ActivationStep] { steps.filter { $0.status == .warn } }

    /// True when nothing failed. Warnings do not make an activation a failure:
    /// a model without tool calling still routes, it just cannot drive an agent
    /// very far, and saying "broken" for that would be wrong.
    public var isWorking: Bool { failures.isEmpty }

    /// One line for a banner, a status row or a shell.
    public var headline: String {
        if let first = failures.first {
            // When the chain never started, the step's title is a tautology —
            // "backend chosen" failed because none was chosen — and the detail
            // is already the whole sentence. Mid-chain the title is the useful
            // half, because it names the hop that is not standing.
            if first.id == ActivationSteps.target {
                return "Routing is not up — \(first.detail)"
            }
            return "Routing is not up — \(first.title.lowercased()): \(first.detail)"
        }
        let routed = steps.first { $0.id == ActivationSteps.bind }
        if let routed, routed.status == .skipped {
            return "\(source) is routed on \(routerURL ?? "the router"), but no agent was pointed at it."
        }
        if !warnings.isEmpty {
            return "Routing is up: \(source) → \(routerURL ?? "router"). \(warnings.count) warning(s)."
        }
        return "Routing is up: \(source) → \(routerURL ?? "router")."
    }

    /// The same report as text, so `jxcode activate` cannot describe a
    /// different outcome from the window.
    public func rendered() -> String {
        var lines: [String] = []
        lines.append("JXCode routing activation")
        lines.append(String(repeating: "─", count: 64))
        lines.append("  target   \(source)")
        lines.append("  router   \(routerURL ?? "—")")
        lines.append(String(repeating: "─", count: 64))

        for step in steps {
            let marker: String
            switch step.status {
            case .pass:    marker = "  ok  "
            case .warn:    marker = " warn "
            case .fail:    marker = " FAIL "
            case .skipped: marker = " skip "
            }
            lines.append("[\(marker)] \(step.title)")
            if !step.detail.isEmpty {
                for line in step.detail.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("         \(line)")
                }
            }
            if let remedy = step.remedy, !remedy.isEmpty {
                for line in remedy.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("         → \(line)")
                }
            }
        }

        lines.append(String(repeating: "─", count: 64))
        lines.append(headline)
        return lines.joined(separator: "\n")
    }

    /// A report for a failure that happened before the chain could start.
    public static func refused(source: String, reason: String, remedy: String?) -> ActivationReport {
        ActivationReport(
            source: source,
            routerURL: nil,
            steps: [ActivationStep(
                id: ActivationSteps.target,
                title: "Backend chosen",
                status: .fail,
                detail: reason,
                remedy: remedy
            )]
        )
    }
}

/// The step ids, named once so the report, the UI and the CLI agree on which
/// hop they are talking about.
public enum ActivationSteps {
    public static let target   = "target"
    public static let upstream = "upstream"
    public static let register = "register"
    public static let router   = "router"
    public static let bind     = "bind"
    public static let verify   = "verify"
}

/// Everything the chain has to touch, injected.
///
/// Deliberately small. Each of these is a thing only the caller can do — the
/// app because the objects are already running and mirrored into the UI, the
/// CLI because it builds them from scratch — and none of them is a decision
/// about *order* or *wording*, which is the part that belongs here.
///
/// Deliberately **not** `@MainActor`, and every handle that only reads state is
/// `async` even though it has nothing to wait for. The reason is the CLI: it
/// drives this chain from a blocking entry point, and a handle that demanded the
/// main actor would deadlock against the thread that is waiting for it. Leaving
/// the handles non-isolated costs the app a `MainActor.run` hop per read, which
/// is the cheap half of that trade.
public struct ActivationHandles {

    /// Load a local GGUF and return once it is answering.
    public var serveLocal: (ActivationSource) async throws -> ServedLocalModel

    /// The registered backends, so a local model can reuse its own entry
    /// instead of appending a duplicate on every run.
    public var providers: () async -> [Provider]

    /// Persist a backend and return the stored copy.
    public var register: (Provider) async throws -> Provider

    /// Point the live router at this backend and model, and return its base URL.
    /// Must not return before the listener is accepting connections.
    public var startRouter: (Provider, String, UInt16) async throws -> String

    /// Write each agent's config. Returns one report per agent.
    public var bind: (String, String) async throws -> [AgentConfigWriter.Report]

    /// Ask the backend for its model list.
    public var probeModels: (Provider) async throws -> [String]

    /// The stored router credential, so the self-test sends what the agents send.
    public var auth: () async -> RouterAuth

    public init(
        serveLocal: @escaping (ActivationSource) async throws -> ServedLocalModel,
        providers: @escaping () async -> [Provider],
        register: @escaping (Provider) async throws -> Provider,
        startRouter: @escaping (Provider, String, UInt16) async throws -> String,
        bind: @escaping (String, String) async throws -> [AgentConfigWriter.Report],
        probeModels: @escaping (Provider) async throws -> [String],
        auth: @escaping () async -> RouterAuth
    ) {
        self.serveLocal = serveLocal
        self.providers = providers
        self.register = register
        self.startRouter = startRouter
        self.bind = bind
        self.probeModels = probeModels
        self.auth = auth
    }
}

/// What one click asked for.
public struct ActivationRequest: Sendable {
    public var source: ActivationSource
    public var port: UInt16
    /// Skip writing agent configs. Used by `jxcode activate --no-bind`, and by
    /// nothing in the app: the whole point there is that the agents come along.
    public var bindAgents: Bool
    /// Run a real round trip through the router at the end.
    public var verify: Bool

    public init(
        source: ActivationSource,
        port: UInt16 = RouterConfiguration.defaultPort,
        bindAgents: Bool = true,
        verify: Bool = true
    ) {
        self.source = source
        self.port = port
        self.bindAgents = bindAgents
        self.verify = verify
    }
}

/// The chain, in one place.
public enum RoutingActivation {

    /// Activate, or come back with the reason and the fix.
    ///
    /// Never throws. Every failure is a step in the report, because the caller
    /// is a button and a button cannot render an exception.
    public static func run(
        _ request: ActivationRequest,
        handles: ActivationHandles
    ) async -> ActivationReport {
        var steps: [ActivationStep] = []
        var routerURL: String?

        // MARK: 1. Resolve the target

        let resolved = await resolve(request.source, handles: handles)
        guard var target = resolved.target else {
            return ActivationReport.refused(
                source: resolved.label,
                reason: resolved.problem ?? "no backend selected",
                remedy: resolved.remedy
            )
        }
        steps.append(ActivationStep(
            id: ActivationSteps.target,
            title: "Backend chosen",
            status: .pass,
            detail: "\(target.provider.name) · \(target.model)"
        ))

        // MARK: 2. The upstream has to be answering before anything is aimed at it

        if case .localModel = request.source {
            do {
                let served = try await handles.serveLocal(request.source)

                // The backend entry is built here, from the port the server
                // actually took, rather than by the caller. A local model is
                // served on whatever port was free, so a provider registered
                // from the path alone would name the wrong one — and the
                // failure is a 500 "could not connect" on the first request,
                // which says nothing about the port.
                target.provider.baseURL = "http://127.0.0.1:\(served.port)"
                target.provider.name = "\(served.displayName) (local)"
                target.provider.models = [served.filename]
                target.provider.contextLength = served.contextLength
                target.model = served.filename

                steps.append(ActivationStep(
                    id: ActivationSteps.upstream,
                    title: "Local model is serving",
                    status: served.warnings.isEmpty ? .pass : .warn,
                    detail: "\(served.displayName) on http://127.0.0.1:\(served.port)"
                        + (served.contextLength.map { " · \($0) token window" } ?? "")
                        + (served.warnings.isEmpty ? "" : "\n" + served.warnings.joined(separator: "\n")),
                    remedy: served.warnings.isEmpty
                        ? nil
                        : "These are warnings, not failures — the model loaded. "
                            + "Close the other server if memory gets tight."
                ))
            } catch {
                steps.append(ActivationStep(
                    id: ActivationSteps.upstream,
                    title: "Local model is serving",
                    status: .fail,
                    detail: "\(error)",
                    remedy: "The server's own log tail is in the message above. The usual causes:\n"
                        + "· no llama-server found — see the Runtime card in Local models\n"
                        + "· another llama-server already holds the port or the memory\n"
                        + "· the model needs more memory than the current policy allows — "
                        + "switch Memory to balanced or maximal"
                ))
                return ActivationReport(source: target.provider.name, routerURL: nil, steps: steps)
            }
        } else {
            // A registered backend. Its models have to be reachable, or the
            // router will start happily and 404 on the first real request.
            var probe = target.provider
            do {
                let models = try await handles.probeModels(probe)
                probe.models = models
                probe.lastSyncedAt = Date()
                if models.isEmpty {
                    steps.append(ActivationStep(
                        id: ActivationSteps.upstream,
                        title: "Backend is answering",
                        status: .fail,
                        detail: "\(probe.normalizedBaseURL) replied with no models",
                        remedy: "The server is up but advertises nothing to run. Check that a model "
                            + "is loaded, or point this backend at a different base URL."
                    ))
                    return ActivationReport(source: probe.name, routerURL: nil, steps: steps)
                }
                if !models.contains(target.model) {
                    steps.append(ActivationStep(
                        id: ActivationSteps.upstream,
                        title: "Backend is answering",
                        status: .warn,
                        detail: "\(models.count) model(s), but not '\(target.model)'. "
                            + "The router will send that name upstream anyway.",
                        remedy: "Pick one of the models it does serve: "
                            + models.prefix(6).joined(separator: ", ")
                    ))
                } else {
                    steps.append(ActivationStep(
                        id: ActivationSteps.upstream,
                        title: "Backend is answering",
                        status: .pass,
                        detail: "\(probe.normalizedBaseURL) · \(models.count) model(s)"
                    ))
                }
            } catch {
                steps.append(ActivationStep(
                    id: ActivationSteps.upstream,
                    title: "Backend is answering",
                    status: .fail,
                    detail: "\(error)",
                    remedy: "The router would start and then fail on the first request, so this stops "
                        + "here instead. Fix the backend, then press Activate again."
                ))
                return ActivationReport(source: probe.name, routerURL: nil, steps: steps)
            }
        }

        // MARK: 3. A backend the router can be pointed at

        let provider: Provider
        do {
            provider = try await handles.register(target.provider)
            steps.append(ActivationStep(
                id: ActivationSteps.register,
                title: "Registered as a backend",
                status: .pass,
                detail: "\(provider.name) [\(provider.kind.rawValue)] · \(provider.normalizedBaseURL)"
            ))
        } catch {
            steps.append(ActivationStep(
                id: ActivationSteps.register,
                title: "Registered as a backend",
                status: .fail,
                detail: "\(error)",
                remedy: "The router can only forward to a backend in its own list. "
                    + "Check that the sandbox's state directory is writable."
            ))
            return ActivationReport(source: target.provider.name, routerURL: nil, steps: steps)
        }

        // MARK: 4. The router

        do {
            let base = try await handles.startRouter(provider, target.model, request.port)
            routerURL = base
            let auth = await handles.auth()
            let authLine = auth.isEnabled
                ? "auth        on — agents carry the router token"
                : "auth        off — any process that can reach the port can spend your keys"
            steps.append(ActivationStep(
                id: ActivationSteps.router,
                title: "Router is listening",
                status: .pass,
                detail: base + "\n" + authLine
            ))
        } catch {
            steps.append(ActivationStep(
                id: ActivationSteps.router,
                title: "Router is listening",
                status: .fail,
                detail: "\(error)",
                remedy: "Port \(request.port) could not be bound. Something else is already "
                    + "listening on it — change the port in the router card, or stop whatever "
                    + "holds it."
            ))
            return ActivationReport(source: provider.name, routerURL: nil, steps: steps)
        }

        guard let base = routerURL else {
            return ActivationReport(source: provider.name, routerURL: nil, steps: steps)
        }

        // MARK: 5. The agents

        if request.bindAgents {
            do {
                let reports = try await handles.bind(base, target.model)
                let routed = reports.filter(\.isRouted)
                let refused = reports.filter { $0.action == .refused }

                if routed.isEmpty {
                    steps.append(ActivationStep(
                        id: ActivationSteps.bind,
                        title: "Agents pointed at the router",
                        status: .fail,
                        detail: "no agent config was written",
                        remedy: "Install an agent from the dashboard first — an agent that is not "
                            + "installed has no config to point anywhere."
                    ))
                } else {
                    steps.append(ActivationStep(
                        id: ActivationSteps.bind,
                        title: "Agents pointed at the router",
                        status: refused.isEmpty ? .pass : .warn,
                        detail: "\(routed.count) agent(s): "
                            + routed.map(\.agentName).joined(separator: ", ")
                            + (refused.isEmpty
                                ? ""
                                : "\nleft alone: " + refused.map(\.agentName).joined(separator: ", ")),
                        remedy: refused.isEmpty
                            ? nil
                            : "Those files are not shaped the way JXCode writes them, so they were "
                                + "not touched. They reach the router through the environment "
                                + "instead, which is enough for most agents."
                    ))
                }
            } catch {
                steps.append(ActivationStep(
                    id: ActivationSteps.bind,
                    title: "Agents pointed at the router",
                    status: .fail,
                    detail: "\(error)",
                    remedy: "The router is up and the backend is live — only the agent configs are "
                        + "missing. Retry from Model routing once the error above is cleared."
                ))
            }
        } else {
            steps.append(ActivationStep(
                id: ActivationSteps.bind,
                title: "Agents pointed at the router",
                status: .skipped,
                detail: "skipped on request"
            ))
        }

        // MARK: 6. Does a request actually come back?

        if request.verify {
            let auth = await handles.auth()
            let outcome = await RouterSelfTest.roundTrip(
                routerURL: base,
                model: target.model,
                token: auth.isEnabled ? auth.token : nil
            )
            steps.append(ActivationStep(
                id: ActivationSteps.verify,
                title: "Round trip through the router",
                status: outcome.ok ? .pass : .fail,
                detail: outcome.detail,
                remedy: outcome.ok ? nil : outcome.remedy
            ))
        } else {
            steps.append(ActivationStep(
                id: ActivationSteps.verify,
                title: "Round trip through the router",
                status: .skipped,
                detail: "skipped on request"
            ))
        }

        return ActivationReport(source: provider.name, routerURL: base, steps: steps)
    }

    // MARK: - Resolving the target

    private struct Target {
        var provider: Provider
        var model: String
    }
    private struct Resolution {
        var label: String
        var target: Target?
        var problem: String?
        var remedy: String?
    }

    private static func resolve(
        _ source: ActivationSource,
        handles: ActivationHandles
    ) async -> Resolution {
        switch source {
        case .registered(let id, let model):
            let all = await handles.providers()
            guard !all.isEmpty else {
                return Resolution(
                    label: "no backend",
                    target: nil,
                    problem: "no backend is registered",
                    remedy: "Add one in Model routing, or from a terminal with "
                        + "`jxcode provider-add <name> <base-url>` — a hosted API needs a key "
                        + "too. To route a local model instead: `jxcode activate <file.gguf>`."
                )
            }
            let provider = id.flatMap { wanted in all.first { $0.id == wanted } } ?? all[0]

            guard let chosen = model ?? provider.models.first else {
                return Resolution(
                    label: provider.name,
                    target: nil,
                    problem: "\(provider.name) has no model selected",
                    remedy: "Fetch its model list and pick one — the router rewrites whatever an "
                        + "agent asks for to the model chosen here."
                )
            }
            return Resolution(
                label: provider.name,
                target: Target(provider: provider, model: chosen),
                problem: nil,
                remedy: nil
            )

        case .localModel(let path, _, _, _):
            let name = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                .lastPathComponent
                .replacingOccurrences(of: ".gguf", with: "")
            return Resolution(
                label: name,
                target: Target(
                    provider: Provider(
                        name: "\(name) (local)",
                        kind: .localGGUF,
                        baseURL: ProviderKind.localGGUF.defaultBaseURL
                    ),
                    model: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                        .lastPathComponent
                ),
                problem: nil,
                remedy: nil
            )
        }
    }
}

// MARK: - Does it actually answer?

/// A real request, through the router, to the backend.
///
/// `/health` proves the router is listening and nothing else — the provider and
/// model it reports are read from its own configuration, so a router pointed at
/// a backend that does not exist still reports healthy. The only check that
/// means anything is a completion, and it is deliberately one token long: the
/// cost of asking is negligible next to the cost of believing a chain works
/// because every light in the UI is green.
public enum RouterSelfTest {

    public struct Outcome: Sendable {
        public let ok: Bool
        public let detail: String
        public let remedy: String?

        public init(ok: Bool, detail: String, remedy: String? = nil) {
            self.ok = ok
            self.detail = detail
            self.remedy = remedy
        }
    }

    /// Wait until the router answers its own liveness endpoint.
    ///
    /// `ModelRouter.start` returns once the listener is set up, which is not
    /// quite the same moment as it accepting connections. The app hides the gap
    /// behind a background queue and a flag; a caller that goes straight from
    /// `start` to a request — `jxcode activate` does — would occasionally report
    /// a working chain as broken. Bounded, and only ever called by a caller that
    /// is about to make a request anyway.
    public static func waitUntilListening(
        routerURL: String,
        timeout: TimeInterval = 5
    ) async -> Bool {
        guard let url = URL(string: routerURL + "/health") else { return false }
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode) {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// Ask the router for one token.
    ///
    /// Anthropic-shaped on purpose: `/v1/messages` is the route Claude Code
    /// uses, so a pass here is evidence about the path that matters rather than
    /// about the one that is easier to test.
    public static func roundTrip(
        routerURL: String,
        model: String,
        token: String?,
        timeout: TimeInterval = 120
    ) async -> Outcome {
        guard let url = URL(string: routerURL + "/v1/messages") else {
            return Outcome(ok: false, detail: "\(routerURL) is not a usable URL", remedy: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "x-api-key")
        }
        request.httpBody = Data("""
        {"model":"\(escape(model))","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}
        """.utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return Outcome(ok: false, detail: "the router gave a non-HTTP reply", remedy: nil)
            }

            if (200..<300).contains(http.statusCode) {
                return Outcome(ok: true, detail: "HTTP \(http.statusCode) — the backend answered through the router")
            }

            let body = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(400)
            return Outcome(
                ok: false,
                detail: "HTTP \(http.statusCode): \(body)",
                remedy: remedy(for: http.statusCode)
            )
        } catch {
            return Outcome(
                ok: false,
                detail: "the router could not be reached: \(error.localizedDescription)",
                remedy: "Nothing is listening on that port any more. The router may have exited — "
                    + "start it again from Model routing."
            )
        }
    }

    /// Turn a status code into the sentence that says what to do about it.
    ///
    /// Split out and public so the wording is testable, and so the app and the
    /// CLI cannot disagree about what a 401 means.
    public static func remedy(for status: Int) -> String? {
        switch status {
        case 401, 403:
            return "The router itself refused the request — its token changed since the agents "
                + "were written. Press Activate again to rewrite their configs."
        case 404:
            return "The backend has no route there. The base URL is probably missing or "
                + "doubling a /v1 suffix."
        case 408, 504:
            return "The backend took too long. A local model still loading its weights looks "
                + "exactly like this — wait for it and press Activate again."
        case 429:
            return "The backend is rate limited or out of credit."
        case 500, 502, 503:
            return "The backend refused the request. Check its credits and its key, and read the "
                + "router log for the upstream message."
        default:
            return "The backend answered with an error. The router log has the upstream message."
        }
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
