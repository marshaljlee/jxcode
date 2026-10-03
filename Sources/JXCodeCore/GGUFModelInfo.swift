import Foundation

// MARK: - Interpreting a GGUF header
//
// `GGUFReader` returns the raw key/value store. This layer turns it into the
// facts the rest of the app reasons about: how big the context is, how many
// layers there are, whether this is a language model or a vision projector, and
// what quantisation it uses.
//
// The awkward part is that llama.cpp namespaces its metadata under the
// architecture string. A Llama file stores `llama.context_length`; a Qwen file
// stores `qwen2.context_length`. So the architecture has to be read first and
// every other lookup is prefixed with it. Getting this wrong is the classic
// GGUF integration bug: the keys look absent, and a model with a 128k context
// gets served with the 4096 default.

/// `Codable` so a scan result can be cached in `state/models.json`. Reading a
/// model card costs ~0.4s on an 9 GB file, which is fine once and annoying on
/// every launch.
public struct GGUFModelInfo: Sendable, Codable, Equatable {
    public let architecture: String?
    public let name: String?
    public let sizeLabel: String?
    public let contextLength: Int?
    public let blockCount: Int?
    public let embeddingLength: Int?
    public let headCount: Int?
    public let headCountKV: Int?
    /// Per-head dimension for keys. Falls back to `embeddingLength / headCount`.
    public let keyLength: Int?
    public let valueLength: Int?
    public let ropeFreqBase: Double?
    public let expertCount: Int?
    public let parameterCount: Int?
    /// Vocabulary size, which is the most reliable way to tell apart models
    /// that share an architecture string. `llama` covers both Llama 2 and
    /// Llama 3, and those two need different chat templates; 32000 versus
    /// 128256 is what separates them.
    ///
    /// Sourced from the tokenizer array's *length* rather than its contents,
    /// because only one of the six models on this machine writes an explicit
    /// `<arch>.vocab_size` while five carry the token array.
    public let vocabularySize: Int?
    public let fileType: GGMLFileType?
    public let chatTemplate: String?
    public let vision: VisionInfo?
    /// Every metadata key seen, sorted. Used by `jxcode model-info` so an
    /// unfamiliar architecture can still be inspected.
    public let allKeys: [String]
    public let tensorCount: UInt64
    public let headerBytesRead: Int

    /// True when this file is a multimodal projector rather than a language
    /// model.
    ///
    /// This is the authoritative test, and it is better than matching filenames:
    /// llama.cpp tags projectors with `general.architecture = "clip"`. Filename
    /// heuristics are only a fallback for files whose metadata will not parse.
    public var isProjector: Bool { architecture == "clip" }

    public var isVisionCapable: Bool { vision?.hasVisionEncoder == true }

    /// Attention head dimension. Explicit when the model declares
    /// `attention.key_length` (needed when it differs from the naive division,
    /// as in some DeepSeek and Qwen variants), otherwise derived.
    public var headDimension: Int? {
        if let keyLength, keyLength > 0 { return keyLength }
        guard let embeddingLength, let headCount, headCount > 0 else { return nil }
        return embeddingLength / headCount
    }

    /// The dimension used for the value cache, which can differ from the key
    /// dimension in models that use MLA-style attention.
    public var valueDimension: Int? {
        if let valueLength, valueLength > 0 { return valueLength }
        return headDimension
    }

    /// Grouped-query attention means KV heads are fewer than query heads. When a
    /// model does not declare it, it is not using GQA and the counts are equal.
    public var resolvedKVHeadCount: Int? {
        if let headCountKV, headCountKV > 0 { return headCountKV }
        return headCount
    }

    /// Bytes of KV cache per token, for both K and V, at a given element size.
    ///
    ///     layers × kv_heads × head_dim × 2 (K and V) × bytes_per_element
    ///
    /// This single number is what decides whether a long context fits in memory,
    /// so it is worth having in one place with the formula written down.
    public func kvBytesPerToken(bytesPerElement: Double) -> Double? {
        guard let blockCount, let kvHeads = resolvedKVHeadCount,
              let keyDim = headDimension, let valueDim = valueDimension else { return nil }
        let perLayer = Double(kvHeads) * (Double(keyDim) + Double(valueDim))
        return Double(blockCount) * perLayer * bytesPerElement
    }

