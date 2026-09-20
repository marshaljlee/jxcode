import XCTest
@testable import JXCodeCore

/// The fixture is a real `/props` body captured from llama-server build
/// 10150 serving a 2B GGUF. Inventing one would have missed the two things
/// that actually matter: that `n_ctx` lives under `default_generation_settings`
/// rather than at the root, and that a working Jinja template still reports
/// `chat_format: "Content-only"` — a label that reads like a fallback and is
/// not one.
final class ServerPropsTests: XCTestCase {

    private let realProps = """
    {
      "bos_token": "<s>",
      "build_info": "b10150-dee2a846b",
      "chat_template": "{{- bos_token }}{%- if tools %}...",
      "chat_template_caps": {
        "supports_object_arguments": true,
        "supports_parallel_tool_calls": true,
        "supports_preserve_reasoning": true,
        "supports_string_content": true,
        "supports_system_role": true,
        "supports_tool_calls": true,
        "supports_tools": true,
        "supports_typed_content": false
      },
      "cors_proxy_enabled": false,
      "default_generation_settings": {
        "n_ctx": 2048,
        "params": {
          "chat_format": "Content-only",
          "reasoning_format": "none",
          "temperature": 1.0,
          "top_k": 40,
          "samplers": ["penalties","dry","top_n_sigma","top_k","typ_p","top_p","min_p","xtc","temperature"]
        }
      },
      "endpoint_metrics": false,
      "endpoint_props": false,
      "endpoint_slots": true,
      "eos_token": "</s>",
      "is_sleeping": false,
      "media_marker": "<__media_test__>",
      "modalities": { "audio": false, "video": false, "vision": false },
      "model_alias": "/Users/test/Models/MiniCPM5-2B.gguf",
      "model_ftype": "Q8_0",
      "model_path": "/Users/test/Models/MiniCPM5-2B.gguf",
      "total_slots": 1
    }
    """

    private func decode(_ json: String) -> ServerProps? {
        guard let data = json.data(using: .utf8) else { return nil }
        return ServerProps(data: data)
    }

    private func real() throws -> ServerProps {
        try XCTUnwrap(decode(realProps), "the captured payload should decode")
    }

    // MARK: Decoding

    func testDecodesTheRealPayload() throws {
        let props = try real()

        XCTAssertEqual(props.buildInfo, "b10150-dee2a846b")
        XCTAssertEqual(props.modelQuantization, "Q8_0")
        XCTAssertEqual(props.totalSlots, 1)
        XCTAssertTrue(props.hasChatTemplate)
        XCTAssertFalse(props.isSleeping)
    }

    func testContextIsReadFromDefaultGenerationSettingsNotTheRoot() throws {
        // `n_ctx` is nested. Looking for it at the root yields nil, which reads
        // as "the server did not say" rather than "we looked in the wrong
        // place" — so it is worth pinning.
        let props = try real()

        XCTAssertEqual(props.contextLength, 2048)
    }

    /// One slot means the whole window belongs to the agent.
    func testAgentContextEqualsTheFullContextWithOneSlot() throws {
        let props = try real()

        XCTAssertEqual(props.contextLength, 2048)
        XCTAssertEqual(props.totalSlots, 1)
        XCTAssertEqual(props.agentContextLength, 2048)
    }

    /// `n_ctx` is a total across slots, so extra slots divide it.
    ///
    /// This is the number that gets written into Claude Code's config. Getting
    /// it wrong in the optimistic direction is what killed a real run: the
    /// agent was told 114k, asked for it, and the model died in a Metal
    /// allocation failure rather than refusing the request.
    func testAgentContextIsDividedAcrossSlots() {
        let props = ServerProps(contextLength: 131_072, totalSlots: 4)
        XCTAssertEqual(props.agentContextLength, 32_768)

        let single = ServerProps(contextLength: 131_072, totalSlots: 1)
        XCTAssertEqual(single.agentContextLength, 131_072)
    }

    /// A server that says nothing about its window must not be guessed at.
    func testAgentContextIsNilWhenTheServerReportsNone() {
        XCTAssertNil(ServerProps().agentContextLength)
        XCTAssertNil(ServerProps(totalSlots: 2).agentContextLength)
    }

    func testCapabilitiesAreDecoded() throws {
        let caps = try XCTUnwrap(try real().capabilities)

        XCTAssertEqual(caps.supportsTools, true)
        XCTAssertEqual(caps.supportsToolCalls, true)
        XCTAssertEqual(caps.supportsParallelToolCalls, true)
        XCTAssertEqual(caps.supportsSystemRole, true)
        XCTAssertEqual(caps.supportsTypedContent, false)
        XCTAssertEqual(caps.toolCallingIsUsable, true)
    }

    func testModalitiesAreDecoded() throws {
        let modalities = try XCTUnwrap(try real().modalities)

        XCTAssertFalse(modalities.vision)
        XCTAssertFalse(modalities.isMultimodal)
    }

