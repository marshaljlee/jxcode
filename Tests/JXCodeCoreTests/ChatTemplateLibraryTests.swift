import XCTest
@testable import JXCodeCore

final class ChatTemplateLibraryTests: XCTestCase {

    // MARK: - The name list

    func testBuiltInPresetNamesAreSortedAndUnique() {
        let names = ChatTemplateLibrary.builtInPresetNames
        XCTAssertEqual(names, names.sorted())
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertFalse(names.isEmpty)
        XCTAssertTrue(names.allSatisfy { !$0.isEmpty })
    }

    func testKnownNamesArePresent() {
        // A spot check that the list is llama-server's, not an approximation.
        for name in ["chatml", "llama3", "llama2-sys-strip", "mistral-v7-tekken",
                     "seed_oss", "gpt-oss", "granite-4.1", "pangu-embedded", "zephyr"] {
            XCTAssertTrue(
                ChatTemplateLibrary.builtInPresetNames.contains(name),
                "\(name) is missing from the built-in list"
            )
        }
    }

    // MARK: - resolve: embedded template wins

    func testEmbeddedTemplateIsPreferredOverAPreset() {
        let resolution = ChatTemplateLibrary.resolve(
            architecture: "qwen2",
            embeddedTemplate: "{% for message in messages %}{{ message['role'] }}{% endfor %}"
        )

        XCTAssertEqual(resolution.source, .embedded)
        XCTAssertTrue(resolution.isResolved)
        XCTAssertEqual(resolution.arguments.count, 1)
        XCTAssertEqual(resolution.arguments[0].flag, "--jinja")
        XCTAssertNil(resolution.arguments[0].value)
        XCTAssertEqual(resolution.arguments[0].category, .template)
        XCTAssertFalse(
            resolution.arguments.contains { $0.flag == "--chat-template" },
            "a preset must not be emitted alongside the model's own template"
        )
    }

    func testEmbeddedTemplateIsPreferredEvenWhenNoPresetExists() {
        let resolution = ChatTemplateLibrary.resolve(
            architecture: "qwen3vl",
            embeddedTemplate: "<|im_start|>{{ role }}"
        )
        XCTAssertEqual(resolution.source, .embedded)
        XCTAssertTrue(resolution.isResolved)
    }

    func testWhitespaceOnlyEmbeddedTemplateCountsAsAbsent() {
        let resolution = ChatTemplateLibrary.resolve(
            architecture: "gemma3",
            embeddedTemplate: "   \n\t "
        )
        XCTAssertEqual(resolution.source, .builtInPreset("gemma"))
    }

    func testEmbeddedNoteIsNotTheFailureNote() {
        let resolution = ChatTemplateLibrary.resolve(architecture: "llama", embeddedTemplate: "x")
        XCTAssertFalse(resolution.note.isEmpty)
        XCTAssertFalse(resolution.note.contains("may not work"))
    }

    // MARK: - resolve: preset fallback

    func testFallsBackToAPresetWhenThereIsNoEmbeddedTemplate() {
        let resolution = ChatTemplateLibrary.resolve(architecture: "qwen3", embeddedTemplate: nil)

        XCTAssertEqual(resolution.source, .builtInPreset("chatml"))
        XCTAssertTrue(resolution.isResolved)
        XCTAssertEqual(resolution.arguments.count, 1)
        XCTAssertEqual(resolution.arguments[0].flag, "--chat-template")
        XCTAssertEqual(resolution.arguments[0].value, "chatml")
        XCTAssertEqual(resolution.arguments[0].category, .template)
        XCTAssertTrue(resolution.note.contains("chatml"), resolution.note)
    }

    func testEmptyStringEmbeddedTemplateFallsBackToAPreset() {
        let resolution = ChatTemplateLibrary.resolve(architecture: "mistral", embeddedTemplate: "")
        XCTAssertEqual(resolution.source, .builtInPreset("mistral-v3"))
    }

    func testPresetNoteNamesTheArchitecture() {
        let resolution = ChatTemplateLibrary.resolve(architecture: "  PHI3 ", embeddedTemplate: nil)
        XCTAssertEqual(resolution.source, .builtInPreset("phi3"))
        XCTAssertTrue(resolution.note.contains("phi3"), resolution.note)
        XCTAssertTrue(resolution.note.contains("tool calling"), resolution.note)
    }

    func testPresetNoteExplainsWhyThePresetWasChosen() {
        let resolution = ChatTemplateLibrary.resolve(architecture: "qwen2", embeddedTemplate: nil)
        XCTAssertTrue(resolution.note.contains("trained on that format"), resolution.note)
    }