    public init(header: GGUFHeader) {
        let metadata = header.metadata
        self.allKeys = header.sortedKeys
        self.tensorCount = header.tensorCount
        self.headerBytesRead = header.bytesRead

        let architecture = metadata["general.architecture"]?.stringValue
        self.architecture = architecture
        self.name = metadata["general.name"]?.stringValue
        self.sizeLabel = metadata["general.size_label"]?.stringValue
        self.parameterCount = metadata["general.parameter_count"]?.intValue

        if let raw = metadata["general.file_type"]?.intValue {
            self.fileType = GGMLFileType(rawValue: raw)
        } else {
            self.fileType = nil
        }

        self.chatTemplate = metadata["tokenizer.chat_template"]?.stringValue

        // Prefer the token array's length, since it is present far more often
        // than an explicit vocab_size key. Clamp rather than trap: a corrupt
        // header could claim an absurd count, and a wrong vocabulary size is a
        // much better outcome than a crash.
        if let count = header.arrayLengths["tokenizer.ggml.tokens"] {
            self.vocabularySize = Int(clamping: count)
        } else {
            self.vocabularySize = metadata
                .first { $0.key.hasSuffix(".vocab_size") }?
                .value.intValue
        }

        // Every architecture-scoped lookup goes through this prefix. Without it
        // the keys appear missing and the model gets llama.cpp's small defaults.
        let prefix = architecture.map { "\($0)." }

        func scoped(_ suffix: String) -> GGUFValue? {
            guard let prefix else { return nil }
            return metadata[prefix + suffix]
        }

        self.contextLength = scoped("context_length")?.intValue
        self.blockCount = scoped("block_count")?.intValue
        self.embeddingLength = scoped("embedding_length")?.intValue
        self.headCount = scoped("attention.head_count")?.intValue
        self.headCountKV = scoped("attention.head_count_kv")?.intValue
        self.keyLength = scoped("attention.key_length")?.intValue
        self.valueLength = scoped("attention.value_length")?.intValue
        self.ropeFreqBase = scoped("rope.freq_base")?.doubleValue
        self.expertCount = scoped("expert_count")?.intValue

        self.vision = VisionInfo(metadata: metadata, architecture: architecture)
    }

    // MARK: - Vision projector details

    public struct VisionInfo: Sendable, Codable, Equatable {
        public let hasVisionEncoder: Bool
        public let hasAudioEncoder: Bool
        public let projectorType: String?
        public let imageSize: Int?
        public let patchSize: Int?
        public let embeddingLength: Int?
        public let projectionDim: Int?
        public let blockCount: Int?
        public let headCount: Int?

        init(metadata: [String: GGUFValue], architecture: String?) {
            self.hasVisionEncoder = metadata["clip.has_vision_encoder"]?.boolValue ?? false
            self.hasAudioEncoder = metadata["clip.has_audio_encoder"]?.boolValue ?? false
            self.projectorType = metadata["clip.projector_type"]?.stringValue
            self.imageSize = metadata["clip.vision.image_size"]?.intValue
            self.patchSize = metadata["clip.vision.patch_size"]?.intValue
            self.embeddingLength = metadata["clip.vision.embedding_length"]?.intValue
            self.projectionDim = metadata["clip.vision.projection_dim"]?.intValue
            self.blockCount = metadata["clip.vision.block_count"]?.intValue
            self.headCount = metadata["clip.vision.attention.head_count"]?.intValue
        }
    }
}

// MARK: - Quantisation

/// `general.file_type`. The raw values are llama.cpp's `ggml_ftype` enum and are
/// part of the file format, so they must not be reordered.
public enum GGMLFileType: Int, Sendable, Codable, CaseIterable {
    case allF32       = 0
    case mostlyF16    = 1
    case mostlyQ4_0   = 2
    case mostlyQ4_1   = 3
    case mostlyQ8_0   = 7
    case mostlyQ5_0   = 8
    case mostlyQ5_1   = 9
    case mostlyQ2_K   = 10
    case mostlyQ3_K_S = 11
    case mostlyQ3_K_M = 12
    case mostlyQ3_K_L = 13
    case mostlyQ4_K_S = 14
    case mostlyQ4_K_M = 15
    case mostlyQ5_K_S = 16
    case mostlyQ5_K_M = 17
    case mostlyQ6_K   = 18
    case mostlyIQ2_XXS = 19
    case mostlyIQ2_XS  = 20
    case mostlyIQ2_S   = 21
    case mostlyIQ2_M   = 22
    case mostlyIQ3_XXS = 23
    case mostlyIQ3_S   = 24
    case mostlyIQ3_M   = 25
    case mostlyIQ1_S   = 26
    case mostlyIQ4_NL  = 27
    case mostlyIQ3_XS  = 28
    case mostlyIQ1_M   = 29
    case mostlyBF16   = 30
    case mostlyQ4_0_4_4 = 31
    case mostlyQ4_0_4_8 = 32
    case mostlyQ4_0_8_8 = 33
    case mostlyTQ1_0  = 34
    case mostlyTQ2_0  = 35
    case mostlyIQ4_XS = 36

