import XCTest
@testable import JXCodeCore

final class GGUFReaderTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gguf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ builder: GGUFFixtureBuilder, name: String = "fixture.gguf") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try builder.write(to: url)
        return url
    }

    // MARK: - Header

    func testReadsMagicVersionAndCounts() throws {
        let url = try write(GGUFFixtureBuilder(version: 3, tensorCount: 427)
            .with("general.architecture", "llama"))

        let header = try GGUFReader.readHeader(at: url)

        XCTAssertEqual(header.version, 3)
        XCTAssertEqual(header.tensorCount, 427)
        XCTAssertEqual(header.metadataCount, 1)
    }

    func testRejectsNonGGUFMagic() throws {
        let url = directory.appendingPathComponent("not-gguf.gguf")
        try Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00, 0x00, 0x00]).write(to: url)

        XCTAssertThrowsError(try GGUFReader.readHeader(at: url)) { error in
            guard case GGUFError.badMagic = error else {
                return XCTFail("expected badMagic, got \(error)")
            }
            // A zip file starts with "PK\x03\x04"; the message should say so
            // rather than printing raw bytes.
            XCTAssertTrue("\(error)".contains("PK"), "message was \(error)")
        }
    }

    func testRejectsVersionOne() throws {
        let url = try write(GGUFFixtureBuilder(version: 1).with("general.architecture", "llama"))

        XCTAssertThrowsError(try GGUFReader.readHeader(at: url)) { error in
            guard case GGUFError.unsupportedVersion(let version) = error else {
                return XCTFail("expected unsupportedVersion, got \(error)")
            }
            XCTAssertEqual(version, 1)
        }
    }

    // MARK: - Scalars

    func testReadsEveryScalarType() throws {
        let url = try write(GGUFFixtureBuilder()
            .with("a.unsigned", 42)
            .with("b.floating", 10_000.0)
            .with("c.boolean", true)
            .with("d.string", "hello")
            .with("e.negative", -7))

        let header = try GGUFReader.readHeader(at: url)

        XCTAssertEqual(header.int("a.unsigned"), 42)
        XCTAssertEqual(header.double("b.floating"), 10_000.0)
        XCTAssertEqual(header.bool("c.boolean"), true)
        XCTAssertEqual(header.string("d.string"), "hello")
        XCTAssertEqual(header.int("e.negative"), -7)
    }

    func testStringsAreNotNullTerminated() throws {
        // The classic GGUF parsing mistake is assuming a C string. If the reader
        // expected a terminator, the following key would be consumed as part of
        // this value and everything after it would be garbage.
        let url = try write(GGUFFixtureBuilder()
            .with("first", "abc")
            .with("second", "def"))

        let header = try GGUFReader.readHeader(at: url)

        XCTAssertEqual(header.string("first"), "abc")
        XCTAssertEqual(header.string("second"), "def")
        XCTAssertEqual(header.metadata.count, 2)
    }

    func testReadsEmptyString() throws {
        let url = try write(GGUFFixtureBuilder().with("empty", ""))

        let header = try GGUFReader.readHeader(at: url)

        XCTAssertEqual(header.string("empty"), "")
    }

    func testReadsUnicodeString() throws {
        let template = "{% for m in messages %}用户：{{ m.content }}\n{% endfor %}"
        let url = try write(GGUFFixtureBuilder().with("tokenizer.chat_template", template))

        let header = try GGUFReader.readHeader(at: url)

        // Length is a byte count, not a character count, so a multi-byte string
        // is the case that catches a reader that confuses the two.
        XCTAssertEqual(header.string("tokenizer.chat_template"), template)
    }

    func testReadsArrays() throws {
        let url = try write(GGUFFixtureBuilder()
            .with("clip.vision.image_mean", array: [.floating(0.5), .floating(0.5), .floating(0.5)])
            .with("tags", array: [.string("a"), .string("b")]))

        let header = try GGUFReader.readHeader(at: url)

        XCTAssertEqual(header["clip.vision.image_mean"]?.arrayValue?.count, 3)
        XCTAssertEqual(header["clip.vision.image_mean"]?.arrayValue?.first?.doubleValue, 0.5)
        XCTAssertEqual(header["tags"]?.arrayValue?.compactMap(\.stringValue), ["a", "b"])
    }

    // MARK: - Skipping large arrays

    func testSkippingALargeStringArrayLandsOnTheNextKey() throws {
        // This is the load-bearing test for the skip path. A real model has a
        // 150,000-element `tokenizer.ggml.tokens`; if skipping it miscomputes a
        // single byte, every key after it decodes as garbage. So the fixture
        // puts a big array in the *middle* and asserts the key after it.
        let tokens = (0..<5_000).map { GGUFValue.string("<|token-\($0)|>") }
        let url = try write(GGUFFixtureBuilder()
            .with("before", "kept")
            .with("tokenizer.ggml.tokens", array: tokens)
            .with("after", "also-kept"))

        let header = try GGUFReader.readHeader(at: url)

        XCTAssertEqual(header.string("before"), "kept")
        XCTAssertEqual(header.string("after"), "also-kept")
        // The array is traversed but deliberately not loaded. It must be *absent*
        // rather than an empty array: `.array([])` would claim the array has zero
        // elements when it has 5,000, and a caller could reasonably believe it.
        XCTAssertNil(header["tokenizer.ggml.tokens"])
        XCTAssertTrue(header.skippedKeys.contains("tokenizer.ggml.tokens"))
    }

    func testSkippedKeysAreReportedSoCallersKnowTheyExist() throws {
        let tokens = (0..<5_000).map { GGUFValue.string("<|t\($0)|>") }
        let url = try write(GGUFFixtureBuilder()
            .with("tokenizer.ggml.tokens", array: tokens)
            .with("general.architecture", "llama"))

        let header = try GGUFReader.readHeader(at: url)

        // The key is not in `metadata`, but it is not lost either — the CLI can
        // still tell the user the tokeniser is there.
        XCTAssertEqual(header.sortedSkippedKeys, ["tokenizer.ggml.tokens"])
        XCTAssertFalse(header.sortedKeys.contains("tokenizer.ggml.tokens"))
    }

    func testSkippingALargeFixedWidthArrayLandsOnTheNextKey() throws {
        let scores = (0..<50_000).map { GGUFValue.floating(Double($0)) }
        let url = try write(GGUFFixtureBuilder()
            .with("tokenizer.ggml.scores", array: scores)
            .with("after", "kept"))

        let header = try GGUFReader.readHeader(at: url)

        XCTAssertEqual(header.string("after"), "kept")
    }

    func testSmallArraysAreMaterialisedEvenWhenSkippingIsPossible() throws {
        // The threshold must not swallow genuinely useful metadata.
        let url = try write(GGUFFixtureBuilder()
            .with("general.tags", array: [.string("roleplay"), .string("abliterated")]))

        let header = try GGUFReader.readHeader(at: url)

        XCTAssertEqual(
            header["general.tags"]?.arrayValue?.compactMap(\.stringValue),
            ["roleplay", "abliterated"]
        )
    }

    func testHeavyKeysAreSkippedEvenWhenSmallEnoughToMaterialise() throws {
        // Belt-and-braces: even a short token array is not worth keeping, and
        // the skip list guarantees it never lands in the metadata dictionary.
        var options = GGUFReadOptions()
        options.maxMaterializedArrayElements = 1_000_000

        let url = try write(GGUFFixtureBuilder()
            .with("tokenizer.ggml.merges", array: [.string("a b")])
            .with("after", "kept"))

        let header = try GGUFReader.readHeader(at: url, options: options)

        XCTAssertNil(header["tokenizer.ggml.merges"])
        XCTAssertEqual(header.string("after"), "kept")
    }

    // MARK: - Hostile input

    func testRejectsAbsurdMetadataCount() throws {
        // A corrupt header claiming 2^40 keys would keep the parser busy for a
        // very long time. It must be refused up front.
        var data = Data()
        data.append(contentsOf: Array("GGUF".utf8))
        data.append(contentsOf: [3, 0, 0, 0])                                  // version 3
        data.append(contentsOf: Array(repeating: 0, count: 8))                 // tensor count 0
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0, 0])    // kv count ~2^41

        let url = directory.appendingPathComponent("hostile.gguf")
        try data.write(to: url)

        XCTAssertThrowsError(try GGUFReader.readHeader(at: url)) { error in
            guard case GGUFError.tooLarge = error else {
                return XCTFail("expected tooLarge, got \(error)")
            }
        }
    }

    func testRejectsImplausibleStringLength() throws {
        var data = Data()
        data.append(contentsOf: Array("GGUF".utf8))
        data.append(contentsOf: [3, 0, 0, 0])
        data.append(contentsOf: Array(repeating: 0, count: 8))
        data.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 0])                      // 1 kv pair
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F]) // key length ~2^63

        let url = directory.appendingPathComponent("longkey.gguf")
        try data.write(to: url)

        XCTAssertThrowsError(try GGUFReader.readHeader(at: url))
    }

    func testTruncatedFileIsReportedNotCrashed() throws {
        let full = GGUFFixtureBuilder().with("general.architecture", "llama").build()
        let url = directory.appendingPathComponent("truncated.gguf")
        try full.prefix(full.count - 4).write(to: url)

        XCTAssertThrowsError(try GGUFReader.readHeader(at: url))
    }

    func testUnknownValueTypeIsRejected() throws {
        var data = Data()
        data.append(contentsOf: Array("GGUF".utf8))
        data.append(contentsOf: [3, 0, 0, 0])
        data.append(contentsOf: Array(repeating: 0, count: 8))
        data.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 0])   // 1 kv pair
        data.append(contentsOf: [2, 0, 0, 0, 0, 0, 0, 0])   // key length 2
        data.append(contentsOf: Array("k1".utf8))
        data.append(contentsOf: [0x63, 0, 0, 0])            // type 99, not a GGUF type

        let url = directory.appendingPathComponent("badtype.gguf")
        try data.write(to: url)

        XCTAssertThrowsError(try GGUFReader.readHeader(at: url)) { error in
            guard case GGUFError.corrupt = error else {
                return XCTFail("expected corrupt, got \(error)")
            }
        }
    }

    func testHeaderCeilingStopsAPathologicalFile() throws {
        // A file with a large, honest kv_count but an enormous amount of
        // metadata should stop at the ceiling rather than reading forever.
        // The fixture is ~1 MB against a 32 KB ceiling, which is enough to
        // prove the guard fires without building a 10 MB file to do it.
        var builder = GGUFFixtureBuilder()
        for index in 0..<2_000 {
            builder = builder.with("key.\(index)", String(repeating: "x", count: 512))
        }
        let url = try write(builder)

        var options = GGUFReadOptions()
        options.maxHeaderBytes = 32_000

        XCTAssertThrowsError(try GGUFReader.readHeader(at: url, options: options)) { error in
            guard case GGUFError.tooLarge = error else {
                return XCTFail("expected tooLarge, got \(error)")
            }
        }
    }

    // MARK: - Efficiency

    func testOnlyTheHeaderIsReadFromALargeFile() throws {
        // The reader must not pull tensor data into memory. This fixture appends
        // 4 MB of fake tensor bytes after the metadata; `bytesRead` should be a
        // few hundred bytes, not megabytes.
        var data = GGUFFixtureBuilder(tensorCount: 1)
            .with("general.architecture", "llama")
            .build()
        data.append(Data(repeating: 0xAB, count: 4 << 20))

        let url = directory.appendingPathComponent("large.gguf")
        try data.write(to: url)

        let header = try GGUFReader.readHeader(at: url)

        XCTAssertLessThan(header.bytesRead, 1024)
        XCTAssertEqual(header.string("general.architecture"), "llama")
    }
}

