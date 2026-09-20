import Foundation

// MARK: - Choosing how to run a model
//
// "Auto optimisation for each different LLM model" sounds like a tuning knob,
// but on this hardware it is a hard requirement. The models in `~/Models` are
// not unusual, and one of them has this geometry:
//
//     32 layers × 4 KV heads × (256 key + 256 value) × 2 bytes = 128 KiB/token
//
// At its full 262144-token context that is **34 GB of KV cache**, before any
// weights. Run it with llama.cpp's defaults and it does not start; run it with a
// generous context and the machine swaps, which is far worse than not starting.
// So the context length, the cache precision, and the layer offload all have to
// be derived from the model's own metadata and the memory actually available.
//
// The policy, in one sentence: **buy context length with cache precision before
// giving up context.** This is an agent workspace — Claude Code and its peers
// send enormous prompts and expect a large window — so a 128k context with a
// q8_0 cache beats a 32k context with an f16 one. The search below reflects
// that: it walks the context ladder from longest to shortest, and only reaches
// for a coarser cache once the current context cannot be made to fit.

/// One llama.cpp argument, with the reasoning attached.
///
/// Flags are kept structured rather than pre-rendered because the spelling of
/// some of them has changed between llama.cpp releases (`-fa` grew an optional
/// value). A renderer that knows which build it is talking to can adjust, and
/// the UI can show *why* a flag was chosen, which is the difference between a
/// tool that is magic and one that is trustworthy.
public struct LlamaArgument: Sendable, Codable, Equatable {
    public enum Category: String, Sendable, Codable, CaseIterable {
        case model
        case multimodal
        case template
        case context
        case memory
        case performance
        case sampling
        case server
    }

    public let flag: String
    public let value: String?
    public let reason: String
    public let category: Category

    public init(flag: String, value: String? = nil, reason: String, category: Category) {
        self.flag = flag
        self.value = value
        self.reason = reason
        self.category = category
    }

    public var rendered: String {
        value.map { "\(flag) \($0)" } ?? flag
    }
}

/// How much of the machine a model is allowed to take.
public enum MemoryPolicy: String, Sendable, Codable, CaseIterable {
    /// Fit inside 55% of physical memory. The default, because a plan that fits
    /// but leaves macOS nothing does not work in practice — it swaps, and
    /// swapping during generation is worse than a shorter context.
    case safe
    /// Fit inside 70%.
    case balanced
    /// Fit inside 80%. macOS refuses GPU allocations past roughly 75% by
    /// default, so this is the most a local model can take at all.
    case maximal

    public var fraction: Double {
        switch self {
        case .safe:     return 0.55
        case .balanced: return 0.70
        case .maximal:  return 0.80
        }
    }

    public func budget(for hardware: HardwareProfile) -> UInt64 {
        UInt64(Double(hardware.physicalMemory) * fraction)
    }
}

/// How much cache precision may be spent to buy context length.
///
/// This is the most consequential trade-off in the whole planner, and it is a
/// genuine judgement call rather than a calculation. A quantised KV cache is
/// near-lossless at q8_0 and noticeably degrading at q4_0 — long-context
/// reasoning is where it shows first — while a longer context is exactly what
/// agent workloads want. Rather than hardcode one answer, the policy is explicit
/// and the default takes the middle position.
public enum CachePolicy: String, Sendable, Codable, CaseIterable {
    /// Never quantise. Shortest context, best quality.
    case quality
    /// Allow q8_0 to buy context, but stop short of q4_0. The default.
    case balanced
    /// Allow q4_0 as well, trading cache fidelity for the longest context.
    case context

    public var allowedCacheTypes: [KVCacheType] {
        switch self {
        case .quality:  return [.f16]
        case .balanced: return [.f16, .q8_0]
        case .context:  return [.f16, .q8_0, .q4_0]
        }
    }

