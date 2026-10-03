import Foundation

/// Deterministic JSON text, with one escaping rule for the whole app.
///
/// Two things are needed from every JSON write here, and they were being
/// re-derived at each call site — which is how the collection ended up writing
/// `@modelcontextprotocol\/server-filesystem` into the manifest while the agent
/// configs next to it were clean.
///
/// 1. **Deterministic bytes.** Sorted keys and stable formatting, so rewriting
///    an unchanged value does not churn the file and the "already correct"
///    checks can be a plain string comparison.
/// 2. **No escaped slashes.** `JSONEncoder` and `JSONSerialization` both write
///    `/` as `\/`. That is legal JSON, but these files are meant to be read by a
///    person, and a URL or a package name full of backslashes looks broken.
///    Undoing it is safe: a literal backslash is itself escaped as `\\`, so a
///    `\/` sequence in the output can only ever be an escaped slash.
public enum JSONText {

    /// Render an `Encodable` value.
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SharedCollectionError.unreadableJSON
        }
        return unescapeSlashes(text) + "\n"
    }

    /// Render an already-parsed JSON object.
    public static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw SharedCollectionError.unreadableJSON
        }
        return unescapeSlashes(text) + "\n"
    }

    static func unescapeSlashes(_ text: String) -> String {
        text.replacingOccurrences(of: "\\/", with: "/")
    }
}