// MARK: - Interpretation

final class GGUFModelInfoTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gguf-info-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func info(_ builder: GGUFFixtureBuilder) throws -> GGUFModelInfo {
        let url = directory.appendingPathComponent("m.gguf")
        try builder.write(to: url)
        return GGUFModelInfo(header: try GGUFReader.readHeader(at: url))
    }

    func testArchitectureScopedKeysAreFound() throws {
        // The classic GGUF integration bug: every geometry key is namespaced
        // under the architecture, so a reader that looks for a bare
        // "context_length" finds nothing and the model is served with a 4096
        // default instead of its real 262144.
        let info = try info(.llama(
            architecture: "qwen35",
            contextLength: 262_144,
            blockCount: 32,
            embeddingLength: 4096,
            headCount: 16,
            headCountKV: 4
        ))

        XCTAssertEqual(info.architecture, "qwen35")
        XCTAssertEqual(info.contextLength, 262_144)
        XCTAssertEqual(info.blockCount, 32)
        XCTAssertEqual(info.embeddingLength, 4096)
        XCTAssertEqual(info.headCount, 16)
        XCTAssertEqual(info.headCountKV, 4)
    }

    func testKeysScopedToTheWrongArchitectureAreNotFound() throws {
        // Proves the lookup is genuinely scoped rather than falling back to a
        // substring match: a `llama.*` key must not satisfy a `qwen2` model.
        let url = directory.appendingPathComponent("mismatch.gguf")
        try GGUFFixtureBuilder()
            .with("general.architecture", "qwen2")
            .with("llama.context_length", 4096)
            .write(to: url)

        let info = GGUFModelInfo(header: try GGUFReader.readHeader(at: url))

        XCTAssertEqual(info.architecture, "qwen2")
        XCTAssertNil(info.contextLength)
    }

    func testHeadDimensionIsDerivedWhenNotDeclared() throws {
        let info = try info(.llama(embeddingLength: 4096, headCount: 16, headCountKV: 4))
        XCTAssertEqual(info.headDimension, 256)
    }

    func testExplicitKeyLengthWinsOverDerivation() throws {
        // Some models declare a key length that is not embedding/heads.
        let url = directory.appendingPathComponent("keylen.gguf")
        try GGUFFixtureBuilder()
            .with("general.architecture", "deepseek2")
            .with("deepseek2.embedding_length", 4096)
            .with("deepseek2.attention.head_count", 32)
            .with("deepseek2.attention.key_length", 192)
            .write(to: url)

        let info = GGUFModelInfo(header: try GGUFReader.readHeader(at: url))

        XCTAssertEqual(info.headDimension, 192)
    }

    func testKvHeadsFallBackToQueryHeadsWithoutGQA() throws {
        let url = directory.appendingPathComponent("nogqa.gguf")
        try GGUFFixtureBuilder()
            .with("general.architecture", "llama")
            .with("llama.block_count", 32)
            .with("llama.embedding_length", 4096)
            .with("llama.attention.head_count", 32)
            .write(to: url)

        let info = GGUFModelInfo(header: try GGUFReader.readHeader(at: url))

        XCTAssertEqual(info.resolvedKVHeadCount, 32)
    }

    func testKvCacheMath() throws {
        // 32 layers × 4 kv heads × (256 key + 256 value) × 2 bytes = 128 KiB
        // per token. This is the number that decides whether a 262144-token
        // context can fit in memory, and the answer for this model is "no".
        let info = try info(.llama(blockCount: 32, embeddingLength: 4096, headCount: 16, headCountKV: 4))

        XCTAssertEqual(info.kvBytesPerToken(bytesPerElement: 2), 131_072)
        XCTAssertEqual(info.kvBytesPerToken(bytesPerElement: 1), 65_536)
    }

    func testProjectorIsIdentifiedByArchitectureNotFilename() throws {
        let info = try info(.clip())

        XCTAssertEqual(info.architecture, "clip")
        XCTAssertTrue(info.isProjector)
        XCTAssertTrue(info.isVisionCapable)
        XCTAssertEqual(info.vision?.projectorType, "mlp")
        XCTAssertEqual(info.vision?.imageSize, 448)
        XCTAssertEqual(info.vision?.patchSize, 14)
    }

    func testLanguageModelIsNotAProjector() throws {
        let info = try info(.llama())
        XCTAssertFalse(info.isProjector)
    }

    func testChatTemplateIsRead() throws {
        let info = try info(.llama(chatTemplate: "{% for m in messages %}{{ m.role }}{% endfor %}"))
        XCTAssertEqual(info.chatTemplate, "{% for m in messages %}{{ m.role }}{% endfor %}")
    }

    func testMissingChatTemplateIsNilRatherThanEmpty() throws {
        // nil and "" mean different things: nil is "no template, use the
        // built-in default", "" is "a template that renders nothing".
        let info = try info(.llama(chatTemplate: nil))
        XCTAssertNil(info.chatTemplate)
    }

    func testFileTypeDecoding() throws {
        XCTAssertEqual(try info(.llama(fileType: .mostlyQ8_0)).fileType, .mostlyQ8_0)
        XCTAssertEqual(try info(.llama(fileType: .mostlyQ4_K_M)).fileType?.label, "Q4_K_M")
        XCTAssertEqual(try info(.llama(fileType: .mostlyQ8_0)).fileType?.bitsPerWeight, 8.5)
    }

    func testUnknownFileTypeIsNil() throws {
        let url = directory.appendingPathComponent("weird.gguf")
        try GGUFFixtureBuilder()
            .with("general.architecture", "llama")
            .with("general.file_type", 999)
            .write(to: url)

        let info = GGUFModelInfo(header: try GGUFReader.readHeader(at: url))
        XCTAssertNil(info.fileType)
    }
}

// MARK: - KV cache types

final class KVCacheTypeTests: XCTestCase {

    func testBytesPerElementIncludesBlockOverhead() {
        // q8_0 stores 32 eight-bit quants plus one 16-bit scale = 34 bytes for
        // 32 elements. Treating it as a flat 1 byte per element understates the
        // cache by 6%, which is the kind of error that turns "fits" into "OOM".
        XCTAssertEqual(KVCacheType.q8_0.bytesPerElement, 34.0 / 32.0, accuracy: 1e-9)
        XCTAssertEqual(KVCacheType.q4_0.bytesPerElement, 18.0 / 32.0, accuracy: 1e-9)
        XCTAssertEqual(KVCacheType.f16.bytesPerElement, 2)
        XCTAssertEqual(KVCacheType.f32.bytesPerElement, 4)
    }

    func testQuantisedDetection() {
        XCTAssertFalse(KVCacheType.f16.isQuantised)
        XCTAssertFalse(KVCacheType.bf16.isQuantised)
        XCTAssertTrue(KVCacheType.q8_0.isQuantised)
        XCTAssertTrue(KVCacheType.q4_0.isQuantised)
    }
}