    // MARK: - resolve: nothing suitable

    func testUnknownArchitectureIsUnresolved() {
        let resolution = ChatTemplateLibrary.resolve(
            architecture: "some-new-architecture",
            embeddedTemplate: nil
        )

        XCTAssertEqual(resolution.source, .none)
        XCTAssertFalse(resolution.isResolved)
        XCTAssertTrue(resolution.arguments.isEmpty)
        XCTAssertTrue(resolution.note.contains("--chat-template"), resolution.note)
    }

    func testMissingArchitectureIsUnresolved() {
        let resolution = ChatTemplateLibrary.resolve(architecture: nil, embeddedTemplate: nil)
        XCTAssertEqual(resolution.source, .none)
        XCTAssertFalse(resolution.isResolved)
        XCTAssertTrue(resolution.arguments.isEmpty)
    }

    func testUnresolvedNoteWarnsAboutToolCalling() {
        let resolution = ChatTemplateLibrary.resolve(architecture: "unknown", embeddedTemplate: nil)
        XCTAssertTrue(resolution.note.contains("Tool calling"), resolution.note)
    }

    func testAmbiguousLlamaWithoutVocabularySizeIsUnresolved() {
        let resolution = ChatTemplateLibrary.resolve(
            architecture: "llama",
            embeddedTemplate: nil,
            vocabularySize: nil
        )
        XCTAssertEqual(resolution.source, .none)
        XCTAssertFalse(resolution.isResolved)
    }

    // MARK: - presetName: the mapping table

    private static let expectedMappings: [(String, String)] = [
        ("qwen2", "chatml"),
        ("qwen3", "chatml"),
        ("qwen2moe", "chatml"),
        ("qwen3moe", "chatml"),
        ("qwen35", "chatml"),
        ("qwen3vl", "chatml"),
        ("yi", "chatml"),
        ("internlm2", "chatml"),
        ("smollm", "chatml"),
        ("gemma", "gemma"),
        ("gemma2", "gemma"),
        ("gemma3", "gemma"),
        ("phi3", "phi3"),
        ("phi4", "phi4"),
        ("deepseek", "deepseek"),
        ("deepseek2", "deepseek2"),
        ("deepseek3", "deepseek3"),
        ("mistral", "mistral-v3"),
        ("command-r", "command-r"),
        ("commandr", "command-r"),
        ("gpt-oss", "gpt-oss"),
        ("granite", "granite"),
        ("minicpm", "minicpm"),
        ("glm4", "chatglm4"),
        ("chatglm", "chatglm4"),
        ("smolvlm", "smolvlm"),
        ("hunyuan-moe", "hunyuan-moe"),
        ("kimi-k2", "kimi-k2"),
    ]

    func testKnownArchitecturesMapToTheirPreset() {
        for (architecture, preset) in Self.expectedMappings {
            XCTAssertEqual(
                ChatTemplateLibrary.presetName(for: architecture),
                preset,
                "\(architecture) should map to \(preset)"
            )
        }
    }

    func testUnknownArchitecturesReturnNil() {
        // Every one of these is either a model family with no built-in
        // template, or one where two families share an architecture string.
        for architecture in ["clip", "bert", "t5", "mamba", "rwkv", "olmo",
                             "exaone", "granite-4.0", "hunyuan-dense", "hunyuan-vl",
                             "llama4", "grok-2", "monarch", "orion", "", "   "] {
            XCTAssertNil(
                ChatTemplateLibrary.presetName(for: architecture),
                "\(architecture) should not be guessed at"
            )
        }
    }

    func testCaseInsensitivityAndWhitespaceTolerance() {
        XCTAssertEqual(ChatTemplateLibrary.presetName(for: "QWEN3"), "chatml")
        XCTAssertEqual(ChatTemplateLibrary.presetName(for: "Qwen3"), "chatml")
        XCTAssertEqual(ChatTemplateLibrary.presetName(for: "  qwen3  "), "chatml")
        XCTAssertEqual(ChatTemplateLibrary.presetName(for: "\nGemma3\t"), "gemma")
        XCTAssertEqual(ChatTemplateLibrary.presetName(for: "DEEPSEEK2"), "deepseek2")
        XCTAssertEqual(ChatTemplateLibrary.presetName(for: " Mistral "), "mistral-v3")
    }

    func testWhitespaceToleranceSurvivesTheWholeResolution() {
        let resolution = ChatTemplateLibrary.resolve(architecture: "  QWEN3 ", embeddedTemplate: nil)
        XCTAssertEqual(resolution.source, .builtInPreset("chatml"))
    }