    public var explanation: String {
        switch self {
        case .quality:
            return "uses an f16 cache only, so the context is as short as memory requires"
        case .balanced:
            return "may quantise the cache to q8_0, which is close to lossless, to gain context"
        case .context:
            return "may quantise the cache to q4_0, which trades noticeable quality for the longest context"
        }
    }
}

public struct OptimizationPlan: Sendable, Codable, Equatable {
    public let modelPath: String
    public let mmprojPath: String?
    public let arguments: [LlamaArgument]

    public let contextLength: Int
    public let cacheTypeK: KVCacheType
    public let cacheTypeV: KVCacheType
    public let gpuLayers: Int
    public let threads: Int
    public let batchSize: Int?
    public let microBatchSize: Int?

    public let estimatedWeightsBytes: UInt64
    public let estimatedKVCacheBytes: UInt64
    public let estimatedComputeBytes: UInt64
    public let estimatedProjectorBytes: UInt64
    public let memoryBudgetBytes: UInt64
    public let hardware: HardwareProfile
    public let policy: MemoryPolicy
    public let cachePolicy: CachePolicy
    /// The sampling preset applied, so the UI can show it alongside the flags.
    public let sampling: SamplingPreset
    /// How the chat template was resolved — the model's own, a built-in preset,
    /// or nothing. Surfaced because an unresolved template silently breaks tool
    /// calling, and the user cannot fix what they cannot see.
    public let templateNote: String
    /// Whether the chosen template can express a tool call, as far as it can be
    /// told without loading the model.
    ///
    /// Carried on the plan rather than recomputed by callers so that the UI
    /// badge, the warning, and the runtime check against `/props` are all
    /// talking about the same prediction. When they disagree, one of them is
    /// wrong, and that is worth being able to see.
    public let templateToolCalling: ChatTemplateLibrary.ToolCallingSupport
    public let warnings: [String]

    public var estimatedTotalBytes: UInt64 {
        estimatedWeightsBytes + estimatedKVCacheBytes + estimatedComputeBytes + estimatedProjectorBytes
    }

    public var memoryUsedFraction: Double {
        guard memoryBudgetBytes > 0 else { return 0 }
        return Double(estimatedTotalBytes) / Double(memoryBudgetBytes)
    }

    /// Everything after the binary, ready for `execve`.
    public func argv(binary: String) -> [String] {
        var out = [binary]
        for argument in arguments {
            out.append(argument.flag)
            if let value = argument.value { out.append(value) }
        }
        return out
    }

    /// A shell-quoted command line, for showing the user what will run.
    public func commandLine(binary: String = "llama-server") -> String {
        argv(binary: binary).map(Self.shellQuoted).joined(separator: " ")
    }

    static func shellQuoted(_ value: String) -> String {
        guard value.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" || $0 == "\\" }) else {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public var summary: String {
        var parts = [
            "\(contextLength / 1024)k context",
            "\(cacheTypeK.rawValue) cache",
            "\(gpuLayers) GPU layers",
            "\(threads) threads",
        ]
        parts.append("~\(Self.formatBytes(estimatedTotalBytes)) of \(Self.formatBytes(memoryBudgetBytes))")
        return parts.joined(separator: " · ")
    }

    public static func formatBytes(_ bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        if gigabytes >= 1 { return String(format: "%.1f GB", gigabytes) }
        let megabytes = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", megabytes)
    }
}

public struct ModelOptimizer: Sendable {

    /// Context sizes worth offering, ascending. Powers of two because that is
    /// what llama.cpp allocates efficiently and what people recognise.
    public static let contextLadder = [4_096, 8_192, 16_384, 32_768, 65_536, 131_072, 262_144]

    /// Cache types in descending order of quality, subject to `CachePolicy`.
    public static let cachePreference: [KVCacheType] = [.f16, .q8_0, .q4_0]

