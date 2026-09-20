import Foundation
@testable import JXCodeCore

/// Writes synthetic GGUF files so the reader can be tested without shipping
/// multi-gigabyte fixtures.
///
/// This deliberately emits the *real* wire format — little-endian, `u64`-prefixed
/// strings, the actual type discriminants — rather than a convenient Swift
/// serialisation, because the point of the tests is to catch disagreements with
/// llama.cpp's format, not with itself.
struct GGUFFixtureBuilder {
    var version: UInt32 = 3
    var tensorCount: UInt64 = 0
    var entries: [(key: String, value: GGUFValue)] = []

    init(version: UInt32 = 3, tensorCount: UInt64 = 0) {
        self.version = version
        self.tensorCount = tensorCount
    }

    func build() -> Data {
        var out = Data()
        out.append(contentsOf: Array("GGUF".utf8))
        out.appendLE(version)
        out.appendLE(tensorCount)
        out.appendLE(UInt64(entries.count))
        for entry in entries {
            out.appendString(entry.key)
            out.appendValue(entry.value)
        }
        return out
    }

    func write(to url: URL) throws {
        try build().write(to: url)
    }

    // MARK: - Fluent construction

    func with(_ key: String, _ string: String) -> GGUFFixtureBuilder {
        var copy = self
        copy.entries.append((key, .string(string)))
        return copy
    }

    func with(_ key: String, _ int: Int) -> GGUFFixtureBuilder {
        var copy = self
        // Negative values must go out as a signed type. `UInt64(-7)` traps at
        // runtime rather than wrapping, so this branch is not cosmetic.
        copy.entries.append((key, int < 0 ? .signed(Int64(int)) : .unsigned(UInt64(int))))
        return copy
    }

    func with(_ key: String, _ double: Double) -> GGUFFixtureBuilder {
        var copy = self
        copy.entries.append((key, .floating(double)))
        return copy
    }

    func with(_ key: String, _ bool: Bool) -> GGUFFixtureBuilder {
        var copy = self
        copy.entries.append((key, .boolean(bool)))
        return copy
    }

    func with(_ key: String, array: [GGUFValue]) -> GGUFFixtureBuilder {
        var copy = self
        copy.entries.append((key, .array(array)))
        return copy
    }

    /// A complete, plausible language-model header.
    static func llama(
        architecture: String = "llama",
        contextLength: Int = 131_072,
        blockCount: Int = 32,
        embeddingLength: Int = 4096,
        headCount: Int = 32,
        headCountKV: Int = 8,
        chatTemplate: String? = "<|start|>{{ prompt }}<|end|>",
        fileType: GGMLFileType = .mostlyQ8_0
    ) -> GGUFFixtureBuilder {
        var builder = GGUFFixtureBuilder()
            .with("general.architecture", architecture)
            .with("general.name", "Fixture Model")
            .with("general.size_label", "8B")
            .with("general.file_type", fileType.rawValue)
            .with("\(architecture).context_length", contextLength)
            .with("\(architecture).block_count", blockCount)
            .with("\(architecture).embedding_length", embeddingLength)
            .with("\(architecture).attention.head_count", headCount)
            .with("\(architecture).attention.head_count_kv", headCountKV)
            .with("\(architecture).rope.freq_base", 10000.0)
        if let chatTemplate {
            builder = builder.with("tokenizer.chat_template", chatTemplate)
        }
        return builder
    }

    /// A complete, plausible vision-projector header.
    static func clip(
        projectorType: String = "mlp",
        imageSize: Int = 448,
        patchSize: Int = 14
    ) -> GGUFFixtureBuilder {
        GGUFFixtureBuilder()
            .with("general.architecture", "clip")
            .with("general.name", "Fixture Projector")
            .with("clip.has_vision_encoder", true)
            .with("clip.has_audio_encoder", false)
            .with("clip.projector_type", projectorType)
            .with("clip.vision.image_size", imageSize)
            .with("clip.vision.patch_size", patchSize)
            .with("clip.vision.embedding_length", 1152)
            .with("clip.vision.projection_dim", 4096)
            .with("clip.vision.block_count", 27)
            .with("clip.vision.attention.head_count", 16)
    }
}

// MARK: - Little-endian encoding

private extension Data {
    mutating func appendLE(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }

    mutating func appendLE(_ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    mutating func appendLE(_ value: Float) {
        appendLE(value.bitPattern)
    }

    mutating func appendString(_ string: String) {
        let bytes = Array(string.utf8)
        appendLE(UInt64(bytes.count))
        append(contentsOf: bytes)
    }

    mutating func appendValue(_ value: GGUFValue) {
        switch value {
        case .unsigned(let number):
            if number <= UInt64(UInt32.max) {
                appendLE(UInt32(4))            // uint32
                appendLE(UInt32(number))
            } else {
                appendLE(UInt32(10))           // uint64
                appendLE(number)
            }
        case .signed(let number):
            appendLE(UInt32(5))                // int32
            appendLE(UInt32(bitPattern: Int32(truncatingIfNeeded: number)))
        case .floating(let number):
            appendLE(UInt32(6))                // float32
            appendLE(Float(number))
        case .boolean(let flag):
            appendLE(UInt32(7))                // bool
            append(flag ? 1 : 0)
        case .string(let text):
            appendLE(UInt32(8))                // string
            appendString(text)
        case .array(let elements):
            appendLE(UInt32(9))                // array
            appendLE(UInt32(Self.elementType(of: elements)))
            appendLE(UInt64(elements.count))
            for element in elements {
                appendArrayElement(element)
            }
        }
    }

    /// Array elements are written as bare values — the element type is declared
    /// once in the array header, not repeated per element.
    mutating func appendArrayElement(_ value: GGUFValue) {
        switch value {
        case .unsigned(let number): appendLE(UInt32(number))
        case .signed(let number):   appendLE(UInt32(bitPattern: Int32(truncatingIfNeeded: number)))
        case .floating(let number): appendLE(Float(number))
        case .boolean(let flag):    append(flag ? 1 : 0)
        case .string(let text):     appendString(text)
        case .array(let elements):
            appendLE(UInt32(Self.elementType(of: elements)))
            appendLE(UInt64(elements.count))
            for element in elements { appendArrayElement(element) }
        }
    }

    static func elementType(of elements: [GGUFValue]) -> Int {
        switch elements.first {
        case .unsigned: return 4   // uint32
        case .signed:   return 5   // int32
        case .floating: return 6   // float32
        case .boolean:  return 7   // bool
        case .string:   return 8   // string
        case .array:    return 9
        case nil:       return 4
        }
    }
}
