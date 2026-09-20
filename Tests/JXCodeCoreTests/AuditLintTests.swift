import XCTest

/// A static lint over the app target's source, run as part of `swift test`.
///
/// The contrast audit found its findings one at a time by sweeping for
/// `SwiftUI` semantic colours that bypassed `Theme`: `.secondary`, `.orange`,
/// `.green`, `.teal`, `.tertiary`, three `.white` icon tints, etc. — 22 sites
/// in five rounds. This test makes the next one impossible: any semantic
/// colour in a colour position fails the suite at PR time.
///
/// The rule: the only colour values in `Sources/JXCodeApp/` are those defined
/// in `Theme` (which references `Palette`) and SwiftUI's `.clear`. Every
/// other colour is a leak — semantic in one mode and a contrast defect in the
/// other — and the audit has to find and remove it before this test will pass.
final class AuditLintTests: XCTestCase {

    /// SwiftUI semantic colours that are not allowed in colour positions.
    /// `.clear` is permitted; `.white` is forbidden everywhere except in the
    /// one place it is a documented fallback (`Theme.ink(on:)`), which is
    /// outside the app target's source so this test doesn't see it.
    private static let forbidden: Set<String> = [
        ".primary", ".secondary", ".tertiary", ".quaternary",
        ".red", ".orange", ".yellow", ".green", ".mint",
        ".teal", ".cyan", ".blue", ".indigo", ".purple",
        ".pink", ".brown", ".white", ".black", ".gray",
    ]

    /// Positions a SwiftUI semantic colour would occupy.
    private static let colourPositions: [String] = [
        ".foregroundStyle(",
        ".foregroundColor(",
        ".fill(",
        ".background(",
        ".stroke(",
        ".tint(",
    ]

    /// Modifier-looking positions where `tint:` is a parameter (not a colour
    /// modifier). `.white` on `MXIconView(name:, size:, tint:)` is the exact
    /// case this audit fixed — checked below.
    private static let tintParameterPositions: [String] = [
        "tint: ",
    ]

    /// Match a colour position followed by a forbidden colour, with possible
    /// whitespace in between.
    private static func makeRegex() -> NSRegularExpression {
        let pos = colourPositions
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let for_ = forbidden
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        // e.g. \.foregroundStyle\( *\.secondary
        // The negative lookbehind excludes identifier tails: `textPrimary`
        // and `tileBlue` end in `.primary` and `.blue` and must not match.
        let pattern = "(?<!\\w)(?:\(pos))\\s*(?<!\\w)(?:\(for_))"
        return try! NSRegularExpression(pattern: pattern)
    }

    private static let regex = makeRegex()

    /// Source root, relative to the package root that `swift test` runs from.
    private var sourcesRoot: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/JXCodeApp")
    }

    func testNoSwiftUISemanticColourInColourPositions() throws {
        guard FileManager.default.fileExists(atPath: sourcesRoot.path) else {
            // Not running from the package root (e.g. an editor's test
            // runner). Skip rather than fail — the lint's value is in CI.
            throw XCTSkip("Sources/JXCodeApp not found at \(sourcesRoot.path)")
        }

        var violations: [String] = []
        for file in try files(in: sourcesRoot) {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            Self.regex.enumerateMatches(in: source, range: range) { match, _, _ in
                guard let m = match else { return }
                let snippet = (source as NSString).substring(with: m.range)
                let line = source.lineNumber(at: m.range.location)
                let relative = file.path
                    .replacingOccurrences(of: FileManager.default.currentDirectoryPath
                                          + "/", with: "")
                violations.append("\(relative):\(line)  \(snippet)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "SwiftUI semantic colours must come from `Theme`, not from the "
            + "SwiftUI palette. Offenders:\n  " + violations.joined(separator: "\n  ")
        )
    }

    /// A separate, narrower check for the icon-tint parameter — the exact
    /// shape the audit had to fix in three places. `tint:` is a positional
    /// argument of `MXIconView` rather than a modifier, so the regex above
    /// does not see it.
    func testNoHardcodedWhiteInIconTints() throws {
        guard FileManager.default.fileExists(atPath: sourcesRoot.path) else {
            throw XCTSkip("Sources/JXCodeApp not found at \(sourcesRoot.path)")
        }

        var violations: [String] = []
        let pattern = try NSRegularExpression(
            pattern: "tint:\\s*\\.white\\b"
        )
        for file in try files(in: sourcesRoot) {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            pattern.enumerateMatches(in: source, range: range) { match, _, _ in
                guard let m = match else { return }
                let line = source.lineNumber(at: m.range.location)
                let relative = file.path
                    .replacingOccurrences(of: FileManager.default.currentDirectoryPath
                                          + "/", with: "")
                violations.append("\(relative):\(line)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "`MXIconView` tint must come from `Theme.ink(on: ...)`, not from "
            + "`.white`. Offenders:\n  " + violations.joined(separator: "\n  ")
        )
    }

    private func files(in root: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var out: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" { out.append(url) }
        }
        return out
    }
}

private extension String {
    /// 1-based line number for an offset.
    func lineNumber(at offset: Int) -> Int {
        let prefix = self.prefix(offset)
        return prefix.reduce(1) { $0 + ($1 == "\n" ? 1 : 0) }
    }
}