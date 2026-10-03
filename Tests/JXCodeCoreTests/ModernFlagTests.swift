import XCTest
@testable import JXCodeCore

// The modern flag set: `--jinja`, `--chat-template-kwargs`, `--fit`, `-ncmoe`,
// `--cache-prompt`, `--cache-reuse`, `--cache-ram`, the reasoning group, and
// `--samplers`.
//
// Every one of these is a flag that did not exist in older llama.cpp builds, and
// emitting one on a build that lacks it is not a harmless no-op: llama-server
// exits at startup with `error: unknown argument`, which reads to a user as a bug
// in this app rather than a version mismatch. So each is gated on the binary's
// own `--help`, and the gates are the subject of this file.
//
// The gates are only worth anything if real capabilities reach the planner. That
// wiring is asserted separately, at the bottom: a plan built against an old build
// must not name a modern flag, and a plan built against an assumed-modern build
// must name them all — the second because `.assumedModern` is the documented
// fallback and changing what it emits would change every existing behaviour.

/// A help page from a build that has the whole modern set.
///
/// Written as the real thing writes it — short spelling, comma, long spelling,
/// value placeholder — because `defines(_:)` matches on the definition line and
/// a tidied-up fixture would not exercise that.
private let modernHelp = """
usage: llama-server [options]

----- common params -----
-m,    --model FNAME                    model path to load
--jinja, --no-jinja                     whether to use jinja template engine for chat (default: enabled)
--chat-template-kwargs STRING           sets additional params for the json template parser
--fit,  --fit [on|off]                  whether to adjust unset arguments to fit in device memory
-fitt, --fit-target MiB0,MiB1,MiB2,...  target margin per device
-ncmoe, --n-cpu-moe N                   keep the Mixture of Experts (MoE) weights of the first N layers in the CPU
-cram, --cache-ram N                    set the maximum cache size in MiB (default: 8192, -1 - no limit)
--cache-prompt, --no-cache-prompt       whether to enable prompt caching (default: enabled)
--cache-reuse N                         min chunk size to attempt reusing from the cache via KV shifting
--context-shift, --no-context-shift     whether to use context shift on infinite text generation (default: disabled)
--samplers SAMPLERS                     samplers that will be used for generation in the order, separated by ';'
--reasoning-format FORMAT               controls whether thought tags are allowed and/or extracted from the response
-rea,  --reasoning [on|off|auto]        Use reasoning/thinking in the chat (default: 'auto' (detect from template))
--reasoning-budget N                    token budget for thinking: -1 for unrestricted, 0 for immediate end
--reasoning-preserve, --no-reasoning-preserve  preserve reasoning trace in the full history
"""

/// A help page from a build that predates all of it.
private let ancientHelp = """
usage: llama-server [options]

----- common params -----
-m,    --model FNAME                    model path to load
-fa,   --flash-attn                     enable flash attention
--mlock                                force system to keep model in RAM
-n,    --n-predict N                   number of tokens to predict
"""

private let modern = LlamaServerCapabilities.parse(helpText: modernHelp)
private let ancient = LlamaServerCapabilities.parse(helpText: ancientHelp)

/// The eleven flags track 1.2 added, in the order the planner emits them.
private let modernFlags = [
    "--chat-template-kwargs", "--reasoning-format", "-rea", "--reasoning-budget",
    "--reasoning-preserve", "--fit", "-ncmoe", "--cache-prompt", "--cache-reuse",
    "--cache-ram", "--samplers",
]

/// The subset a modern build is given for a model that does **not** fit.
///
/// Two of the eleven are absent from this list, and neither absence is an
/// oversight:
///
///   - `--chat-template-kwargs` is suppressed wherever the build defines
///     `--reasoning`, which is the modern spelling of the same request. Its own
///     tests below pin both directions.
///   - `--cache-ram` is suppressed wherever the derivation lands on the
///     sentinel. A model that does not fit leaves nothing over for the prompt
///     cache, so the arithmetic reaches 0 — and 0 means `disable` in this flag's
///     vocabulary, not "a small bound". Its own tests below pin both directions.
///
/// The two are mutually exclusive by construction rather than by accident:
/// `-ncmoe` fires exactly when the model overflows, and `--cache-ram` fires
/// exactly when it fits with a tight margin. No single geometry can exercise
/// both, which is why the "whole set" assertions are scoped to this list and the
/// exceptions are asserted individually.
private let modernFlagsForAnOverflowingModel = [
    "--reasoning-format", "-rea", "--reasoning-budget", "--reasoning-preserve",
    "--fit", "-ncmoe", "--cache-prompt", "--cache-reuse", "--samplers",
]