    /// The label people actually use, as it appears in model filenames.
    public var label: String {
        switch self {
        case .allF32:       return "F32"
        case .mostlyF16:    return "F16"
        case .mostlyBF16:   return "BF16"
        case .mostlyQ4_0:   return "Q4_0"
        case .mostlyQ4_1:   return "Q4_1"
        case .mostlyQ5_0:   return "Q5_0"
        case .mostlyQ5_1:   return "Q5_1"
        case .mostlyQ8_0:   return "Q8_0"
        case .mostlyQ2_K:   return "Q2_K"
        case .mostlyQ3_K_S: return "Q3_K_S"
        case .mostlyQ3_K_M: return "Q3_K_M"
        case .mostlyQ3_K_L: return "Q3_K_L"
        case .mostlyQ4_K_S: return "Q4_K_S"
        case .mostlyQ4_K_M: return "Q4_K_M"
        case .mostlyQ5_K_S: return "Q5_K_S"
        case .mostlyQ5_K_M: return "Q5_K_M"
        case .mostlyQ6_K:   return "Q6_K"
        case .mostlyIQ1_S:  return "IQ1_S"
        case .mostlyIQ1_M:  return "IQ1_M"
        case .mostlyIQ2_XXS: return "IQ2_XXS"
        case .mostlyIQ2_XS:  return "IQ2_XS"
        case .mostlyIQ2_S:   return "IQ2_S"
        case .mostlyIQ2_M:   return "IQ2_M"
        case .mostlyIQ3_XXS: return "IQ3_XXS"
        case .mostlyIQ3_XS:  return "IQ3_XS"
        case .mostlyIQ3_S:   return "IQ3_S"
        case .mostlyIQ3_M:   return "IQ3_M"
        case .mostlyIQ4_NL:  return "IQ4_NL"
        case .mostlyIQ4_XS:  return "IQ4_XS"
        case .mostlyQ4_0_4_4: return "Q4_0_4_4"
        case .mostlyQ4_0_4_8: return "Q4_0_4_8"
        case .mostlyQ4_0_8_8: return "Q4_0_8_8"
        case .mostlyTQ1_0:   return "TQ1_0"
        case .mostlyTQ2_0:   return "TQ2_0"
        }
    }

    /// Bits per weight, including the per-block scale overhead.
    ///
    /// The `_K` and `IQ` families store a scale and a min per block, which is why
    /// their effective size is above the nominal bit count. These are the
    /// published figures llama.cpp uses when it reports model size.
    public var bitsPerWeight: Double {
        switch self {
        case .allF32:        return 32
        case .mostlyF16:     return 16
        case .mostlyBF16:    return 16
        case .mostlyQ4_0:    return 4.5
        case .mostlyQ4_1:    return 5.0
        case .mostlyQ5_0:    return 5.5
        case .mostlyQ5_1:    return 6.0
        case .mostlyQ8_0:    return 8.5
        case .mostlyQ2_K:    return 2.5625
        case .mostlyQ3_K_S:  return 3.4375
        case .mostlyQ3_K_M:  return 3.875
        case .mostlyQ3_K_L:  return 4.25
        case .mostlyQ4_K_S:  return 4.5
        case .mostlyQ4_K_M:  return 4.85
        case .mostlyQ5_K_S:  return 5.5
        case .mostlyQ5_K_M:  return 5.75
        case .mostlyQ6_K:    return 6.5625
        case .mostlyIQ1_S:   return 1.5625
        case .mostlyIQ1_M:   return 1.75
        case .mostlyIQ2_XXS: return 2.0625
        case .mostlyIQ2_XS:  return 2.3125
        case .mostlyIQ2_S:   return 2.5
        case .mostlyIQ2_M:   return 2.7
        case .mostlyIQ3_XXS: return 3.0625
        case .mostlyIQ3_XS:  return 3.3125
        case .mostlyIQ3_S:   return 3.4375
        case .mostlyIQ3_M:   return 3.625
        case .mostlyIQ4_NL:  return 4.5
        case .mostlyIQ4_XS:  return 4.25
        case .mostlyQ4_0_4_4: return 4.5
        case .mostlyQ4_0_4_8: return 4.5
        case .mostlyQ4_0_8_8: return 4.5
        case .mostlyTQ1_0:   return 1.6875
        case .mostlyTQ2_0:   return 2.0625
        }
    }
}

// MARK: - KV cache element types

/// The element type used for the KV cache (`--cache-type-k` / `--cache-type-v`).
///
/// Quantising the cache is the single most effective way to fit a long context
/// into a fixed memory budget: it costs a small amount of quality and saves
/// roughly half to three-quarters of the cache. The sizes below are bytes per
/// element including block overhead, which is why q8_0 is 1.0625 rather than 1.
public enum KVCacheType: String, Sendable, Codable, CaseIterable {
    case f32
    case f16
    case bf16
    case q8_0
    case q5_1
    case q5_0
    case q4_1
    case q4_0

    public var bytesPerElement: Double {
        switch self {
        case .f32:  return 4
        case .f16:  return 2
        case .bf16: return 2
        // 34 bytes per 32 elements (32 × 8-bit quants + one 16-bit scale).
        case .q8_0: return 34.0 / 32.0
        // 24 bytes per 32 (quants + scale + min).
        case .q5_1: return 24.0 / 32.0
        case .q5_0: return 22.0 / 32.0
        case .q4_1: return 20.0 / 32.0
        case .q4_0: return 18.0 / 32.0
        }
    }

    /// Whether llama.cpp supports this type for the *value* cache. The original
    /// quantised-cache implementation only allowed K to be quantised, and V had
    /// to match. Flash attention lifted that restriction, so the planner only
    /// offers quantised V when flash attention is on.
    public var isQuantised: Bool { self != .f32 && self != .f16 && self != .bf16 }
}
