import XCTest

/// A static lint over the app target: nothing in it may block the main actor.
///
/// The defects behind this were all the same shape — a call that is correct in
/// a command-line tool and wrong in a view. `usleep` waiting for a server to
/// unload a model, `pgrep` with `waitUntilExit()` looking for conflicting
/// processes, a filesystem walk evaluated inside `body`, and `otool` run once
/// per library from `onAppear`. Each cost milliseconds in a test and a frozen
/// window on a real machine.
///
/// A unit test cannot check this: `AppState` and the panes live in the
/// executable target, which the test target does not import, so the behaviour
/// is unreachable from here. The invariant that *is* checkable is enforced
/// instead — no blocking primitive may appear in the app target at all. Work
/// that occupies a thread belongs in `JXCodeCore`, behind an `async` function
/// the UI can `await`.
final class MainThreadLintTests: XCTestCase {

    /// Calls that occupy the calling thread until something else finishes.
    ///
    /// A short list of unambiguous primitives rather than a general lint over
    /// everything that could block. None of them has a legitimate use in a
    /// view, and all of them are invisible in code review next to the code
    /// they are standing in for.
    private static let blocking: [String] = [
        "usleep(",
        "waitUntilExit(",
        "Thread.sleep(",
        "readDataToEndOfFile()",
    ]

    private var sourcesRoot: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/JXCodeApp")
    }

    func testAppTargetContainsNothingThatBlocksItsCaller() throws {
        guard FileManager.default.fileExists(atPath: sourcesRoot.path) else {
            // Not running from the package root (an editor's test runner, say).
            // Skip rather than fail — the lint's value is in CI.
            throw XCTSkip("Sources/JXCodeApp not found at \(sourcesRoot.path)")
        }

        var violations: [String] = []
        for file in try files(in: sourcesRoot) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for primitive in Self.blocking where line.contains(primitive) {
                    let relative = file.path
                        .replacingOccurrences(of: FileManager.default.currentDirectoryPath + "/", with: "")
                    violations.append("\(relative):\(index + 1)  \(primitive)")
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "The app target must not block the main actor. Move the work into "
            + "JXCodeCore behind an `async` function and `await` it. Offenders:\n  "
            + violations.joined(separator: "\n  ")
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
