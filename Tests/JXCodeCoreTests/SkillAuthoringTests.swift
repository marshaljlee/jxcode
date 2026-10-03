import XCTest
@testable import JXCodeCore

/// The authoring half of a skill: what a good description looks like.
///
/// Separate from `SkillSpec` on purpose, and the tests are separate for the
/// same reason — a finding is a claim about whether a file loads, and advice is
/// a claim about whether a skill will ever be chosen. Nothing here refuses
/// anything, so nothing here should ever make a skill unbindable.
final class SkillAuthoringTests: XCTestCase {

    // MARK: - The rule set

    /// Three, pinned as a number.
    ///
    /// The count is the deliverable as much as the text is: the plan asks for
    /// advice rather than a style guide, and the failure mode of this list is
    /// that it grows one reasonable-sounding rule at a time until an author
    /// skims it. A fourth rule should be a deliberate decision that moves this
    /// number.
    func testThereAreExactlyThreeRules() {
        XCTAssertEqual(SkillAuthoring.rules.count, 3)
    }

    func testEveryRuleCarriesTheReasonItExists() {
        for rule in SkillAuthoring.rules {
            XCTAssertFalse(rule.headline.isEmpty, "a rule with no headline is invisible")
            XCTAssertFalse(
                rule.because.isEmpty,
                "“\(rule.headline)” states a preference with no mechanism behind it"
            )
            XCTAssertFalse(
                rule.good.isEmpty,
                "“\(rule.headline)” says what fails without saying what works"
            )
        }
    }

    /// Exactly one rule is about an absence, and it is the only one with
    /// nothing to show.
    ///
    /// Pinned because `examples` keys off `bad.isEmpty` to decide whether to
    /// print a ✗ line, so a second rule that lost its example would silently
    /// lose its failing half rather than fail a test.
    func testOnlyTheAbsenceRuleHasNoFailingExample() {
        let withoutBad = SkillAuthoring.rules.filter { $0.bad.isEmpty }
        XCTAssertEqual(withoutBad.count, 1)
        XCTAssertEqual(withoutBad.first, SkillAuthoring.rules[2])
        XCTAssertEqual(withoutBad.first?.examples.count, 1)
    }

    /// Every good example is the same sentence.
    ///
    /// This is the pedagogical claim the rules make: one line satisfies all
    /// three, so an author who writes it has nothing left to check. If the
    /// examples drift apart the rules become three separate instructions and
    /// the test is the only thing that noticed.
    func testEveryGoodExampleIsTheWorkedExample() {
        for rule in SkillAuthoring.rules {
            XCTAssertEqual(rule.good, SkillAuthoring.workedExample, rule.headline)
        }
    }

    // MARK: - The advice selector

    func testAnEmptyDescriptionGetsTheRuleAboutAbsence() {
        XCTAssertEqual(SkillAuthoring.advice(name: "Release checklist", description: ""),
                       SkillAuthoring.rules[2])
        XCTAssertEqual(SkillAuthoring.advice(name: "Release checklist", description: "   \n"),
                       SkillAuthoring.rules[2])
    }

    func testADescriptionThatIsTheNameGetsTheRuleAboutNaming() {
        XCTAssertEqual(SkillAuthoring.advice(name: "Release checklist", description: "Release checklist"),
                       SkillAuthoring.rules[0])
        // The name in another capitalization is the same mistake.
        XCTAssertEqual(SkillAuthoring.advice(name: "Release checklist", description: "release CHECKLIST"),
                       SkillAuthoring.rules[0])
    }

    /// The slug is what the directory will be called, so it is what an author
    /// who has already seen the file is most likely to copy back.
    func testADescriptionThatIsTheSlugOfTheNameGetsTheRuleAboutNaming() {
        XCTAssertEqual(SkillAuthoring.advice(name: "House Style", description: "house-style"),
                       SkillAuthoring.rules[0])
    }

