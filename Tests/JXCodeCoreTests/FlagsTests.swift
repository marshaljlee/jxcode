import XCTest
@testable import JXCodeCore

/// A flag that takes no value must not eat the token after it.
///
/// The failure it causes is silent in a way worth spelling out: the token
/// disappears from `positional`, the command falls back to its default, and
/// nothing anywhere reports a value on an option that never wanted one.
final class FlagsTests: XCTestCase {

    /// The case from the review: `jxcode scan --names-only /Volumes/Models`.
    func testASwitchDoesNotSwallowTheNextPositional() {
        let flags = parseFlags(["--names-only", "/Volumes/Models"])

        XCTAssertTrue(flags.has("--names-only"))
        XCTAssertEqual(flags.value("--names-only"), "", "the flag took the path as its value")
        XCTAssertEqual(
            flags.positional, ["/Volumes/Models"],
            "the path was eaten, so the command will fall back to its default"
        )
    }

    func testAValuedOptionStillTakesItsValue() {
        let flags = parseFlags(["--workspace", "ws", "scan"])

        XCTAssertEqual(flags.value("--workspace"), "ws")
        XCTAssertEqual(flags.positional, ["scan"])
    }

    /// `--key=value` works for any option, including one that is not listed.
    func testAnEqualsSignBindsTheValue() {
        let flags = parseFlags(["--workspace=ws", "--names-only=true", "left"])

        XCTAssertEqual(flags.value("--workspace"), "ws")
        XCTAssertTrue(flags.has("--names-only"))
        XCTAssertEqual(flags.positional, ["left"])
    }

    /// An option nobody has heard of is a switch: better to lose nothing than
    /// to guess that it takes a value.
    func testAnUnlistedFlagIsASwitch() {
        let flags = parseFlags(["--future-flag", "/path"])

        XCTAssertTrue(flags.has("--future-flag"))
        XCTAssertEqual(flags.positional, ["/path"])
    }

    func testAValuedOptionDoesNotSwallowAFlag() {
        let flags = parseFlags(["--workspace", "--quiet", "x"])

        XCTAssertEqual(flags.value("--workspace"), "")
        XCTAssertTrue(flags.has("--quiet"))
        XCTAssertEqual(flags.positional, ["x"])
    }

    /// Left empty rather than absent, so `--workspace` with nothing after it is
    /// reported as a missing name instead of being silently ignored.
    func testAValuedOptionWithNoValueIsEmptyNotAbsent() {
        let flags = parseFlags(["--workspace"])

        XCTAssertTrue(flags.has("--workspace"))
        XCTAssertEqual(flags.value("--workspace"), "")
        XCTAssertTrue(flags.positional.isEmpty)
    }

    /// The other half of the same defect. Read "a value happens to follow" as
    /// the rule and this is what breaks; read the set as empty and it breaks the
    /// other way, with `--name "Release checklist"` landing in `positional`
    /// while `--name` reports empty.
    func testEveryValuedOptionInRealUseTakesItsValue() {
        let flags = parseFlags([
            "--name", "Release checklist", "--description", "how we ship",
            "--agent", "claude", "--prompt", "triage open issues",
        ])

        XCTAssertEqual(flags.value("--name"), "Release checklist")
        XCTAssertEqual(flags.value("--description"), "how we ship")
        XCTAssertEqual(flags.value("--agent"), "claude")
        XCTAssertEqual(flags.value("--prompt"), "triage open issues")
        XCTAssertTrue(flags.positional.isEmpty)
    }

    /// The set is the fix, and the set is what rots: the next command to read
    /// `flags.value("--something")` that is not listed here parses as a switch
    /// and eats its own argument, which is the bug this file exists for. So the
    /// agreement is checked against the commands themselves rather than trusted.
    func testValuedOptionsMatchesWhatTheCommandsActuallyRead() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // JXCodeCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the package
        let commands = root.appendingPathComponent("Sources/jxcode")
        let files = try FileManager.default.contentsOfDirectory(
            at: commands, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no CLI sources found at \(commands.path)")

        let pattern = try NSRegularExpression(
            pattern: #"flags\.(value|has)\("(--[a-z0-9-]+)"\)"#, options: []
        )
        var valued: Set<String> = []
        var switches: Set<String> = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(
                in: text, options: [], range: NSRange(text.startIndex..., in: text)
            ) {
                guard let kind = Range(match.range(at: 1), in: text),
                      let name = Range(match.range(at: 2), in: text)
                else { continue }
                if text[kind] == "value" { valued.insert(String(text[name])) }
                else { switches.insert(String(text[name])) }
            }
        }

        XCTAssertFalse(valued.isEmpty, "the scan found nothing — the pattern is wrong")
        XCTAssertEqual(
            valued, Flags.valuedOptions,
            "a flag read with value() is missing from valuedOptions, so it "
                + "parses as a switch and swallows the token after it"
        )
        XCTAssertEqual(
            switches.intersection(Flags.valuedOptions), [],
            "a flag read with has() is listed as taking a value"
        )
    }

    func testPositionalOrderIsPreserved() {
        let flags = parseFlags(["first", "--quiet", "second", "third"])

        XCTAssertTrue(flags.has("--quiet"))
        XCTAssertEqual(flags.positional, ["first", "second", "third"])
    }
}