/// A template with a thinking branch, which is what the reasoning group is
/// gated on. The check is a substring test for `<think` or `reasoning`, so the
/// fixture has to contain one of them literally — a template that merely *has* a
/// thinking branch under another spelling would leave the group unexercised.
private let thinkingTemplate = """
{% for m in messages %}<|{{ m.role }}|>{{ m.content }}<|end|>{% endfor %}
{% if enable_thinking %}<think>{% endif %}
{% if tools %}<tools>{{ tools }}</tools>{% endif %}
"""

// MARK: - `defines`

final class CapabilityDefinitionsTests: XCTestCase {

    func testEveryModernFlagIsFoundOnTheBuildThatDefinesIt() {
        for flag in modernFlags {
            XCTAssertTrue(modern.defines(flag), "\(flag) was not found in its own help page")
        }
    }

    func testNoneOfTheModernFlagsIsFoundOnTheOldBuild() {
        for flag in modernFlags {
            XCTAssertFalse(ancient.defines(flag), "\(flag) was reported present on a build without it")
        }
    }

    /// The reason the match is on the *definition* line and not on any mention.
    ///
    /// A modern build's help text names `--load-mode` on the very flags it
    /// deprecated, so a bare `contains` reports support on a build that would
    /// reject the flag as an argument. The same trap applies to anything a build
    /// ever cross-references.
    func testAMentionInAnotherFlagsHelpIsNotADefinition() {
        let help = """
        usage: llama-server [options]

        --mlock    force system to keep model in RAM (DEPRECATED in favor of --load-mode)
        """
        let capabilities = LlamaServerCapabilities.parse(helpText: help)

        XCTAssertFalse(capabilities.defines("--load-mode"))
        XCTAssertTrue(capabilities.defines("--mlock"), "the flag that line defines is still defined")
    }

    /// Both spellings of a flag resolve to the same answer.
    ///
    /// The planner gates on the long form and emits the short one for `-ncmoe`
    /// and `-rea`, so a matcher that only understood one spelling would gate on
    /// a flag it never emits.
    func testTheShortAndLongSpellingsAgree() {
        XCTAssertTrue(modern.defines("-ncmoe"))
        XCTAssertTrue(modern.defines("--n-cpu-moe"))
        XCTAssertTrue(modern.defines("-rea"))
        XCTAssertTrue(modern.defines("--reasoning"))
        XCTAssertTrue(modern.defines("-cram"))
        XCTAssertTrue(modern.defines("--cache-ram"))
    }

    /// An unreadable help text is treated as a modern build.
    ///
    /// Optimistic on purpose: guessing modern when the build is old produces a
    /// startup error the user can see and report, whereas guessing old silently
    /// drops features that are present.
    func testAnUnreadableHelpTextClaimsEverything() {
        for flag in modernFlags {
            XCTAssertTrue(LlamaServerCapabilities.assumedModern.defines(flag))
        }
    }
}

// MARK: - The planner's gates

final class ModernFlagPlanningTests: XCTestCase {

    private func optimizer(
        memoryGB: Double = 32,
        policy: MemoryPolicy = .safe,
        cache: CachePolicy = .balanced,
        sampling: SamplingPreset = .default,
        capabilities: LlamaServerCapabilities = .assumedModern
    ) -> ModelOptimizer {
        ModelOptimizer(
            hardware: .synthetic(memoryGB: memoryGB, performanceCores: 8, efficiencyCores: 4),
            policy: policy,
            cachePolicy: cache,
            sampling: sampling,
            capabilities: capabilities
        )
    }

