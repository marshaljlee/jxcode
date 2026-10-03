import XCTest
@testable import JXCodeCore

final class SamplingPresetTests: XCTestCase {

    // MARK: - Default

    func testDefaultPresetIsAgent() {
        // The whole design argument for this module. A model served by this app
        // is a component of a coding agent, so it must not sample creatively
        // unless a person asked for it.
        XCTAssertEqual(SamplingPreset.default, .agent)
    }

    func testEveryCaseIsOfferedOnce() {
        XCTAssertEqual(
            SamplingPreset.allCases,
            [.modelDefault, .agent, .balanced, .creative]
        )
    }

    // MARK: - Exact argument lists

    func testModelDefaultEmitsNothing() {
        XCTAssertTrue(SamplingPreset.modelDefault.arguments.isEmpty)
        XCTAssertNil(SamplingPreset.modelDefault.temperature)
    }

    func testAgentArgumentsExact() {
        let preset = SamplingPreset.agent
        XCTAssertEqual(
            preset.arguments.map(\.rendered),
            ["--temp 0", "--top-p 1", "--top-k 1", "--repeat-penalty 1"]
        )
        XCTAssertEqual(preset.temperature, 0.0)
        XCTAssertEqual(
            preset.arguments.map(\.flag),
            ["--temp", "--top-p", "--top-k", "--repeat-penalty"]
        )
    }

    func testBalancedArgumentsExact() {
        let preset = SamplingPreset.balanced
        XCTAssertEqual(
            preset.arguments.map(\.rendered),
            ["--temp 0.7", "--min-p 0.05", "--top-k 40", "--top-p 0.95", "--repeat-penalty 1.1"]
        )
        XCTAssertEqual(preset.temperature, 0.7)
    }

    func testCreativeArgumentsExact() {
        let preset = SamplingPreset.creative
        XCTAssertEqual(
            preset.arguments.map(\.rendered),
            [
                "--temp 1",
                "--min-p 0.05",
                "--top-k 0",
                "--top-p 1",
                "--dry-multiplier 0.8",
                "--dry-base 1.75",
                "--xtc-probability 0.5",
                "--xtc-threshold 0.1",
                "--repeat-penalty 1",
            ]
        )
        XCTAssertEqual(preset.temperature, 1.0)
    }

    func testCreativeLeavesRepeatPenaltyOff() {
        // Creative uses DRY for repetition control. Both at once over-penalises
        // and the prose goes stilted, so repeat-penalty must stay at 1.0.
        let penalty = SamplingPreset.creative.arguments.first { $0.flag == "--repeat-penalty" }
        XCTAssertEqual(penalty?.value, "1")
        XCTAssertTrue(SamplingPreset.creative.arguments.contains { $0.flag == "--dry-multiplier" })
    }

    func testArgumentsAreFullyFormed() {
        // Every flag must render as a flag plus a value, carry a reason for the
        // UI to show, and be categorised. A nil value here would produce a
        // bare --temp on the command line.
        for preset in SamplingPreset.allCases {
            for argument in preset.arguments {
                XCTAssertTrue(argument.flag.hasPrefix("--"), "\(preset): \(argument.flag)")
                XCTAssertNotNil(argument.value, "\(preset): \(argument.flag) has no value")
                XCTAssertFalse(argument.reason.isEmpty, "\(preset): \(argument.flag) has no reason")
                XCTAssertEqual(argument.category, .performance)
            }
        }
    }

    func testPresetsWithArgumentsCarryATemperature() {
        for preset in SamplingPreset.allCases where !preset.arguments.isEmpty {
            XCTAssertNotNil(preset.temperature, "\(preset) emits flags but declares no temperature")
            XCTAssertEqual(
                preset.arguments.first?.flag,
                "--temp",
                "\(preset) should lead with --temp"
            )
        }
    }

    // MARK: - Value formatting

    func testScalarWritesWholeNumbersWithoutATrailingDecimal() {
        XCTAssertEqual(SamplingPreset.scalar(1.0), "1")
        XCTAssertEqual(SamplingPreset.scalar(0.0), "0")
        XCTAssertEqual(SamplingPreset.scalar(40.0), "40")
        XCTAssertEqual(SamplingPreset.scalar(128_256.0), "128256")
    }

    func testScalarKeepsRealFractions() {
        XCTAssertEqual(SamplingPreset.scalar(0.7), "0.7")
        XCTAssertEqual(SamplingPreset.scalar(0.05), "0.05")
        XCTAssertEqual(SamplingPreset.scalar(0.95), "0.95")
        XCTAssertEqual(SamplingPreset.scalar(1.1), "1.1")
        XCTAssertEqual(SamplingPreset.scalar(1.75), "1.75")
        XCTAssertEqual(SamplingPreset.scalar(0.8), "0.8")
    }

    func testNoEmittedValueEndsInDotZero() {
        for preset in SamplingPreset.allCases {
            for argument in preset.arguments {
                let value = argument.value ?? ""
                XCTAssertFalse(
                    value.hasSuffix(".0"),
                    "\(preset) renders \(argument.rendered), which reads as a mistake"
                )
            }
        }
    }

    // MARK: - Presentation

