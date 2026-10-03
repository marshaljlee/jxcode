import Foundation

// MARK: - GGUF
//
// GGUF is the container format llama.cpp uses for quantised models. Its layout
// is a header followed by a metadata key/value store, followed by tensor data:
//
//     magic          u32   0x46554747 ("GGUF" little-endian)
//     version        u32   2 or 3 (1 exists and is obsolete)
//     tensor_count   u64
//     kv_count       u64
//     kv pairs...
//     tensor descriptors...
//     tensor data (aligned)
//
// Everything is little-endian. Strings are `u64 length` followed by that many
// bytes of UTF-8 and are **not** null-terminated, which is the detail that
// breaks naive parsers.
//
// This reader exists for three reasons, and all three are why it is a streaming
// parser rather than `Data(contentsOf:)`:
//
//   1. **The files are enormous.** The models on this machine run to 8.9 GB. The
//      metadata lives in the first few kilobytes. Reading the whole file to find
//      out its context length would be absurd.
//
//   2. **Some metadata values are enormous too.** `tokenizer.ggml.tokens` is an
//      array of ~150,000 strings, and `tokenizer.ggml.merges` is similar. A
//      reader that materialises every value it walks past will allocate hundreds
//      of megabytes and take seconds to answer a question whose answer was in
//      the first 4 KB. So values are **structurally traversed but not
//      materialised** unless they are asked for (see `GGUFReadOptions`).
//
//   3. **GGUF files are untrusted input.** They are downloaded from the
//      internet. A corrupt or hostile file can claim `kv_count` is 2^63 or that
//      a string is 40 GB long, so every read is bounded.

public enum GGUFError: Error, CustomStringConvertible {
    /// The first four bytes were not `GGUF`.
    case badMagic(UInt32)
    case unsupportedVersion(UInt32)
    case truncated(expected: Int, at: Int)
    case corrupt(String)
    case tooLarge(String)

    public var description: String {
        switch self {
        case .badMagic(let magic):
            let bytes = (0..<4).map { String(UnicodeScalar(UInt8((magic >> (8 * $0)) & 0xFF))) }.joined()
            return "not a GGUF file (magic was \"\(bytes)\")"
        case .unsupportedVersion(let version):
            return "unsupported GGUF version \(version) — this reader handles 2 and 3"
        case .truncated(let expected, let at):
            return "file ended after \(at) bytes while reading \(expected) more"
        case .corrupt(let detail):
            return "malformed GGUF: \(detail)"
        case .tooLarge(let detail):
            return "refusing to parse: \(detail)"
        }
    }
}

// MARK: - Values

/// One metadata value. GGUF has thirteen scalar types plus arrays; they collapse
/// onto five Swift shapes, which is all the interpretation layer needs.
public enum GGUFValue: Sendable, Equatable {
    case unsigned(UInt64)
    case signed(Int64)
    case floating(Double)
    case boolean(Bool)
    case string(String)
    case array([GGUFValue])

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var uintValue: UInt64? {
        switch self {
        case .unsigned(let value): return value
        case .signed(let value):   return value >= 0 ? UInt64(value) : nil
        default:                   return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .unsigned(let value): return value <= UInt64(Int.max) ? Int(value) : nil
        case .signed(let value):   return Int(value)
        default:                   return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .floating(let value): return value
        case .unsigned(let value): return Double(value)
        case .signed(let value):   return Double(value)
        default:                   return nil
        }
    }

    public var boolValue: Bool? {
        if case .boolean(let value) = self { return value }
        return nil
    }