    private func plan(
        _ optimizer: ModelOptimizer,
        info: GGUFModelInfo? = nil,
        modelBytes: UInt64 = 4 * 1_073_741_824
    ) -> OptimizationPlan {
        optimizer.plan(
            modelPath: "/models/Model.gguf",
            mmprojPath: nil,
            info: info ?? makeModelInfo(),
            modelBytes: modelBytes,
            projectorBytes: 0
        )
    }

    private func flags(_ plan: OptimizationPlan) -> Set<String> {
        Set(plan.arguments.map(\.flag))
    }

    /// A Mixture-of-Experts model that reasons and does not fit.
    ///
    /// Chosen so that most of the modern set has a reason to be emitted: `-ncmoe`
    /// needs a MoE that overflows and the reasoning group needs a template with a
    /// thinking branch. A model that fit comfortably would leave both
    /// unexercised, and the gates would look correct while testing nothing.
    private var crowded: (info: GGUFModelInfo, bytes: UInt64) {
        (makeModelInfo(blockCount: 40, chatTemplate: thinkingTemplate, expertCount: 8),
         UInt64(30 * 1_073_741_824))
    }

    // MARK: Both directions of the gate

    /// The one-variable comparison: same machine, same model, same policies.
    /// The only difference between this test and the next is which binary the
    /// planner was told about.
    func testAnOldBuildIsSparedEveryModernFlag() {
        let planned = plan(
            optimizer(memoryGB: 16, capabilities: ancient),
            info: crowded.info,
            modelBytes: crowded.bytes
        )

        for flag in modernFlags {
            XCTAssertFalse(
                flags(planned).contains(flag),
                "\(flag) was emitted for a build whose help page does not define it"
            )
        }
    }

    func testTheModernBuildGetsTheSetItCanRun() {
        let planned = plan(
            optimizer(memoryGB: 16, capabilities: modern),
            info: crowded.info,
            modelBytes: crowded.bytes
        )

        for flag in modernFlagsForAnOverflowingModel {
            XCTAssertTrue(
                flags(planned).contains(flag),
                "\(flag) was withheld from a build that defines it and a geometry that needs it"
            )
        }
    }

    func testTheAssumedCapabilitiesEmitTheSameSet() {
        // `.assumedModern` is the fallback when the help text cannot be read, and
        // it claims every flag. A plan built against it must therefore look
        // exactly as it did before the gates existed — otherwise the gates would
        // have silently changed every existing behaviour rather than adding
        // protection for the builds that need it.
        let planned = plan(
            optimizer(memoryGB: 16, capabilities: .assumedModern),
            info: crowded.info,
            modelBytes: crowded.bytes
        )

        for flag in modernFlagsForAnOverflowingModel {
            XCTAssertTrue(flags(planned).contains(flag), "\(flag) went missing under .assumedModern")
        }
    }

    // MARK: `--jinja`

    /// A model file that carries its own template gets `--jinja` from the
    /// template resolution, and the planner must not add a second one.
    ///
    /// The first draft of track 1.2 did, and the command line read
    /// `--jinja --jinja`. No unit test could have caught it — both arguments
    /// were well formed and the flag was present — which is why the assertion is
    /// on the *count*.
    func testJinjaIsStatedExactlyOnce() {
        let planned = plan(optimizer())

        let count = planned.arguments.filter { $0.flag == "--jinja" }.count
        XCTAssertEqual(count, 1, "expected one --jinja, got \(count)")
    }

    func testJinjaIsStillCarriedByTheTemplateResolution() {
        // Removing the planner's duplicate must not remove the flag itself: the
        // template resolution owns it, and it carries the better reason.
        let planned = plan(optimizer())
        let jinja = planned.arguments.first { $0.flag == "--jinja" }

        XCTAssertEqual(jinja?.category, .template)
        XCTAssertTrue(jinja?.reason.contains("chat template") == true, "\(jinja?.reason ?? "nil")")
    }

    // MARK: `--chat-template-kwargs`