    func testNonObjectJSONDoesNotDecode() {
        // A router that proxied an HTML error page must not be mistaken for a
        // server reporting no features.
        XCTAssertNil(decode("<html>502 Bad Gateway</html>"))
        XCTAssertNil(decode("[1,2,3]"))
        XCTAssertNil(decode("not json at all"))
    }

    // MARK: The "Content-only" trap

    func testContentOnlyChatFormatIsNotTreatedAsAFailure() throws {
        // This is the whole reason the type documents the field. A model using
        // its own Jinja template reports `Content-only`, tool calling works
        // correctly, and a naive check on this string would produce a false
        // alarm on every well-configured model.
        let props = try real()

        XCTAssertEqual(props.chatFormat, "Content-only")
        XCTAssertEqual(props.disagreements(), [], "a working template must not be reported as broken")
    }

    // MARK: Disagreements

    func testMissingToolCallingIsReported() throws {
        let broken = """
        {
          "chat_template": "{{ .Prompt }}",
          "chat_template_caps": {
            "supports_tools": false,
            "supports_tool_calls": false
          },
          "default_generation_settings": { "n_ctx": 4096 }
        }
        """
        let props = try XCTUnwrap(decode(broken))

        let problems = props.disagreements()

        XCTAssertEqual(problems.count, 1)
        // `first` + `XCTUnwrap`, never `problems[0]`. Subscripting an empty
        // array is a fatal error, and a fatal error takes the whole test
        // binary with it: every other result in the run is discarded and the
        // output reads as a build failure rather than a failed assertion.
        // Observed while mutation-testing `toolCallingIsUsable` — the count
        // assertion failed, the next line crashed, and the run was reported as
        // a compile error.
        let problem = try XCTUnwrap(problems.first)
        XCTAssertTrue(problem.contains("does not support tool calling"))
        // The message has to say what to do about it, not just that it is wrong.
        XCTAssertTrue(problem.contains("--chat-template"))
    }

    func testAbsentCapabilitiesAreUnknownRatherThanUnsupported() throws {
        // An older build that reports no capability block has told us nothing.
        // Treating that as "no tool calling" would cry wolf on a working setup.
        let noCaps = """
        {
          "chat_template": "{{ .Prompt }}",
          "default_generation_settings": { "n_ctx": 4096 }
        }
        """
        let props = try XCTUnwrap(decode(noCaps))

        XCTAssertNil(props.capabilities)
        XCTAssertEqual(props.disagreements(), [])
    }

    func testAProjectorThatDidNotLoadIsReported() throws {
        // The plan passed --mmproj but the server says there is no vision.
        // Without this check the user finds out when the model cannot see.
        let problems = try real().disagreements(expectedVision: true)

        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(try XCTUnwrap(problems.first).contains("no vision modality"))
    }

    func testVisionAppearingUnaskedIsReported() throws {
        let visionProps = """
        {
          "chat_template": "t",
          "default_generation_settings": { "n_ctx": 4096 },
          "modalities": { "vision": true, "video": false, "audio": false }
        }
        """
        let props = try XCTUnwrap(decode(visionProps))

        let problems = props.disagreements(expectedVision: false)

        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(try XCTUnwrap(problems.first).contains("found one on its own"))
    }

    func testMatchingVisionProducesNoComplaint() throws {
        let visionProps = """
        {
          "chat_template": "t",
          "chat_template_caps": { "supports_tools": true, "supports_tool_calls": true },
          "default_generation_settings": { "n_ctx": 4096 },
          "modalities": { "vision": true, "video": false, "audio": false }
        }
        """
        let props = try XCTUnwrap(decode(visionProps))

        XCTAssertEqual(props.disagreements(expectedVision: true), [])
    }

    func testContextShortfallIsReported() throws {
        let problems = try real().disagreements(requestedContext: 32_768)

        XCTAssertEqual(problems.count, 1)
        let problem = try XCTUnwrap(problems.first)
        XCTAssertTrue(problem.contains("32768"))
        XCTAssertTrue(problem.contains("2048"))
    }

    func testMatchingContextProducesNoComplaint() throws {
        XCTAssertEqual(try real().disagreements(requestedContext: 2048), [])
    }

    func testExtraSlotsAreReportedBecauseTheyDivideTheContext() throws {
        // `-c` is the total across slots, so a server that opened four slots
        // gives each agent a quarter of the window. This is the failure
        // `--parallel 1` exists to prevent, so a mismatch is worth surfacing.
        let fourSlots = """
        {
          "chat_template": "t",
          "chat_template_caps": { "supports_tools": true, "supports_tool_calls": true },
          "default_generation_settings": { "n_ctx": 8192 },
          "total_slots": 4
        }
        """
        let props = try XCTUnwrap(decode(fourSlots))

        let problems = props.disagreements(expectedSlots: 1)

        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(try XCTUnwrap(problems.first).contains("fraction of the context"))
    }