    public var arrayValue: [GGUFValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// A compact rendering for logs and the CLI. Strings are quoted and
    /// truncated; arrays report their length rather than their contents,
    /// because the interesting arrays here have 150,000 entries.
    public var displayDescription: String {
        switch self {
        case .unsigned(let value): return String(value)
        case .signed(let value):   return String(value)
        case .floating(let value): return String(value)
        case .boolean(let value):  return value ? "true" : "false"
        case .string(let value):
            let flattened = value.replacingOccurrences(of: "\n", with: "\\n")
            if flattened.count <= 120 { return "\"\(flattened)\"" }
            return "\"\(flattened.prefix(117))...\" (\(flattened.count) chars)"
        case .array(let values):
            return "[\(values.count) values]"
        }
    }
}

/// The wire types. The raw values are the on-disk discriminants and must not be
/// reordered.
enum GGUFType: UInt32 {
    case uint8   = 0
    case int8    = 1
    case uint16  = 2
    case int16   = 3
    case uint32  = 4
    case int32   = 5
    case float32 = 6
    case bool    = 7
    case string  = 8
    case array   = 9
    case uint64  = 10
    case int64   = 11
    case float64 = 12

    var fixedWidth: Int? {
        switch self {
        case .uint8, .int8, .bool:   return 1
        case .uint16, .int16:        return 2
        case .uint32, .int32, .float32: return 4
        case .uint64, .int64, .float64: return 8
        case .string, .array:        return nil
        }
    }
}

// MARK: - Read options

/// Controls what the parser allocates. The defaults are tuned for "read a model
/// card", not "load a tokeniser".
public struct GGUFReadOptions: Sendable {
    /// Arrays longer than this are traversed (so the stream lands in the right
    /// place) but never allocated. The default is deliberately small: the only
    /// arrays worth keeping are things like `clip.vision.image_mean` (3 floats).
    public var maxMaterializedArrayElements: Int

    /// Hard ceiling on header bytes. A well-formed model card is a few KB; a
    /// 64 MB ceiling gives enormous headroom while still bounding a corrupt file.
    public var maxHeaderBytes: Int

    /// Keys skipped even when short, because they are known to be huge.
    ///
    /// `maxMaterializedArrayElements` already catches these, but listing them is
    /// belt-and-braces: if someone raises the array limit to inspect a tokeniser
    /// they should not accidentally allocate 150,000 Swift strings.
    public var skipKeys: Set<String>

    public static let heavyKeys: Set<String> = [
        "tokenizer.ggml.tokens",
        "tokenizer.ggml.merges",
        "tokenizer.ggml.scores",
        "tokenizer.ggml.token_type",
        "tokenizer.ggml.types",
    ]

    public init(
        maxMaterializedArrayElements: Int = 512,
        maxHeaderBytes: Int = 64 << 20,
        skipKeys: Set<String> = GGUFReadOptions.heavyKeys
    ) {
        self.maxMaterializedArrayElements = maxMaterializedArrayElements
        self.maxHeaderBytes = maxHeaderBytes
        self.skipKeys = skipKeys
    }

    public static let `default` = GGUFReadOptions()
}

// MARK: - Parsed header

public struct GGUFHeader: Sendable {
    public let version: UInt32
    public let tensorCount: UInt64
    public let metadataCount: UInt64
    public let metadata: [String: GGUFValue]

    /// Keys that were present in the file but deliberately not materialised.
    ///
    /// This exists so the parser never has to lie. An earlier version stored a
    /// skipped array as `.array([])`, which claims the array has zero elements
    /// when `tokenizer.ggml.tokens` actually has 150,000. Absence is honest —
    /// "we chose not to load this" — whereas an empty array is not. Keeping the
    /// names here means `jxcode model-info` can still report that the key exists.
    public let skippedKeys: Set<String>

    /// Element counts for arrays encountered in the header, keyed by metadata
    /// key — including arrays whose contents were never loaded. Lets a caller
    /// ask how many tokens a tokenizer has without paying to materialise them.
    public let arrayLengths: [String: UInt64]

    /// Bytes of the file actually read. Worth surfacing: it is the difference
    /// between "we parsed a 9 GB model" and "we read 11 KB of it".
    public let bytesRead: Int

    public subscript(key: String) -> GGUFValue? { metadata[key] }

    public func string(_ key: String) -> String? { metadata[key]?.stringValue }
    public func int(_ key: String) -> Int? { metadata[key]?.intValue }
    public func double(_ key: String) -> Double? { metadata[key]?.doubleValue }
    public func bool(_ key: String) -> Bool? { metadata[key]?.boolValue }