    /// On a build that has `--reasoning`, `enable_thinking` through the template
    /// kwargs is the deprecated spelling of the same request.
    ///
    /// Build 10150 says so at startup, and the check is not theoretical: two
    /// servers with one variable between them — same model, same prompt — both
    /// returned a `thinking` block with `-rea on` alone, and the one with the
    /// kwarg returned the same block plus a deprecation warning. Emitting both
    /// asks for one thing twice in two vocabularies.
    func testTemplateKwargsAreWithheldWhereReasoningReplacesThem() {
        let info = makeModelInfo(chatTemplate: thinkingTemplate)
        let planned = plan(optimizer(capabilities: modern), info: info)

        XCTAssertFalse(flags(planned).contains("--chat-template-kwargs"))
        XCTAssertNil(planned.templateKwargs, "the plan still carries the deprecated kwargs")
        XCTAssertTrue(flags(planned).contains("-rea"), "the replacement must actually be emitted")
    }

    /// On a build with the kwarg and no `--reasoning`, it is the only lever, so
    /// it is still emitted — and the plan says so, for the probe to reuse.
    func testTemplateKwargsAreSentOnABuildWithoutReasoning() {
        let help = """
        usage: llama-server [options]

        --jinja, --no-jinja                     whether to use jinja template engine for chat
        --chat-template-kwargs STRING           sets additional params for the json template parser
        --samplers SAMPLERS                     samplers used for generation
        """
        let capabilities = LlamaServerCapabilities.parse(helpText: help)
        let info = makeModelInfo(chatTemplate: thinkingTemplate)
        let planned = plan(optimizer(capabilities: capabilities), info: info)

        let kwargs = planned.arguments.first { $0.flag == "--chat-template-kwargs" }
        XCTAssertNotNil(kwargs, "the only lever available was withheld")
        XCTAssertEqual(kwargs?.value, #"{"enable_thinking":true}"#)
        XCTAssertEqual(planned.templateKwargs, ["enable_thinking": .bool(true)])
    }

    /// A template that never reads the variable must not be handed it.
    ///
    /// Sending a keyword argument to a template with no use for it reads as
    /// tuning and does nothing, which is the worst combination in a plan whose
    /// every line is meant to be load-bearing.
    func testTemplateKwargsAreNotSentToATemplateThatIgnoresThem() {
        let help = """
        usage: llama-server [options]

        --jinja, --no-jinja                     whether to use jinja template engine for chat
        --chat-template-kwargs STRING           sets additional params for the json template parser
        """
        let capabilities = LlamaServerCapabilities.parse(helpText: help)
        let info = makeModelInfo(chatTemplate: "{% for m in messages %}{{ m.content }}{% endfor %}")
        let planned = plan(optimizer(capabilities: capabilities), info: info)

        XCTAssertFalse(flags(planned).contains("--chat-template-kwargs"))
        XCTAssertNil(planned.templateKwargs)
    }

    func testNoTemplateMeansNoKwargs() {
        let help = """
        usage: llama-server [options]

        --chat-template-kwargs STRING           sets additional params for the json template parser
        """
        let capabilities = LlamaServerCapabilities.parse(helpText: help)
        let planned = plan(optimizer(capabilities: capabilities), info: makeModelInfo(chatTemplate: nil))

        XCTAssertNil(planned.templateKwargs)
    }

    // MARK: `--cache-ram`

    /// Naming a flag in order to set the value it already has says nothing.
    ///
    /// Worse than nothing here: the reason beside it claims to bound the cache
    /// more tightly than llama.cpp's fixed default, while the value is that
    /// default. The first draft printed `--cache-ram 8192` with exactly that
    /// sentence next to it — the flag was present, the value was legal, and only
    /// the prose was false.
    ///
    /// The geometry matters and is not obvious. The context ladder deliberately
    /// spends most of the budget on KV cache, so a big machine with a big model
    /// still ends up with a *tight* prompt-cache margin. What leaves headroom
    /// above the default is a model whose trained context caps the ladder early
    /// — an 8k-context model on a 32 GB machine, which is the ordinary shape of a
    /// small local model.
    func testCacheRAMIsOmittedWhenItWouldOnlyRestateTheDefault() {
        let planned = plan(
            optimizer(memoryGB: 32, capabilities: modern),
            info: makeModelInfo(contextLength: 8_192)
        )

        XCTAssertFalse(
            flags(planned).contains("--cache-ram"),
            "the derived bound clamps to llama.cpp's own default, so the flag is a no-op"
        )
    }

    func testCacheRAMAppearsWhenTheDerivedBoundIsTighter() {
        // A small machine with a big model: whatever is left for the prompt
        // cache is well under llama.cpp's flat 8192 MiB.
        let planned = plan(
            optimizer(memoryGB: 16, capabilities: modern),
            modelBytes: 6 * 1_073_741_824
        )

        let argument = planned.arguments.first { $0.flag == "--cache-ram" }
        let value = argument.flatMap { $0.value }.flatMap(UInt64.init)

        XCTAssertNotNil(argument, "a tighter bound than the default was not stated")
        XCTAssertNotNil(value)
        XCTAssertLessThan(value ?? .max, ModelOptimizer.defaultCacheRAMMiB)
    }

    /// `0` is not a small bound in this flag's vocabulary, it is `disable`.
    ///
    /// The binary's own help page says so: "(default: 8192, -1 - no limit, 0 -
    /// disable)". So when a model does not fit and nothing is left over, the
    /// derivation reaches 0 — and spelling that as `--cache-ram 0` would enable
    /// prompt caching with one flag and give it no memory with the next, quietly
    /// defeating the `--cache-reuse` that depends on it. A derivation that lands
    /// on the sentinel is not expressible with this flag, so it is not spelled
    /// with it, and the warning about the model not fitting carries the fact.
    func testCacheRAMIsNotSpelledAsZeroWhenTheArithmeticLandsThere() {
        let planned = plan(
            optimizer(memoryGB: 16, capabilities: modern),
            info: crowded.info,
            modelBytes: crowded.bytes
        )

        let argument = planned.arguments.first { $0.flag == "--cache-ram" }
        XCTAssertNil(argument, "the plan spelled a sentinel as if it were a bound")
        XCTAssertTrue(
            planned.warnings.contains { $0.contains("does not fit") },
            "the fact the flag could not carry has to be said somewhere: \(planned.warnings)"
        )
    }

    /// Whatever bound is emitted has to be a bound: above zero, below the
    /// default. Anything outside that range either disables the cache or restates
    /// llama.cpp's own value.
    func testTheCacheRAMBoundIsAlwaysInsideTheOpenRange() {
        for memoryGB in [8.0, 16.0, 32.0, 64.0, 128.0] {
            for contextLength in [4_096, 8_192, 32_768, 131_072] {
                let planned = plan(
                    optimizer(memoryGB: memoryGB, capabilities: modern),
                    info: makeModelInfo(contextLength: contextLength)
                )
                guard let value = planned.arguments
                    .first(where: { $0.flag == "--cache-ram" })?
                    .value
                    .flatMap(UInt64.init) else { continue }
                XCTAssertGreaterThan(value, 0, "at \(memoryGB) GB / \(contextLength) tokens")
                XCTAssertLessThan(value, ModelOptimizer.defaultCacheRAMMiB, "at \(memoryGB) GB / \(contextLength) tokens")
            }
        }
    }

    // MARK: `-ncmoe`

    /// The partial-offload lever is for a Mixture-of-Experts model and nothing
    /// else. `-ncmoe N` moves expert weights, so on a dense model it is
    /// meaningless — llama-server would accept it and the plan would be lying.
    func testTheMoELeverIsNotPulledForADenseModel() {
        let planned = plan(
            optimizer(memoryGB: 16, capabilities: modern),
            info: makeModelInfo(expertCount: 1),
            modelBytes: 30 * 1_073_741_824
        )

        XCTAssertFalse(flags(planned).contains("-ncmoe"))
    }

    func testTheMoELeverClosesAGapTheModelCannotOtherwiseClose() {
        let info = makeModelInfo(blockCount: 40, expertCount: 8)
        let planned = plan(
            optimizer(memoryGB: 16, capabilities: modern),
            info: info,
            modelBytes: 30 * 1_073_741_824
        )

        let argument = planned.arguments.first { $0.flag == "-ncmoe" }
        let moved = argument.flatMap { $0.value }.flatMap(Int.init)

        XCTAssertNotNil(argument, "a MoE that does not fit had no lever pulled")
        XCTAssertNotNil(moved)
        // At least one layer, and never more layers than the model has: moving
        // expert weights for layers that do not exist is not a plan.
        XCTAssertGreaterThanOrEqual(moved ?? 0, 1)
        XCTAssertLessThanOrEqual(moved ?? .max, 40)
        XCTAssertTrue(
            planned.warnings.contains { $0.contains("Mixture-of-Experts") },
            "the estimate has to be flagged as one: \(planned.warnings)"
        )
    }

    func testTheMoELeverIsNotPulledWhenTheModelFits() {
        // Nothing to close, so nothing to move.
        let planned = plan(
            optimizer(memoryGB: 128, capabilities: modern),
            info: makeModelInfo(blockCount: 40, expertCount: 8),
            modelBytes: 4 * 1_073_741_824
        )

        XCTAssertFalse(flags(planned).contains("-ncmoe"))
    }

    // MARK: The reasoning group

    func testTheReasoningGroupIsOnlyForAModelThatReasons() {
        let plain = plan(optimizer(capabilities: modern), info: makeModelInfo(chatTemplate: "{{ m.content }}"))
        XCTAssertFalse(flags(plain).contains("-rea"))
        XCTAssertFalse(flags(plain).contains("--reasoning-format"))

        let thinking = plan(
            optimizer(capabilities: modern),
            info: makeModelInfo(chatTemplate: thinkingTemplate)
        )
        XCTAssertTrue(flags(thinking).contains("--reasoning-format"))
    }

    /// `--reasoning-preserve` and the reasoning group must not be stated for a
    /// model whose template has no thinking branch at all.
    func testTheReasoningGroupIsAllOrNothing() {
        let planned = plan(optimizer(capabilities: modern), info: makeModelInfo(chatTemplate: "{{ m.content }}"))
        let reasoning = flags(planned).filter { $0.contains("reasoning") || $0 == "-rea" }

        XCTAssertTrue(reasoning.isEmpty, "half a reasoning group is worse than none: \(reasoning)")
    }

    // MARK: `--samplers`

    func testTheSamplerChainIsNamedForAPresetThatConfiguresOne() {
        let planned = plan(optimizer(sampling: .agent, capabilities: modern))
        let argument = planned.arguments.first { $0.flag == "--samplers" }

        XCTAssertEqual(argument?.value, SamplingPreset.agent.samplerChain)
        XCTAssertTrue(flags(planned).contains("--temp"), "the chain must travel with its values")
    }

    /// `.modelDefault` is defined as emitting no sampling flags, so the chain
    /// must not appear either — otherwise "leave the sampler alone" would still
    /// replace the sampler chain.
    func testTheSamplerChainIsAbsentForTheModelDefaultPreset() {
        let planned = plan(optimizer(sampling: .modelDefault, capabilities: modern))

        XCTAssertFalse(flags(planned).contains("--samplers"))
        XCTAssertFalse(flags(planned).contains("--temp"))
    }

    /// The chain goes in front of the values it orders.
    ///
    /// `--samplers` replaces the whole sequence, so a reader scanning the command
    /// line should meet the sequence before the numbers that populate it. The
    /// order is also what the real binary's own help page lists them in.
    func testTheSamplerChainPrecedesTheValuesItOrders() {
        let planned = plan(optimizer(sampling: .balanced, capabilities: modern))
        let flagsInOrder = planned.arguments.map(\.flag)

        guard let chain = flagsInOrder.firstIndex(of: "--samplers"),
              let temperature = flagsInOrder.firstIndex(of: "--temp") else {
            return XCTFail("expected both a chain and a temperature: \(flagsInOrder)")
        }
        XCTAssertLessThan(chain, temperature)
    }
}

// MARK: - The rendered command line

final class RenderedCommandLineTests: XCTestCase {