    /// The `-ngl` value meaning "every layer", which must *over*-count.
    ///
    /// Measured on llama.cpp 10150 / Apple M2 Max with a 42-layer model:
    /// `-ngl 42` — the exact count — segfaults during Metal graph init, and so
    /// do partial values (`20`) and CPU-only (`0`). Only a value at or above
    /// the layer count (`99`, `999`) loads. An exact or partial count leaves
    /// the last layer or the output tensor on the CPU, and this build's CPU
    /// path crashes before the model finishes loading.
    ///
    /// So there is no working partial-offload setting here. This is also the
    /// convention llama.cpp's own tooling and the sibling routers use.
    public static let fullOffloadValue = 999

    public var hardware: HardwareProfile
    public var policy: MemoryPolicy
    public var cachePolicy: CachePolicy
    /// How the model should sample. Defaults to `.agent` rather than to
    /// llama.cpp's own defaults, because this app exists to run coding agents:
    /// a tool call that samples creatively is a tool call that fails to parse.
    public var sampling: SamplingPreset

    public init(
        hardware: HardwareProfile = .current(),
        policy: MemoryPolicy = .safe,
        cachePolicy: CachePolicy = .balanced,
        sampling: SamplingPreset = .default
    ) {
        self.hardware = hardware
        self.policy = policy
        self.cachePolicy = cachePolicy
        self.sampling = sampling
    }

    /// Compute a plan for a scanned model.
    public func plan(for model: LocalModel) throws -> OptimizationPlan {
        guard let modelPath = model.modelPath else {
            throw OptimizationError.modelUnreadable(model.model.filename)
        }
        return plan(
            modelPath: modelPath,
            mmprojPath: model.mmprojPath,
            info: model.model.info,
            modelBytes: UInt64(max(0, model.model.sizeBytes)),
            projectorBytes: UInt64(max(0, model.projector?.sizeBytes ?? 0))
        )
    }

    public enum OptimizationError: Error, CustomStringConvertible {
        case modelUnreadable(String)
        case noMetadata(String)

        public var description: String {
            switch self {
            case .modelUnreadable(let name):
                return "\(name) could not be opened, so no plan can be made for it"
            case .noMetadata(let name):
                return "\(name) has no readable metadata, so its memory use cannot be estimated"
            }
        }
    }