    func testLabelsAndExplanationsArePresentAndDistinct() {
        let labels = SamplingPreset.allCases.map(\.label)
        let explanations = SamplingPreset.allCases.map(\.explanation)

        XCTAssertEqual(Set(labels).count, SamplingPreset.allCases.count)
        XCTAssertEqual(Set(explanations).count, SamplingPreset.allCases.count)
        for preset in SamplingPreset.allCases {
            XCTAssertFalse(preset.label.isEmpty)
            XCTAssertFalse(preset.explanation.isEmpty)
        }
    }

    func testAgentLabelSaysWhatItIsFor() {
        XCTAssertEqual(SamplingPreset.agent.label, "Agent (deterministic)")
    }

    // MARK: - The sampler chain
    //
    // `--samplers` replaces the whole chain, so naming it is what stops a preset
    // from depending on llama.cpp's default sequence. Two properties are claimed
    // by `SamplingPreset.samplerChain`'s own documentation, and both are asserted
    // here rather than trusted: the chain is llama.cpp's documented order with
    // stages removed and never reordered, and it names exactly the stages the
    // preset's value flags configure.

    func testModelDefaultNamesNoChain() {
        // The preset is defined as emitting no sampling flags at all, so it must
        // not emit this one either — otherwise "leave the sampler alone" would
        // still replace the sampler chain.
        XCTAssertNil(SamplingPreset.modelDefault.samplerChain)
    }

    func testEveryOtherPresetNamesAChain() {
        for preset in SamplingPreset.allCases where preset != .modelDefault {
            XCTAssertNotNil(preset.samplerChain, "\(preset) configures values but names no chain")
        }
    }

    func testEachChainIsTheDocumentedOrderWithStagesRemoved() {
        let documented = SamplingPreset.documentedChain

        for preset in SamplingPreset.allCases {
            guard let chain = preset.samplerChain else { continue }
            let stages = chain.split(separator: ";").map(String.init)

            // Subsequence, not subset: the same stages in the same relative
            // order as llama.cpp lists them. A chain that reordered them would
            // change what sampling does, which is the opposite of the intent —
            // this flag exists to stop unset stages running at their defaults,
            // not to rearrange the pipeline.
            var cursor = documented.startIndex
            for stage in stages {
                guard let found = documented[cursor...].firstIndex(of: stage) else {
                    return XCTFail("\(preset): \(stage) is out of documented order or unknown")
                }
                cursor = documented.index(after: found)
            }
        }
    }

    func testTheChainNamesExactlyTheStagesTheValuesConfigure() {
        for preset in SamplingPreset.allCases {
            guard let chain = preset.samplerChain else {
                XCTAssertTrue(
                    preset.arguments.isEmpty,
                    "\(preset) names no chain but emits values, which would do nothing"
                )
                continue
            }

            let named = Set(chain.split(separator: ";").map(String.init))
            let configured = Set(
                preset.arguments.compactMap { SamplingPreset.stageOfFlag[$0.flag] }
            )

            XCTAssertEqual(
                named, configured,
                "\(preset): the chain and its values disagree — a stage nothing configures is "
                    + "noise, and a value whose stage is missing from the chain does nothing"
            )
        }
    }

    func testEverySamplerValueFlagIsMappedToAStage() {
        // The link between a flag and its stage is by name and nothing enforces
        // it at compile time, so an unmapped flag is a value that silently stops
        // travelling with its chain.
        for preset in SamplingPreset.allCases {
            for argument in preset.arguments {
                XCTAssertNotNil(
                    SamplingPreset.stageOfFlag[argument.flag],
                    "\(preset): \(argument.flag) is not mapped to a sampler stage"
                )
            }
        }
    }

    func testEveryMappedStageIsInTheDocumentedChain() {
        // The reverse direction: a mapping that points at a stage llama.cpp does
        // not have would produce a chain the binary rejects at startup.
        for (flag, stage) in SamplingPreset.stageOfFlag {
            XCTAssertTrue(
                SamplingPreset.documentedChain.contains(stage),
                "\(flag) maps to \(stage), which is not a stage llama.cpp documents"
            )
        }
    }

    func testTheChainsAreDistinctPerPreset() {
        // Two presets naming the same chain would be two presets that differ
        // only in their values, which is a distinction the chain is supposed to
        // make visible.
        let chains = SamplingPreset.allCases.compactMap(\.samplerChain)
        XCTAssertEqual(Set(chains).count, chains.count, "\(chains)")
    }

    // MARK: - Codable

    func testRoundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode(SamplingPreset.creative)
        XCTAssertEqual(try JSONDecoder().decode(SamplingPreset.self, from: data), .creative)
    }

    func testRawValuesAreStable() {
        // These strings are persisted with workspace settings, so renaming one
        // silently loses a user's choice.
        XCTAssertEqual(SamplingPreset.modelDefault.rawValue, "modelDefault")
        XCTAssertEqual(SamplingPreset.agent.rawValue, "agent")
        XCTAssertEqual(SamplingPreset.balanced.rawValue, "balanced")
        XCTAssertEqual(SamplingPreset.creative.rawValue, "creative")
    }
}