    /// The rendered command must reproduce the plan when pasted into a shell.
    ///
    /// It did not. `shellQuoted` tested for space, quote and backslash, so every
    /// other shell metacharacter went out bare — and `--samplers
    /// penalties;top_k;top_p;temperature` is the case that shows it: `;` ends a
    /// command, so the shell ran `penalties` and then `top_k` and `top_p` and
    /// `temperature` as four separate commands. The plan's own printed output did
    /// not reproduce the plan.
    func testASemicolonInAValueIsQuoted() {
        XCTAssertEqual(
            OptimizationPlan.shellQuoted("penalties;top_k;top_p;temperature"),
            "'penalties;top_k;top_p;temperature'"
        )
    }

    func testEveryShellMetacharacterIsQuoted() {
        // Not an exhaustive shell grammar — just the characters that would
        // change what the command means if they went out bare.
        for character in [";", "&", "|", "<", ">", "(", ")", "$", "`", "*", "?", "[", "]", "#", "!", "~", "\\", "'", "\"", " ", "\n", "{", "}"] {
            let value = "a\(character)b"
            XCTAssertEqual(
                OptimizationPlan.shellQuoted(value),
                "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'",
                "\(character.debugDescription) was left bare"
            )
        }
    }

    func testOrdinaryValuesAreLeftAlone() {
        // Quoting a path that needs no quoting is noise, and the plan is read by
        // people. The safe set is deliberately generous — but `on|off|auto` is
        // not in it, and must not be: `|` is a pipe.
        for value in ["on", "256", "8192", "0.95", "-1", "/Users/me/Models/M.gguf",
                      "deepseek", "a-b_c.d,e:f=g@h+i%j"] {
            XCTAssertEqual(OptimizationPlan.shellQuoted(value), value)
        }
        XCTAssertEqual(OptimizationPlan.shellQuoted("on|off|auto"), "'on|off|auto'")
    }

