import Foundation

extension URL {

    /// Whether this path lies *inside* `directory`.
    ///
    /// The trailing slash is the whole point. Without it, `/x/skills-archive`
    /// reads as inside `/x/skills`, and a containment test that answers yes to a
    /// sibling is worse than no test at all — containment is the question that
    /// decides whether something gets deleted.
    ///
    /// Both sides are standardised first, so `..` is resolved before the
    /// comparison rather than after it.
    ///
    /// Symlinks are deliberately **not** resolved: this answers a question about
    /// the path as written, which is what a link's destination is. Resolving it
    /// would make a stale link — one whose target no longer exists — answer
    /// "outside", so pruning it would leave exactly the dangling entry the prune
    /// exists to remove.
    ///
    /// The directory is not inside itself.
    public func isContained(in directory: URL) -> Bool {
        let here = standardizedFileURL.path
        let container = directory.standardizedFileURL.path
        return here.hasPrefix(container.hasSuffix("/") ? container : container + "/")
    }
}