    /// Metadata keys, sorted, for `jxcode model-info` output.
    public var sortedKeys: [String] { metadata.keys.sorted() }

    public var sortedSkippedKeys: [String] { skippedKeys.sorted() }
}

// MARK: - Byte reader

/// A minimal buffered forward-only reader over a `FileHandle`.
///
/// Forward-only is not a limitation here: GGUF is a sequential format and the
/// parser never needs to seek backwards. Having no seek means the buffer can be
/// a plain ring-free `[UInt8]` with a cursor, which keeps the hot path — walking
/// past a 150,000-element string array — to an array index and a compare.
final class GGUFByteReader {
    private let handle: FileHandle
    private let chunkSize: Int
    private var buffer: [UInt8] = []
    private var cursor: Int = 0
    private var reachedEOF = false

    /// Total bytes handed out. The parser uses this for its header ceiling.
    private(set) var consumed: Int = 0

    init(handle: FileHandle, chunkSize: Int = 1 << 18) {
        self.handle = handle
        self.chunkSize = chunkSize
    }

    private func refill() throws {
        guard cursor >= buffer.count else { return }
        buffer.removeAll(keepingCapacity: true)
        cursor = 0
        let data = try handle.read(upToCount: chunkSize) ?? Data()
        if data.isEmpty {
            reachedEOF = true
            return
        }
        buffer.append(contentsOf: data)
    }

    private func ensureAvailable() throws {
        if cursor >= buffer.count {
            try refill()
        }
        if cursor >= buffer.count {
            throw GGUFError.truncated(expected: 1, at: consumed)
        }
    }

    func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0 else { throw GGUFError.corrupt("negative length") }
        if count == 0 { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(count)
        var remaining = count
        while remaining > 0 {
            try ensureAvailable()
            let available = min(remaining, buffer.count - cursor)
            out.append(contentsOf: buffer[cursor..<(cursor + available)])
            cursor += available
            consumed += available
            remaining -= available
        }
        return out
    }

    /// Advance without allocating. This is what makes walking a token array cheap.
    func skipBytes(_ count: Int) throws {
        guard count >= 0 else { throw GGUFError.corrupt("negative skip") }
        if count == 0 { return }
        var remaining = count

        // Anything already buffered is free to step over.
        let buffered = min(remaining, buffer.count - cursor)
        cursor += buffered
        consumed += buffered
        remaining -= buffered

        // Beyond the buffer, seek rather than read: the bytes are being
        // discarded, so there is no reason to pull them through memory.
        //
        // This is only correct because the branch above consumed the *entire*
        // remaining buffer: `buffered` is `min(remaining, buffer.count - cursor)`
        // and we are here only when `remaining` exceeded it, so `cursor` is now
        // `buffer.count` and the OS file offset finally equals the logical
        // offset. Seeking from `handle.offset()` while the buffer still held
        // unread bytes would jump too far forward, because the file handle is
        // already positioned at the end of the chunk we prefetched.
        if remaining > 0 {
            let position = try handle.offset()
            try handle.seek(toOffset: position + UInt64(remaining))
            consumed += remaining
            reachedEOF = false
            buffer.removeAll(keepingCapacity: true)
            cursor = 0
        }
    }

    // MARK: Integer reads
    //
    // Each of these has a fast path that reads straight out of `buffer` and a
    // slow path that goes through `readBytes`. The fast path exists because of a
    // measured problem: walking `tokenizer.ggml.tokens` means ~150,000 calls to
    // `readUInt64`, and the allocating version spent 0.64s per model doing
    // nothing but building throwaway `[UInt8]`s. Reading from the buffer in
    // place takes that under 0.05s, which is the difference between a model
    // library that scans instantly and one that takes ten seconds.

    private func hasBuffered(_ count: Int) -> Bool {
        buffer.count - cursor >= count
    }