    func testAnEmptyValueIsStillAWord() {
        // An empty argv element has to survive as `''`; dropped entirely it would
        // shift every argument after it.
        XCTAssertEqual(OptimizationPlan.shellQuoted(""), "''")
    }

    func testASingleQuoteInsideAValueIsEscaped() {
        XCTAssertEqual(OptimizationPlan.shellQuoted("it's"), #"'it'\''s'"#)
    }

    func testARealPlansCommandLineQuotesItsSamplerChain() {
        let optimizer = ModelOptimizer(
            hardware: .synthetic(memoryGB: 32, performanceCores: 8, efficiencyCores: 4),
            policy: .safe,
            cachePolicy: .balanced,
            sampling: .agent,
            capabilities: .assumedModern
        )
        let planned = optimizer.plan(
            modelPath: "/models/Model.gguf",
            mmprojPath: nil,
            info: makeModelInfo(),
            modelBytes: 4 * 1_073_741_824,
            projectorBytes: 0
        )

        XCTAssertTrue(
            planned.commandLine().contains("'\(SamplingPreset.agent.samplerChain ?? "")'"),
            planned.commandLine()
        )
    }

    /// The JSON in `--chat-template-kwargs` carries double quotes, which is the
    /// case the old rule happened to catch. Asserted so a future simplification
    /// of the safe set cannot lose it.
    func testAJSONValueIsQuoted() {
        XCTAssertEqual(
            OptimizationPlan.shellQuoted(#"{"enable_thinking":true}"#),
            #"'{"enable_thinking":true}'"#
        )
    }
}

// MARK: - The adapter's second line of defence

final class AdaptedModernFlagTests: XCTestCase {

    private func arguments() -> [LlamaArgument] {
        [
            LlamaArgument(flag: "--chat-template-kwargs", value: #"{"a":true}"#, reason: "r", category: .template),
            LlamaArgument(flag: "--reasoning-format", value: "deepseek", reason: "r", category: .template),
            LlamaArgument(flag: "-rea", value: "on", reason: "r", category: .template),
            LlamaArgument(flag: "--reasoning-budget", value: "-1", reason: "r", category: .template),
            LlamaArgument(flag: "--reasoning-preserve", value: nil, reason: "r", category: .template),
            LlamaArgument(flag: "--fit", value: "on", reason: "r", category: .memory),
            LlamaArgument(flag: "-ncmoe", value: "12", reason: "r", category: .memory),
            LlamaArgument(flag: "--cache-prompt", value: nil, reason: "r", category: .context),
            LlamaArgument(flag: "--cache-reuse", value: "256", reason: "r", category: .context),
            LlamaArgument(flag: "--cache-ram", value: "4096", reason: "r", category: .memory),
            LlamaArgument(flag: "--samplers", value: "penalties;top_k", reason: "r", category: .performance),
        ]
    }

    /// The planner gates these, but the planner is not the only way arguments
    /// reach a server: a plan can be built against the assumed capabilities and
    /// then launched on an older binary. `default:` in `adapt` passes anything it
    /// does not recognise straight through, so without this list the whole server
    /// would exit at startup with `unknown argument`.
    func testAdaptStripsTheModernSetOnABuildThatLacksIt() {
        let adapted = LlamaServerCapabilities.parse(helpText: ancientHelp).adapt(arguments())

        XCTAssertTrue(
            adapted.isEmpty,
            "these would take the server down at startup: \(adapted.map(\.flag))"
        )
    }

    func testAdaptKeepsTheModernSetOnABuildThatDefinesIt() {
        let adapted = LlamaServerCapabilities.parse(helpText: modernHelp).adapt(arguments())

        XCTAssertEqual(adapted.map(\.flag), arguments().map(\.flag))
    }

    /// `.assumedModern` has no help text, so it strips nothing — which is what
    /// keeps existing behaviour intact.
    func testTheAssumedCapabilitiesStripNothing() {
        let adapted = LlamaServerCapabilities.assumedModern.adapt(arguments())

        XCTAssertEqual(adapted.map(\.flag), arguments().map(\.flag))
    }

    /// A flag the adapter knows nothing about still passes through, so the list
    /// above is load-bearing rather than decorative.
    func testAnUnknownFlagIsStillPassedThrough() {
        let argument = LlamaArgument(flag: "--something-new", value: "1", reason: "r", category: .memory)
        let adapted = LlamaServerCapabilities.parse(helpText: ancientHelp).adapt([argument])

        XCTAssertEqual(adapted.map(\.flag), ["--something-new"])
    }
}

// MARK: - The probe

final class CapabilityProbeTests: XCTestCase {

    /// A binary that does not exist has no capabilities, and the caller's
    /// fallback is the assumed set rather than nothing.
    func testAProbeOfNothingIsTheAssumedSet() {
        let missing = URL(fileURLWithPath: "/nonexistent/llama-server")
        XCTAssertEqual(LlamaServerCapabilities.cached(binary: missing), .assumedModern)
        XCTAssertNil(LlamaServerCapabilities.probeSynchronously(binary: missing))
    }

    func testNoBinaryAtAllIsTheAssumedSet() {
        XCTAssertEqual(LlamaServerCapabilities.cached(binary: nil), .assumedModern)
    }

    /// The memo key has to notice a binary being replaced and ignore a rebuild of
    /// this app. Path plus size plus modification date does both; path alone would
    /// serve a stale answer forever.
    func testTheCacheKeyFollowsTheFileNotJustItsPath() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("llama-server")
        try Data(repeating: 0x41, count: 10).write(to: file)
        let first = LlamaServerCapabilities.cacheKey(for: file)

        try Data(repeating: 0x42, count: 20).write(to: file)
        let second = LlamaServerCapabilities.cacheKey(for: file)

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasPrefix(file.path), first)
    }

    func testTheCacheIsStableForAnUnchangedFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe-stable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("llama-server")
        try Data(repeating: 0x41, count: 10).write(to: file)

        XCTAssertEqual(
            LlamaServerCapabilities.cacheKey(for: file),
            LlamaServerCapabilities.cacheKey(for: file)
        )
    }
}
