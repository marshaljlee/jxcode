import Foundation

/// Arbitrary JSON.
///
/// Needed because tool `input` payloads and JSON Schemas have no fixed shape —
/// they are whatever the model produced or the tool author declared. Modelling
/// them as a value type keeps the wire types honest instead of pretending the
/// shape is known.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        // Order matters: Bool before Double, because `true` would otherwise be
        // coerced by some decoders.
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "unsupported JSON value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:              try container.encodeNil()
        case .bool(let value):   try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value):  try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public extension JSONValue {

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        numberValue.map { Int($0) }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// An object, or an empty one. Convenient when building requests.
    var objectOrEmpty: [String: JSONValue] {
        objectValue ?? [:]
    }

    /// Serialised form, for embedding in a JSON string field.
    ///
    /// `sortedKeys` so the output is stable — tool-call arguments get compared
    /// and logged, and unstable ordering makes both harder.
    func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parse a JSON string. Returns `.null` on failure so callers can treat a
    /// malformed tool-call argument as empty rather than throwing mid-stream.
    static func parse(_ string: String) -> JSONValue {
        guard let data = string.data(using: .utf8) else { return .null }
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }

    /// Flatten whatever a content field holds into plain text.
    ///
    /// Anthropic lets several fields be either a bare string or an array of
    /// content blocks — `tool_result.content` and `system` both do. OpenAI has
    /// no equivalent, so both collapse to text.
    var flattenedText: String {
        switch self {
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.flattenedText).filter { !$0.isEmpty }.joined(separator: "\n")
        case .object(let object):
            // A single content block, e.g. {"type":"text","text":"..."}
            if let text = object["text"]?.stringValue { return text }
            if let content = object["content"] { return content.flattenedText }
            return jsonString()
        case .number(let value):
            return value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value):
            return String(value)
        case .null:
            return ""
        }
    }
}