    func readUInt8() throws -> UInt8 {
        if hasBuffered(1) {
            let value = buffer[cursor]
            cursor += 1
            consumed += 1
            return value
        }
        return try readBytes(1)[0]
    }

    func readUInt16() throws -> UInt16 {
        if hasBuffered(2) {
            let base = cursor
            cursor += 2
            consumed += 2
            return UInt16(buffer[base]) | UInt16(buffer[base + 1]) << 8
        }
        let b = try readBytes(2)
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }

    func readUInt32() throws -> UInt32 {
        if hasBuffered(4) {
            let base = cursor
            cursor += 4
            consumed += 4
            return UInt32(buffer[base])
                | UInt32(buffer[base + 1]) << 8
                | UInt32(buffer[base + 2]) << 16
                | UInt32(buffer[base + 3]) << 24
        }
        let b = try readBytes(4)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    func readUInt64() throws -> UInt64 {
        if hasBuffered(8) {
            let base = cursor
            cursor += 8
            consumed += 8
            var value: UInt64 = 0
            for index in stride(from: 7, through: 0, by: -1) {
                value = (value << 8) | UInt64(buffer[base + index])
            }
            return value
        }
        let b = try readBytes(8)
        var value: UInt64 = 0
        for index in stride(from: 7, through: 0, by: -1) {
            value = (value << 8) | UInt64(b[index])
        }
        return value
    }

    func readInt8() throws -> Int8 { Int8(bitPattern: try readUInt8()) }
    func readInt16() throws -> Int16 { Int16(bitPattern: try readUInt16()) }
    func readInt32() throws -> Int32 { Int32(bitPattern: try readUInt32()) }
    func readInt64() throws -> Int64 { Int64(bitPattern: try readUInt64()) }

    func readFloat32() throws -> Float { Float(bitPattern: try readUInt32()) }
    func readFloat64() throws -> Double { Double(bitPattern: try readUInt64()) }
}

// MARK: - Parser

public enum GGUFReader {

    /// Parse the metadata header of a GGUF file.
    ///
    /// Only the header is read; tensor data is never touched. On the 8.9 GB
    /// model in `~/Models` this reads roughly 11 KB.
    public static func readHeader(
        at url: URL,
        options: GGUFReadOptions = .default
    ) throws -> GGUFHeader {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try readHeader(from: handle, options: options)
    }

    static func readHeader(
        from handle: FileHandle,
        options: GGUFReadOptions = .default
    ) throws -> GGUFHeader {
        let reader = GGUFByteReader(handle: handle)

        let magic = try reader.readUInt32()
        guard magic == 0x4655_4747 else { throw GGUFError.badMagic(magic) }

        let version = try reader.readUInt32()
        guard version == 2 || version == 3 else {
            throw GGUFError.unsupportedVersion(version)
        }

        let tensorCount = try reader.readUInt64()
        let metadataCount = try reader.readUInt64()

        // A 9 GB model has a few hundred tensors and a few dozen metadata keys.
        // Anything wildly beyond that is a corrupt or hostile header, and
        // trusting it means looping for a very long time.
        guard metadataCount <= 100_000 else {
            throw GGUFError.tooLarge("header claims \(metadataCount) metadata entries")
        }
        guard tensorCount <= 10_000_000 else {
            throw GGUFError.tooLarge("header claims \(tensorCount) tensors")
        }

        var metadata: [String: GGUFValue] = [:]
        metadata.reserveCapacity(Int(min(metadataCount, 512)))
        var skippedKeys: Set<String> = []
        var arrayLengths: [String: UInt64] = [:]

        for index in 0..<metadataCount {
            if reader.consumed > options.maxHeaderBytes {
                throw GGUFError.tooLarge(
                    "header exceeded \(options.maxHeaderBytes) bytes after \(index) of \(metadataCount) entries"
                )
            }

            let key = try readString(reader)
            let rawType = try reader.readUInt32()
            guard let type = GGUFType(rawValue: rawType) else {
                throw GGUFError.corrupt("unknown value type \(rawType) for key \"\(key)\"")
            }

            var arrayCount: UInt64?

            if options.skipKeys.contains(key) {
                try skipValue(reader, type: type, options: options, arrayCount: &arrayCount)
                skippedKeys.insert(key)
                if let arrayCount { arrayLengths[key] = arrayCount }
                continue
            }

            // `nil` means "present in the file, deliberately not loaded". The
            // key is recorded so callers can still report that it exists.
            if let value = try readValue(
                reader,
                type: type,
                options: options,
                arrayCount: &arrayCount
            ) {
                metadata[key] = value
            } else {
                skippedKeys.insert(key)
            }
            if let arrayCount { arrayLengths[key] = arrayCount }
        }

        return GGUFHeader(
            version: version,
            tensorCount: tensorCount,
            metadataCount: metadataCount,
            metadata: metadata,
            skippedKeys: skippedKeys,
            arrayLengths: arrayLengths,
            bytesRead: reader.consumed
        )
    }