    func testMatchingSlotsProduceNoComplaint() throws {
        XCTAssertEqual(try real().disagreements(expectedSlots: 1), [])
    }

    func testEveryDisagreementCanFireAtOnce() throws {
        // A check that can only ever report one problem is easy to get wrong,
        // so exercise the full set.
        let bad = """
        {
          "chat_template_caps": { "supports_tools": false, "supports_tool_calls": false },
          "default_generation_settings": { "n_ctx": 2048 },
          "modalities": { "vision": false, "video": false, "audio": false },
          "total_slots": 4
        }
        """
        let props = try XCTUnwrap(decode(bad))

        let problems = props.disagreements(
            expectedVision: true,
            requestedContext: 32_768,
            expectedSlots: 1
        )

        XCTAssertEqual(problems.count, 4, "expected tool-calling, vision, context and slot complaints")
    }

    // MARK: Display

    func testSummaryDescribesTheLoadedModel() throws {
        let summary = try real().summary

        XCTAssertTrue(summary.contains("2k context"))
        XCTAssertTrue(summary.contains("Q8_0"))
        XCTAssertTrue(summary.contains("tool calling"))
        // One slot is the correct configuration, so it is not worth reporting.
        XCTAssertFalse(summary.contains("slot"))
    }

    func testSummaryFlagsNoToolCalling() throws {
        let broken = """
        {
          "chat_template_caps": { "supports_tools": false, "supports_tool_calls": false },
          "default_generation_settings": { "n_ctx": 4096 }
        }
        """
        let props = try XCTUnwrap(decode(broken))

        XCTAssertTrue(props.summary.contains("no tool calling"))
    }

    func testCapabilityListOnlyNamesWhatIsSupported() throws {
        let supported = try XCTUnwrap(try real().capabilities).supported

        XCTAssertTrue(supported.contains("tools"))
        XCTAssertTrue(supported.contains("parallel tool calls"))
        // supports_typed_content is false in the fixture, so it must not appear.
        XCTAssertFalse(supported.contains("typed content"))
    }
}

// MARK: - The Llama vocabulary discriminator

/// `llama` covers both Llama 2 and Llama 3, and their templates differ in
/// whether a system role exists at all — so the discriminator has to be right.
final class LlamaVocabularyDiscriminationTests: XCTestCase {

    private func preset(vocab: Int?) -> String? {
        ChatTemplateLibrary.presetName(for: "llama", vocabularySize: vocab)
    }

    func testLlama3VocabulariesMapToLlama3() {
        XCTAssertEqual(preset(vocab: 128_256), "llama3")
    }

    func testLlama2VocabularyMapsToLlama2() {
        XCTAssertEqual(preset(vocab: 32_000), "llama2")
    }

    func testAnExtendedLlama3VocabularyStillMapsToLlama3() {
        // The case that motivated the threshold. A real model on this machine
        // reports architecture `llama` with 130560 entries — a Llama 3 tokenizer
        // with tokens added. An exact-equality check returned nil for it, which
        // silently drops the template and breaks tool calling.
        XCTAssertEqual(preset(vocab: 130_560), "llama3")
    }

    func testTheBandsSitWellClearOfBothFamilies() {
        // The families are separated by a factor of four, so the exact edges are
        // not delicate — but both real cases must clear their band by a wide
        // margin, and the genuinely ambiguous middle must stay unanswered.
        XCTAssertEqual(preset(vocab: 100_000), "llama3")
        XCTAssertEqual(preset(vocab: 99_999), nil, "just below the Llama 3 band is not a guess")
        XCTAssertEqual(preset(vocab: 40_000), "llama2")
        XCTAssertEqual(preset(vocab: 40_001), nil, "just above the Llama 2 band is not a guess")
        XCTAssertEqual(preset(vocab: 200_000), "llama3")
    }

    func testAVocabularyBetweenTheFamiliesIsNotGuessed() {
        // GPT-2's 50257 is neither family, and a wrong template corrupts every
        // prompt silently rather than failing loudly.
        XCTAssertNil(preset(vocab: 50_257))
        XCTAssertNil(preset(vocab: 0))
    }

    func testNoVocabularySizeMeansNoAnswer() {
        // Guessing here is worse than declining: the wrong template breaks
        // instruction following rather than merely degrading it.
        XCTAssertNil(preset(vocab: nil))
    }

    func testUnambiguousArchitecturesIgnoreTheVocabularySize() {
        XCTAssertEqual(ChatTemplateLibrary.presetName(for: "qwen3", vocabularySize: nil), "chatml")
        XCTAssertEqual(ChatTemplateLibrary.presetName(for: "gemma3", vocabularySize: nil), "gemma")
    }
}