    // MARK: - presetName: the ambiguous llama family

    func testLlamaIsDiscriminatedByVocabularySize() {
        // Llama 2 and Llama 3 both report architecture "llama" and need
        // different templates, so the tokenizer size is the only signal.
        //
        // Note that this test alone proves very little: 128_256 and 32_000 are
        // the two values an exact-match implementation would hardcode, so it
        // passes whether the rule is exact or banded. The test below is the one
        // that distinguishes them.
        XCTAssertEqual(
            ChatTemplateLibrary.presetName(for: "llama", vocabularySize: 128_256),
            "llama3"
        )
        XCTAssertEqual(
            ChatTemplateLibrary.presetName(for: "llama", vocabularySize: 32_000),
            "llama2"
        )
    }

    func testTheLlamaDiscriminatorUsesBandsNotExactSizes() {
        // Written after mutation testing: reverting the bands to exact equality
        // (128_256 / 32_000) left the whole suite green, because every value
        // the tests used was one of those two constants. The rule was untested.
        //
        // Exact equality is right for a stock tokenizer and wrong for every
        // fine-tune that adds tokens to one. `MiniCPM5-2B` on this machine
        // reports **130_560** — a Llama 3 tokenizer plus added tokens — which
        // matched neither constant and silently loaded with no template at all.
        // A *wrong* template corrupts every prompt; a missing one is merely
        // unconfigured, which is why the middle band declines rather than
        // guessing.
        let expectations: [(size: Int, preset: String?)] = [
            (130_560, "llama3"),   // the real fine-tune that motivated the bands
            (100_000, "llama3"),   // floor of the llama3 band
            (99_999, nil),         // one below it, deliberately not guessed
            (128_256, "llama3"),
            (40_000, "llama2"),    // ceiling of the llama2 band
            (40_001, nil),         // one above it
            (32_000, "llama2"),
            (50_257, nil),         // the ambiguous middle
        ]

        for (size, preset) in expectations {
            XCTAssertEqual(
                ChatTemplateLibrary.presetName(for: "llama", vocabularySize: size),
                preset,
                "vocab \(size)"
            )
        }
    }

    func testLlamaWithNoVocabularySizeIsNotGuessed() {
        XCTAssertNil(ChatTemplateLibrary.presetName(for: "llama"))
        XCTAssertNil(ChatTemplateLibrary.presetName(for: "llama", vocabularySize: nil))
    }

    func testLlamaWithAnUnrecognisedVocabularySizeIsNotGuessed() {
        XCTAssertNil(ChatTemplateLibrary.presetName(for: "llama", vocabularySize: 50_257))
        XCTAssertNil(ChatTemplateLibrary.presetName(for: "llama", vocabularySize: 0))
    }

    func testVocabularySizeDoesNotDisturbOtherArchitectures() {
        XCTAssertEqual(
            ChatTemplateLibrary.presetName(for: "qwen2", vocabularySize: 32_000),
            "chatml"
        )
    }

    // MARK: - Every emitted name must exist

    func testEveryPresetNameIsARealBuiltInTemplate() {
        // The important test. A typo here produces `--chat-template chatm1`,
        // which llama-server rejects at startup — or, worse, a name that is
        // accepted by a later build as something else entirely. Any architecture
        // this function will answer for has to come back with a name from the
        // list llama.cpp actually ships.
        var architectures = Self.expectedMappings.map(\.0)
        architectures += [
            "llama", "Llama", "  llama  ", "unknown-arch", "clip", "",
            "qwen3vl", "gemma3", "phi4", "deepseek3", "gpt-oss", "kimi-k2",
            "hunyuan-moe", "smolvlm", "chatglm", "minicpm", "granite",
            "commandr", "mistral", "internlm2", "smollm", "yi", "qwen35",
        ]

        let vocabularies: [Int?] = [nil, 32_000, 128_256, 50_257]

        var resolvedCount = 0
        for architecture in architectures {
            for vocabularySize in vocabularies {
                guard let preset = ChatTemplateLibrary.presetName(
                    for: architecture,
                    vocabularySize: vocabularySize
                ) else { continue }
                resolvedCount += 1
                XCTAssertTrue(
                    ChatTemplateLibrary.builtInPresetNames.contains(preset),
                    "\(architecture) (vocab \(vocabularySize.map(String.init) ?? "nil")) "
                        + "produced '\(preset)', which is not a built-in template name"
                )
            }
        }
        XCTAssertGreaterThan(resolvedCount, 0, "the sweep resolved nothing, so it proves nothing")
    }