    // MARK: Strings

    private static func readString(_ reader: GGUFByteReader) throws -> String {
        let length = try reader.readUInt64()
        guard length <= 64 << 20 else {
            throw GGUFError.corrupt("string length \(length) is implausible")
        }
        let bytes = try reader.readBytes(Int(length))
        // A GGUF key or value that is not valid UTF-8 is corrupt rather than
        // merely unusual, so this is strict on purpose.
        guard let string = String(bytes: bytes, encoding: .utf8) else {
            throw GGUFError.corrupt("string of \(length) bytes was not valid UTF-8")
        }
        return string
    }

    // MARK: Values

    /// Reads one value. Returns `nil` when the value is present but too large to
    /// be worth materialising — the caller records the key as skipped rather
    /// than inventing an empty array for it.
    ///
    /// `arrayCount` is set whenever the value turned out to be an array, whether
    /// or not its elements were loaded. The distinction earns its keep: the
    /// length of `tokenizer.ggml.tokens` *is* the model's vocabulary size, and
    /// throwing that away because 150,000 strings were not worth allocating
    /// would discard a fact the header already told us. Only one of the six
    /// models on this machine carries an explicit `<arch>.vocab_size`, so this
    /// is the reliable source rather than a nicety.
    private static func readValue(
        _ reader: GGUFByteReader,
        type: GGUFType,
        options: GGUFReadOptions,
        arrayCount: inout UInt64?
    ) throws -> GGUFValue? {
        switch type {
        case .uint8:   return .unsigned(UInt64(try reader.readUInt8()))
        case .uint16:  return .unsigned(UInt64(try reader.readUInt16()))
        case .uint32:  return .unsigned(UInt64(try reader.readUInt32()))
        case .uint64:  return .unsigned(try reader.readUInt64())
        case .int8:    return .signed(Int64(try reader.readInt8()))
        case .int16:   return .signed(Int64(try reader.readInt16()))
        case .int32:   return .signed(Int64(try reader.readInt32()))
        case .int64:   return .signed(try reader.readInt64())
        case .float32: return .floating(Double(try reader.readFloat32()))
        case .float64: return .floating(try reader.readFloat64())
        case .bool:    return .boolean(try reader.readUInt8() != 0)
        case .string:  return .string(try readString(reader))

        case .array:
            let elementRaw = try reader.readUInt32()
            guard let elementType = GGUFType(rawValue: elementRaw) else {
                throw GGUFError.corrupt("unknown array element type \(elementRaw)")
            }
            let count = try reader.readUInt64()
            arrayCount = count

            // Nested arrays are legal in the format but never emitted by
            // llama.cpp, and nothing here needs them. Skipping wholesale avoids
            // inventing semantics for a case that does not occur.
            if elementType == .array {
                try skipArrayElements(reader, type: elementType, count: count, options: options)
                return nil
            }

            // The decisive branch. A token array is 150,000 strings; walking it
            // without allocating is milliseconds, materialising it is hundreds
            // of megabytes. Keep the stream position, drop the contents.
            if count > UInt64(options.maxMaterializedArrayElements) {
                try skipArrayElements(reader, type: elementType, count: count, options: options)
                return nil
            }

            var elements: [GGUFValue] = []
            elements.reserveCapacity(Int(count))
            for _ in 0..<count {
                // A nested array is the only case that recurses here, and the
                // inner count belongs to the inner array, not to this one.
                var ignored: UInt64?
                guard let element = try readValue(
                    reader,
                    type: elementType,
                    options: options,
                    arrayCount: &ignored
                ) else {
                    throw GGUFError.corrupt("array element could not be read")
                }
                elements.append(element)
            }
            return .array(elements)
        }
    }