    func testADescriptionAboutTheSkillRatherThanTheTaskGetsTheRuleAboutNaming() {
        for opener in ["This skill explains how to read a git log",
                       "A skill that normalizes line endings",
                       "This is a skill for releases"] {
            XCTAssertEqual(
                SkillAuthoring.advice(name: "Git Log", description: opener),
                SkillAuthoring.rules[0],
                opener
            )
        }
    }

    func testAnOverlongDescriptionGetsTheRuleAboutLength() {
        let long = String(repeating: "a ", count: SkillSpec.maxDescriptionLength)
        XCTAssertEqual(SkillAuthoring.advice(name: "Verbose", description: long),
                       SkillAuthoring.rules[1])
    }

    /// The common answer, and the one that keeps the advice worth reading.
    ///
    /// `nil` here is not a gap: advice that fires on a good description is
    /// advice an author learns to skip.
    func testAGoodDescriptionGetsNoAdvice() {
        XCTAssertNil(SkillAuthoring.advice(name: "Release Notes",
                                           description: SkillAuthoring.workedExample))
        XCTAssertNil(SkillAuthoring.advice(name: "Git Log",
                                           description: "Read a log when a branch diverged"))
    }

    /// The near-miss a longer prefix list would have flagged.
    ///
    /// "Use this skill when…" opens with a self-reference and is a perfectly
    /// good description, because the rest of the sentence is the condition. A
    /// list of openers that grew to include "use this" would start refusing
    /// good descriptions, which is why the list is three entries and this test
    /// holds the line.
    func testUseThisSkillWhenIsNotFlagged() {
        XCTAssertNil(SkillAuthoring.advice(
            name: "Git Log",
            description: "Use this skill when a branch has diverged and you need the merge base"
        ))
    }

    func testTheHintIsNilForAGoodDescriptionAndOneLineOtherwise() {
        XCTAssertNil(SkillAuthoring.hint(name: "Release Notes",
                                         description: SkillAuthoring.workedExample))

        let hint = SkillAuthoring.hint(name: "Tidy", description: "Tidy")
        XCTAssertEqual(hint, SkillAuthoring.rules[0].oneLine)
        XCTAssertFalse(hint?.contains("\n") ?? true, "a hint under a text field has to be one line")
    }

    // MARK: - The rendered surfaces

    /// Every rule and every example reaches the terminal, and none of them
    /// wraps itself.
    ///
    /// The width check is the point. A terminal does not wrap for us and the
    /// bad examples are long on purpose, so an unwrapped line is a break in the
    /// middle of the sentence the author is comparing against — invisible in a
    /// diff, obvious in a real terminal, which is exactly the kind of defect
    /// this repo records rather than asserts.
    func testTheHelpIsWrappedAndComplete() {
        let help = SkillAuthoring.helpText
        let lines = help.components(separatedBy: "\n")

        for line in lines {
            XCTAssertLessThanOrEqual(line.count, 80, "over 80 columns: \(line)")
        }
        for rule in SkillAuthoring.rules {
            XCTAssertTrue(help.contains(rule.headline), rule.headline)
            XCTAssertTrue(help.contains(rule.good), rule.headline)
        }
        XCTAssertTrue(help.contains("routing key"),
                      "the help has to say why the description is not a title")
        XCTAssertTrue(help.contains("jxcode skill-check"),
                      "the help has to point at the command that judges a skill already written")
    }

    /// The pane carries the same three rules, because it has no room for the
    /// full block and a second copy of the text would drift.
    func testTheTooltipCarriesEveryRuleAndTheReason() {
        let tooltip = SkillAuthoring.tooltip
        for rule in SkillAuthoring.rules {
            XCTAssertTrue(tooltip.contains(rule.headline), rule.headline)
            XCTAssertTrue(tooltip.contains(rule.good), rule.headline)
        }
        XCTAssertTrue(tooltip.contains("routing key"),
                      "the tooltip is the only place the pane can explain why the description matters")
    }
}