    func testResolutionNeverEmitsAnUnknownPresetName() {
        for architecture in Self.expectedMappings.map(\.0) + ["llama", "nonsense"] {
            let resolution = ChatTemplateLibrary.resolve(
                architecture: architecture,
                embeddedTemplate: nil,
                vocabularySize: 128_256
            )
            for argument in resolution.arguments {
                XCTAssertEqual(argument.flag, "--chat-template")
                guard let name = argument.value else {
                    XCTFail("\(architecture) emitted --chat-template with no value")
                    continue
                }
                XCTAssertTrue(
                    ChatTemplateLibrary.builtInPresetNames.contains(name),
                    "\(architecture) emitted '\(name)', which is not a built-in template"
                )
            }
        }
    }
}

// MARK: - Tool-calling detection

/// Preferring the model's own template is right in general and wrong in one
/// specific case: a model whose author never wrote tool handling into it. The
/// templates below are real — the first two are copied from models on this
/// machine, and the first is the one that exposed the gap.
final class ChatTemplateToolCallingTests: XCTestCase {

    /// A real 410-character template from a 1.1B model. Plain role tags, no
    /// tool handling, and nothing about the file looks broken.
    private let roleTagsOnly = """
    {% for message in messages %}
    {% if message['role'] == 'user' %}
    {{ '<|user|>
    ' + message['content'] + eos_token }}
    {% elif message['role'] == 'system' %}
    {{ '<|system|>
    ' + message['content'] + eos_token }}
    {% elif message['role'] == 'assistant' %}
    {{ '<|assistant|>
    '  + message['content'] + eos_token }}
    {% endif %}
    {% if loop.last and add_generation_prompt %}
    {{ '<|assistant|>' }}
    {% endif %}
    {% endfor %}
    """

    /// A real template that handles tools in *both* halves: it reads the
    /// `tools` variable, and it renders `tool_calls`. Either alone is not
    /// enough — the first puts the definitions in front of the model, the
    /// second is how a call comes back out.
    private let withTools = """
    {{- bos_token }}{%- if tools %}
    {%- set tool_definitions %}
    {{- "# Tools\n\nYou are provided with function signatures within <tools></tools> XML tags:" }}
    {%- for tool in tools %}
    {{- "\n<tool>" + tool['function']['name'] + "</tool>" }}
    {%- endfor %}
    {%- endif %}
    {%- for message in messages %}
    {%- if message['role'] == 'assistant' and message['tool_calls'] %}
    {{- '<｜tool╱calls╱begin｜>' }}
    {%- for tool_call in message['tool_calls'] %}
    {{- tool_call['function']['name'] + tool_call['function']['arguments'] }}
    {%- endfor %}
    {%- endif %}
    {%- endfor %}
    """

    /// The template that exposed the bug, in the shape it actually has: 2,937
    /// characters from a DeepSeek R1 fine-tune that render
    /// `message['tool_calls']` in full and never mention `tools`. llama.cpp
    /// reports `supports_tool_calls=true, supports_tools=false`, and an agent
    /// asking for a tool gets prose, because the model was never told the tool
    /// existed.
    private let rendersCallsWithoutTools = """
    {%- for message in messages %}
    {%- if message['role'] == 'assistant' and message['tool_calls'] is defined %}
    {%- for tool in message['tool_calls'] %}
    {{ '<｜tool╱calls╱begin｜><｜tool╱call╱begin｜>' + tool['type'] + '<｜tool╱sep｜>'
       + tool['function']['name'] + ' ' + '```json' + tool['function']['arguments'] + '```'
       + '<｜tool╱call╱end｜>' }}
    {%- endfor %}
    {%- endif %}
    {%- endfor %}
    """

    private func resolution(_ template: String?) -> ChatTemplateLibrary.Resolution {
        ChatTemplateLibrary.resolve(
            architecture: "llama",
            embeddedTemplate: template,
            vocabularySize: 32_000
        )
    }

    func testATemplateWithoutToolHandlingIsReported() {
        // The case that matters: the template resolves, llama.cpp accepts it,
        // and the model answers in prose when an agent asks for a tool.
        let result = resolution(roleTagsOnly)

        XCTAssertEqual(result.source, .embedded)
        XCTAssertTrue(result.isResolved, "the template did resolve — that is the problem")
        XCTAssertEqual(result.toolCalling, .unsupported)
        XCTAssertNotNil(result.warning)
    }