    // MARK: Skipping

    private static func skipValue(
        _ reader: GGUFByteReader,
        type: GGUFType,
        options: GGUFReadOptions,
        arrayCount: inout UInt64?
    ) throws {
        if let width = type.fixedWidth {
            try reader.skipBytes(width)
            return
        }
        switch type {
        case .string:
            let length = try reader.readUInt64()
            guard length <= 64 << 20 else {
                throw GGUFError.corrupt("string length \(length) is implausible")
            }
            try reader.skipBytes(Int(length))
        case .array:
            let elementRaw = try reader.readUInt32()
            guard let elementType = GGUFType(rawValue: elementRaw) else {
                throw GGUFError.corrupt("unknown array element type \(elementRaw)")
            }
            let count = try reader.readUInt64()
            arrayCount = count
            try skipArrayElements(reader, type: elementType, count: count, options: options)
        default:
            throw GGUFError.corrupt("unhandled skip for type \(type)")
        }
    }

    /// How deep nested arrays may go before the reader refuses them.
    ///
    /// llama.cpp emits none, so any depth at all is a hand-built file — and
    /// each level costs a stack frame, twelve bytes of header buys one, and the
    /// byte budget is only checked between metadata entries. A megabyte of
    /// nothing but nested array headers was enough to overflow the stack
    /// outright.
    private static let maxArrayNesting = 8

    private static func skipArrayElements(
        _ reader: GGUFByteReader,
        type: GGUFType,
        count: UInt64,
        options: GGUFReadOptions,
        depth: Int = 0
    ) throws {
        guard depth <= maxArrayNesting else {
            throw GGUFError.corrupt(
                "nested arrays more than \(maxArrayNesting) deep; llama.cpp emits none"
            )
        }
        // Fixed-width arrays can be jumped in one seek — this is the common case
        // for `tokenizer.ggml.scores` and `tokenizer.ggml.token_type`.
        if let width = type.fixedWidth {
            let total = count.multipliedReportingOverflow(by: UInt64(width))
            guard !total.overflow, total.partialValue <= UInt64(Int.max) else {
                throw GGUFError.tooLarge("array of \(count) × \(width) bytes overflows")
            }
            try reader.skipBytes(Int(total.partialValue))
            return
        }

        switch type {
        case .string:
            // Variable-length, so each element has to be walked. But only the
            // 8-byte length prefix is read; the bytes themselves are skipped.
            for _ in 0..<count {
                let length = try reader.readUInt64()
                guard length <= 64 << 20 else {
                    throw GGUFError.corrupt("string length \(length) is implausible")
                }
                try reader.skipBytes(Int(length))
            }
        case .array:
            // Nested arrays are legal but never used by llama.cpp metadata, and
            // every level is another frame — hence the depth, which is the only
            // thing here that recursion can grow without bound.
            for _ in 0..<count {
                let elementRaw = try reader.readUInt32()
                guard let elementType = GGUFType(rawValue: elementRaw) else {
                    throw GGUFError.corrupt("unknown nested array element type \(elementRaw)")
                }
                let inner = try reader.readUInt64()
                try skipArrayElements(
                    reader,
                    type: elementType,
                    count: inner,
                    options: options,
                    depth: depth + 1
                )
            }
        default:
            throw GGUFError.corrupt("cannot skip array of \(type)")
        }
    }
}