    /// Compute a plan from raw parts. Exposed separately so tests can drive it
    /// with synthetic hardware and synthetic model geometry.
    public func plan(
        modelPath: String,
        mmprojPath: String?,
        info: GGUFModelInfo?,
        modelBytes: UInt64,
        projectorBytes: UInt64
    ) -> OptimizationPlan {
        var warnings: [String] = []

        let budget = policy.budget(for: hardware)
        let weights = modelBytes
        let projector = mmprojPath != nil ? projectorBytes : 0

        // llama.cpp keeps a compute buffer sized by the batch, plus the graph
        // itself. It scales with the model rather than being fixed, and a flat
        // 512 MB floor covers the small end where the graph dominates.
        //
        // Mixture-of-Experts models get a smaller buffer. All their weights are
        // resident — every expert must be loaded — but only the top-k experts
        // are active per token, so the FFN activation that dominates a dense
        // model's buffer is a fraction of the size here. Sizing it as though it
        // were dense over-reserves and costs real context. This is an estimate
        // rather than a measurement, so it errs small on purpose.
        let isMixtureOfExperts = (info?.expertCount ?? 0) > 1
        let computeDivisor: UInt64 = isMixtureOfExperts ? 24 : 12
        let compute = max(512 * 1_048_576, weights / computeDivisor)

        // What is left for the cache once everything else is accounted for.
        let fixed = weights &+ compute &+ projector
        let availableForCache = budget > fixed ? budget - fixed : 0

        let trainedContext = info?.contextLength
        let candidates = contextCandidates(trained: trainedContext)

        var chosenContext: Int?
        var chosenCache: KVCacheType?

        // Context outermost, cache innermost: take the longest context that can
        // be made to fit at *any* cache precision the policy permits, and only
        // then shorten. A longer context is worth more to an agent than a
        // marginally more precise cache — up to the limit the policy sets.
        let permittedCaches = cachePolicy.allowedCacheTypes

        for context in candidates {
            for cache in permittedCaches {
                guard let perToken = info?.kvBytesPerToken(bytesPerElement: cache.bytesPerElement) else {
                    // Without geometry the cache size is unknown, so the only
                    // honest thing is to pick a conservative default and say so.
                    chosenContext = chosenContext ?? context
                    chosenCache = chosenCache ?? cache
                    continue
                }
                let cacheBytes = UInt64(perToken * Double(context))
                if cacheBytes <= availableForCache {
                    chosenContext = context
                    chosenCache = cache
                    break
                }
            }
            if chosenContext != nil { break }
        }

        // Nothing fit. Fall back to the smallest sensible configuration and tell
        // the user exactly what is wrong, rather than emitting a plan that will
        // fail at load time.
        if chosenContext == nil || chosenCache == nil {
            chosenContext = candidates.last ?? 4_096
            chosenCache = permittedCaches.last ?? .q4_0
            warnings.append(
                "This model does not fit in \(OptimizationPlan.formatBytes(budget)) even at "
                    + "\(chosenContext! / 1024)k context with a \(chosenCache!.rawValue) cache. Weights alone are "
                    + "\(OptimizationPlan.formatBytes(weights)). Expect it to be slow or to fail to load."
            )
        }

        let context = chosenContext!
        let cacheType = chosenCache!
        let kvPerToken = info?.kvBytesPerToken(bytesPerElement: cacheType.bytesPerElement) ?? 0
        let kvBytes = UInt64(kvPerToken * Double(context))

        // Layer offload. With unified memory, if it fits it all goes on the GPU.
        let layers = info?.blockCount ?? 0
        var gpuLayers = layers
        if layers > 0, fixed &+ kvBytes > budget {
            let room = budget > (compute &+ projector) ? budget - compute - projector : 0
            let fraction = weights > 0 ? Double(room) / Double(weights) : 0
            gpuLayers = max(0, min(layers, Int(Double(layers) * fraction)))
            warnings.append(
                "Only about \(gpuLayers) of \(layers) layers fit in the memory budget. Partial "
                    + "offload does not start on this llama.cpp build, so all \(layers) are "
                    + "offloaded anyway — expect memory pressure."
            )
        }

        // A quantised cache is only sound with flash attention enabled — and on
        // Metal it is faster anyway, so it is on regardless.
        let flashAttention = true

        let headroom = budget > (fixed &+ kvBytes) ? budget - fixed - kvBytes : 0
        let tight = Double(headroom) / Double(max(budget, 1)) < 0.15

        // A smaller micro-batch shrinks the compute buffer, which is the largest
        // single allocation at long context. Worth the small throughput cost
        // when there is not much room left.
        let microBatch: Int? = tight ? 256 : nil
        let batch: Int? = tight ? 1_024 : nil

        if tight {
            warnings.append(
                "Memory is tight — \(OptimizationPlan.formatBytes(headroom)) spare out of "
                    + "\(OptimizationPlan.formatBytes(budget)). The batch sizes have been reduced to "
                    + "shrink the compute buffer."
            )
        }

        var arguments: [LlamaArgument] = []

        arguments.append(LlamaArgument(
            flag: "-m",
            value: modelPath,
            reason: "the model to serve",
            category: .model
        ))

        if let mmprojPath {
            arguments.append(LlamaArgument(
                flag: "--mmproj",
                value: mmprojPath,
                reason: "the vision projector paired with this model",
                category: .multimodal
            ))
        }

        // The chat template. llama.cpp selects one automatically, but that
        // selection is only correct when the model embeds its own template or
        // its architecture maps onto one llama.cpp ships. When neither holds,
        // the model is served with a generic format that breaks tool calling —
        // so resolve it explicitly and record which way it went, rather than
        // leaving the user to infer it from malformed output.
        let templateResolution = ChatTemplateLibrary.resolve(
            architecture: info?.architecture,
            embeddedTemplate: info?.chatTemplate,
            vocabularySize: info?.vocabularySize
        )
        arguments.append(contentsOf: templateResolution.arguments)
        if !templateResolution.isResolved {
            warnings.append(templateResolution.note)
        }
        // A template that resolves but cannot express a tool call is the quiet
        // failure this whole path exists to prevent. It is worth saying before
        // the model is loaded rather than after an agent has spent a turn
        // emitting its tool call as prose.
        if let warning = templateResolution.warning {
            warnings.append(warning)
        }

        // Thinking models put their chain of thought inline in the answer by
        // default, as literal <think> tags. That corrupts the visible response
        // and breaks tool-call parsing further downstream. `deepseek` moves it
        // into `message.reasoning_content`, which the router maps onto
        // Anthropic `thinking` blocks — so the reasoning survives *and* stops
        // being mistaken for the answer.
        if let template = info?.chatTemplate,
           template.contains("<think") || template.lowercased().contains("reasoning") {
            arguments.append(LlamaArgument(
                flag: "--reasoning-format",
                value: "deepseek",
                reason: "keep the model's reasoning out of the answer and in its own field",
                category: .template
            ))
        }

        if layers > 0 {
            arguments.append(LlamaArgument(
                flag: "-ngl",
                value: String(Self.fullOffloadValue),
                reason: gpuLayers >= layers
                    ? "all \(layers) layers on the GPU; memory is shared with the CPU on this chip"
                    : "all \(layers) layers on the GPU — a partial count (\(gpuLayers)) cannot start this build",
                category: .memory
            ))
        } else {
            arguments.append(LlamaArgument(
                flag: "-ngl",
                value: String(Self.fullOffloadValue),
                reason: "the layer count could not be read, so offload everything",
                category: .memory
            ))
        }

        arguments.append(LlamaArgument(
            flag: "-c",
            value: String(context),
            reason: contextReason(
                context: context,
                trained: trainedContext,
                cache: cacheType,
                kvBytes: kvBytes
            ),
            category: .context
        ))

        // Without this, `-c` is divided between slots. An agent sends one
        // conversation at a time, and splitting a 128k window into four 32k
        // windows would silently truncate its context.
        arguments.append(LlamaArgument(
            flag: "--parallel",
            value: "1",
            reason: "one slot, so the whole context belongs to the agent using it",
            category: .context
        ))

        // Slide the cache instead of refusing once the context fills.
        //
        // This is what makes a long agent session survivable. An agent resends
        // its whole transcript every turn, so the context fills up as a matter
        // of course; without shifting, the server errors out mid-session and
        // the agent looks like it crashed. The reference implementations all
        // pass it, and it is gated on the build supporting it.
        arguments.append(LlamaArgument(
            flag: "--context-shift",
            reason: "slide the KV cache when the context fills, rather than failing "
                + "mid-session — agents resend a growing transcript every turn",
            category: .context
        ))

        if cacheType != .f16 {
            arguments.append(LlamaArgument(
                flag: "--cache-type-k",
                value: cacheType.rawValue,
                reason: "quantising the key cache to \(cacheType.rawValue) makes a "
                    + "\(context / 1024)k context fit",
                category: .memory
            ))
            arguments.append(LlamaArgument(
                flag: "--cache-type-v",
                value: cacheType.rawValue,
                reason: "the value cache must match the key cache",
                category: .memory
            ))
        }

        if flashAttention {
            arguments.append(LlamaArgument(
                flag: "-fa",
                reason: cacheType == .f16
                    ? "faster attention on Metal"
                    : "required for a quantised value cache, and faster on Metal",
                category: .performance
            ))
        }

        if let batch {
            arguments.append(LlamaArgument(
                flag: "-b",
                value: String(batch),
                reason: "smaller logical batch to keep the compute buffer down",
                category: .performance
            ))
        }

        if let microBatch {
            arguments.append(LlamaArgument(
                flag: "-ub",
                value: String(microBatch),
                reason: "smaller physical batch; this is the allocation that grows with context",
                category: .performance
            ))
        }

        // Loading mode. Only emitted when the user has asked for the machine to
        // be used aggressively, because `mlock` is a request to the kernel to
        // never swap or compress these pages — it is the right answer for a
        // model that is meant to be resident, and the wrong answer for one that
        // is competing with the user's other work. The `safe` policy exists
        // precisely because macOS swapping during generation is worse than a
        // shorter context, so it is left on the default `mmap` behaviour.
        if policy == .maximal {
            arguments.append(LlamaArgument(
                flag: "--load-mode",
                value: "mlock",
                reason: "keep the weights resident so macOS cannot compress them mid-generation",
                category: .performance
            ))
        }

        arguments.append(LlamaArgument(
            flag: "-t",
            value: String(hardware.recommendedThreads),
            reason: hardware.performanceCores != nil
                ? "performance cores only — scheduling onto efficiency cores makes them the bottleneck"
                : "all available cores",
            category: .performance
        ))

        // Sampling. llama.cpp's defaults — temperature 0.8, top_k 40 — are
        // tuned for chat. This app runs coding agents, where a tool call
        // sampled at 0.8 occasionally arrives as prose instead of JSON. The
        // preset is emitted explicitly so the behaviour is visible in the plan
        // rather than implied by an upstream default that may change.
        arguments.append(contentsOf: sampling.arguments)

        if context < (trainedContext ?? context) {
            warnings.append(
                "The model was trained for a \(trainedContext! / 1024)k context but will be served "
                    + "at \(context / 1024)k, which is what fits in memory."
            )
        }

        return OptimizationPlan(
            modelPath: modelPath,
            mmprojPath: mmprojPath,
            arguments: arguments,
            contextLength: context,
            cacheTypeK: cacheType,
            cacheTypeV: cacheType,
            gpuLayers: gpuLayers,
            threads: hardware.recommendedThreads,
            batchSize: batch,
            microBatchSize: microBatch,
            estimatedWeightsBytes: weights,
            estimatedKVCacheBytes: kvBytes,
            estimatedComputeBytes: compute,
            estimatedProjectorBytes: projector,
            memoryBudgetBytes: budget,
            hardware: hardware,
            policy: policy,
            cachePolicy: cachePolicy,
            sampling: sampling,
            templateNote: templateResolution.note,
            templateToolCalling: templateResolution.toolCalling,
            warnings: warnings
        )
    }

    /// Context sizes to try, longest first.
    ///
    /// The model's own trained length is included even when it is not a power of
    /// two, because serving a model at exactly the length it was trained for is
    /// the case worth getting right.
    func contextCandidates(trained: Int?) -> [Int] {
        var values = Self.contextLadder
        if let trained, trained > 0 {
            values = values.filter { $0 <= trained }
            if !values.contains(trained) { values.append(trained) }
        }
        let unique = Array(Set(values)).sorted(by: >)
        return unique.isEmpty ? [4_096] : unique
    }

    private func contextReason(
        context: Int,
        trained: Int?,
        cache: KVCacheType,
        kvBytes: UInt64
    ) -> String {
        let size = OptimizationPlan.formatBytes(kvBytes)
        guard let trained else {
            return "\(context / 1024)k tokens, using \(size) of cache; the trained length could not be read"
        }
        if context >= trained {
            return "the model's full \(trained / 1024)k trained context, using \(size) of cache"
        }
        return "reduced from the trained \(trained / 1024)k to \(context / 1024)k so the cache "
            + "(\(size)) fits in memory"
    }
}