    func testTheWarningExplainsItIsTheModelNotTheApp() {
        // A user who reads "tool calling is broken" and cannot tell whose fault
        // it is will go looking in the wrong place.
        let warning = try? XCTUnwrap(resolution(roleTagsOnly).warning)

        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("model file"), "the warning should say where the cause is")
        XCTAssertTrue(warning!.contains("--chat-template"), "and what can be done about it")
    }

    func testATemplateWithToolHandlingIsReportedAsSupported() {
        let result = resolution(withTools)

        XCTAssertEqual(result.toolCalling, .supported)
        XCTAssertNil(result.warning, "a working template must not produce a warning")
    }

    func testTheEmitHalfAloneIsNotToolCalling() {
        // Templates vary in which of llama.cpp's fields they read, and every
        // one of these is enough to render a call the template is *handed*.
        // None of them gets the tool definitions into the prompt, which is the
        // half a model needs before it can decide to call anything.
        for marker in ["tool_calls", "tool_call_id", "tool_result", "function"] {
            let template = "{% if \(marker) %}...{% endif %}"
            XCTAssertEqual(
                resolution(template).toolCalling, .unsupported,
                "a template referencing only '\(marker)' cannot receive tools"
            )
        }
    }

    func testBothHalvesTogetherAreRecognised() {
        for marker in ["tool_calls", "tool_call_id", "tool_result"] {
            let template = "{%- if tools %}{% for t in tools %}{{ t.name }}{% endfor %}{% endif %}"
                + "{% if \(marker) %}...{% endif %}"
            XCTAssertEqual(
                resolution(template).toolCalling, .supported,
                "a template reading 'tools' and '\(marker)' should count as handling tools"
            )
        }
    }

    /// The trap, in the shape a real file has. Reported as working by the old
    /// search, because it renders `tool_calls` and speaks of `function` — and
    /// it cannot call a tool at all.
    func testATemplateThatRendersCallsButNeverReceivesThemIsNotToolCalling() {
        let result = resolution(rendersCallsWithoutTools)

        XCTAssertTrue(result.isResolved, "it resolves, which is what makes it dangerous")
        XCTAssertEqual(result.toolCalling, .unsupported)
        XCTAssertNotNil(result.warning, "the user should be told, not left to find out")
    }

    func testABuiltInPresetIsNotClaimedEitherWay() {
        // The preset's body lives in llama.cpp, not here, so any claim would be
        // a guess. Several presets support tools and several do not.
        let result = ChatTemplateLibrary.resolve(
            architecture: "qwen3",
            embeddedTemplate: nil,
            vocabularySize: nil
        )

        XCTAssertEqual(result.toolCalling, .unknown)
        XCTAssertNil(result.warning)
    }

    func testAnUnresolvedTemplateMakesNoSecondClaim() {
        // `.none` already warns that tool calling may not work; a second
        // warning saying the same thing is noise.
        let result = ChatTemplateLibrary.resolve(
            architecture: "nonsense",
            embeddedTemplate: nil,
            vocabularySize: nil
        )

        XCTAssertFalse(result.isResolved)
        XCTAssertEqual(result.toolCalling, .unknown)
        XCTAssertNil(result.warning)
    }

    func testBothHalvesAreRequired() {
        // The bias used to run the other way — towards `supported` — on the
        // reasoning that a false "unsupported" warns about a model that works,
        // while the runtime check against /props catches the opposite. It does
        // not catch it soon enough to help: the plan is what decides whether
        // the user is warned at all, and by the time /props is read the agent
        // is already sending tools to a model that cannot see them.
        XCTAssertEqual(resolution("{% if tools %}{{ tool_calls }}{% endif %}").toolCalling, .supported)
        // Reads the definitions but never emits a call.
        XCTAssertEqual(resolution("{% if tools %}x{% endif %}").toolCalling, .unsupported)
        XCTAssertEqual(resolution("Tools available: {{ tools }}").toolCalling, .unsupported)
        // Emits a call but never reads the definitions.
        XCTAssertEqual(resolution("{% if tool_calls %}x{% endif %}").toolCalling, .unsupported)
        // Prose about functions is not a call. This is the opening of a real
        // tool template with the emitting half removed — the word "function"
        // appears in ordinary English there, which is why it is not evidence.
        XCTAssertEqual(
            resolution("{%- if tools %}You are provided with function signatures.{%- endif %}").toolCalling,
            .unsupported
        )
        // A template that merely uses the word inside a sentence about
        // something else is a judgement call, and either answer is defensible.
        XCTAssertEqual(resolution("no tooling here").toolCalling, .unsupported)
    }
}
