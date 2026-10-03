import Foundation

// MARK: - One model per server, and why that is the rule
//
// Track 1.4 asked whether to delegate multi-model local serving to llama-server's
// own router mode (`--models-dir` / `--models-max`) or keep jxcode's `ModelRouter`
// in front. The decision is **keep one router**: per-agent model overrides, the
// router's access token and the one-press activation chain all live in
// `ModelRouter`, and a second router inside the backend would be a second place to
// configure them, with neither able to see what the other decided.
//
// What the plan got wrong is the *mechanism*. It reads as though router mode is
// switched on by `--models-dir`, which would make "do not delegate" a rule about
// not passing a flag. Measured against the installed binary, that is not how it
// works. Four runs on build 10150, all with `--host 127.0.0.1` and no model file
// in sight:
//
//   llama-server                                        → router mode, 0 models
//   llama-server --models-max 2                         → router mode, 0 models
//   llama-server -m /nonexistent.gguf                   → not router mode; exits
//   llama-server -m /nonexistent.gguf --models-dir D    → not router mode; exits
//
// Router mode is not opt-in. It is what the server falls back to when **no model
// is named**, and the four `--models-*` flags only *configure* it — beside a `-m`
// they are inert, which is the third and fourth run above. So the rule that keeps
// llama-server out of router mode is not "don't pass `--models-dir`". It is the
// positive one: **every server this app starts is given exactly one model**.
//
// That rule has teeth because router mode fails in the one way this app is built
// to refuse. A model-less server answers `/health` **200** immediately — measured,
// with its own log saying `Available models (0)` in the same second.
// `LlamaServer.start()` confirms a launch by polling `/health`, so a router-mode
// server would be declared healthy while serving nothing, and `/props` then
// answers `role: "router"`, `model_path: "none"`, `n_ctx: 0`, which
// `disagreementsWithPlan()` would report as a plan disagreement rather than as
// "this server has no model in it". Both are recorded in the README.

/// What a `llama-server` is actually serving, read from its argument list.
public enum ModelServingMode: Sendable, Equatable {
    /// One named model. The only mode this app starts a server in.
    case oneModel(path: String)
    /// llama-server's own router: nothing loaded, a model chosen per request.
    /// What the binary does when no model is named, whether or not any
    /// `--models-*` flag was passed.
    case router
    /// `-m` is present and names nothing. llama.cpp reads the *next* argument as
    /// the path, so this is an argument list assembled wrongly rather than a
    /// server that would serve nothing — and it is a startup error either way.
    case malformed

    public var isRouter: Bool { self == .router }
}

public enum ModelServingPolicy {

    // MARK: The decision

    /// The decision, in the words both surfaces print.
    ///
    /// Written once, here, for the same reason every other report is: a decision
    /// stated at two print sites is a decision that will one day be stated two
    /// different ways.
    public static let decision = """
        One model per server, and jxcode's own router in front of it.

        llama-server can serve a whole directory of models itself: with no model named
        it starts in router mode and picks one per request. jxcode does not use that,
        because per-agent model overrides, the router's access token and the one-press
        activation chain all live in jxcode's ModelRouter. A second router inside the
        backend would be a second place to configure them, and neither would know what
        the other decided.

        Router mode is not switched off by a flag. It is what the server falls back to
        when no model is named, so the rule is the positive one: every server this app
        starts is given exactly one `-m`.
        """

    /// Why a server with no model in it is refused rather than started.
    ///
    /// The reason, not the rule, because the rule alone reads as a preference. This
    /// is the failure it prevents: `/health` answers 200 to a server that loaded
    /// nothing, and `start()` treats a 200 as proof of a launch.
    public static let routerModeRefusal =
        "a llama-server with no `-m` starts in its own router mode: it answers "
        + "/health 200 straight away with no model loaded, and /props then reports "
        + "role \"router\" and model_path \"none\" — so the health check this app "
        + "confirms a launch with would call it up, and the plan check would call it "
        + "a disagreement rather than an empty server. jxcode keeps one router, so "
        + "every server it starts is given exactly one model."

    // MARK: The flags

    /// The flags that configure router mode, spelled as the installed binary
    /// spells them.
    ///
    /// Four, not the two the plan named. All four were read out of `--help` on
    /// both kegs installed on this machine — build 10150 (`dee2a846b`) and build
    /// 10964 (`b29c606e2`) — rather than out of a document, and both list the
    /// same four under the same heading, "for the router server".
    public static let routerConfigurationFlags: [String] = [
        "--models-dir",
        "--models-preset",
        "--models-max",
        "--models-autoload",
    ]

    /// What one of them does, in the binary's own terms.
    public static func role(of flag: String) -> String {
        switch flag {
        case "--models-dir":
            return "the directory router mode loads models from"
        case "--models-preset":
            return "an INI file of model presets — the other way to feed router mode"
        case "--models-max":
            return "how many models router mode may hold at once (binary default 4)"
        case "--models-autoload":
            return "whether router mode loads a model on demand (binary default on)"
        case "--no-models-autoload":
            return "the off spelling of --models-autoload"
        default:
            return "not a router-mode flag"
        }
    }

    /// Whether a spelling names a router-mode flag.
    ///
    /// The `--no-` twin is included because the binary documents
    /// `--models-autoload, --no-models-autoload` as one entry, and a plan that
    /// carried the negated spelling would be describing the same feature.
    public static func isRouterConfigurationFlag(_ flag: String) -> Bool {
        routerConfigurationFlags.contains(flag) || flag == "--no-models-autoload"
    }

    /// The router-mode flags an argument list names, in the order it names them.
    ///
    /// Reported rather than refused. Beside a `-m` these are inert — measured on
    /// build 10150, not assumed — so a plan carrying one still serves exactly one
    /// model. Saying so is the whole point: the alternative is a reader believing
    /// `--models-max 2` bought them two models, which is what the plan's own
    /// sentence about `--models-dir` implies.
    public static func configuredRouterFlags(in arguments: [LlamaArgument]) -> [String] {
        var seen: [String] = []
        for argument in arguments where isRouterConfigurationFlag(argument.flag) {
            if !seen.contains(argument.flag) { seen.append(argument.flag) }
        }
        return seen
    }

    // MARK: The discriminator

    /// The model a plan names with `-m` / `--model`.
    ///
    /// Both spellings, because the binary accepts both and a server this app did
    /// not start may have used either.
    public static func namedModel(in arguments: [LlamaArgument]) -> String? {
        arguments.first { $0.flag == "-m" || $0.flag == "--model" }?.value
    }

    /// The mode the binary would enter for this argument list.
    ///
    /// This is the check, and it is a check about a *model*, not about a flag —
    /// which is the correction track 1.4 needed. An empty `-m` is separated out
    /// rather than folded into `.router` because the two have different causes and
    /// therefore different remedies: one is a plan that never named a model, the
    /// other is a plan that named it wrongly.
    public static func mode(of arguments: [LlamaArgument]) -> ModelServingMode {
        guard arguments.contains(where: { $0.flag == "-m" || $0.flag == "--model" }) else {
            return .router
        }
        guard let path = namedModel(in: arguments), !path.isEmpty else { return .malformed }
        return .oneModel(path: path)
    }
}
