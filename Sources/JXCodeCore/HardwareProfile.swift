import Foundation

// MARK: - What the machine actually has
//
// The optimiser needs three numbers to decide how to run a model: how much
// memory it may use, how many fast cores there are, and which chip it is on.
//
// Only the first is interesting. On Apple Silicon the CPU and GPU share one
// pool of memory, so "how much VRAM" is not a question with an answer — there
// is a single budget, and the only real constraint is leaving macOS enough to
// keep running. macOS enforces this through the GPU wired-memory limit, which
// defaults to roughly 75% of physical memory.
//
// The core counts matter because llama.cpp's `-t` default counts *all* physical
// cores, including the efficiency cores. On Apple Silicon that is the wrong
// answer: work scheduled onto efficiency cores runs several times slower than on
// performance cores, and the generation loop is latency-bound, so the slow cores
// become the critical path. Setting `-t` to the performance-core count is
// reliably faster than the default.

public struct HardwareProfile: Sendable, Codable, Equatable {
    public let physicalMemory: UInt64
    /// `hw.perflevel0.physicalcpu`. Absent on Intel Macs.
    public let performanceCores: Int?
    /// `hw.perflevel1.physicalcpu`.
    public let efficiencyCores: Int?
    public let totalCores: Int
    /// `machdep.cpu.brand_string`, e.g. "Apple M3 Max".
    public let chipName: String?
    /// `hw.model`, e.g. "Mac15,6".
    public let modelIdentifier: String?
    /// Whether the GPU shares memory with the CPU.
    public let isUnifiedMemory: Bool

    public init(
        physicalMemory: UInt64,
        performanceCores: Int?,
        efficiencyCores: Int?,
        totalCores: Int,
        chipName: String?,
        modelIdentifier: String?,
        isUnifiedMemory: Bool
    ) {
        self.physicalMemory = physicalMemory
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.totalCores = totalCores
        self.chipName = chipName
        self.modelIdentifier = modelIdentifier
        self.isUnifiedMemory = isUnifiedMemory
    }

    /// Read the current machine.
    public static func current() -> HardwareProfile {
        let memory = ProcessInfo.processInfo.physicalMemory
        let performance = sysctlInt("hw.perflevel0.physicalcpu")
        let efficiency = sysctlInt("hw.perflevel1.physicalcpu")
        let total = sysctlInt("hw.physicalcpu") ?? ProcessInfo.processInfo.processorCount
        let brand = sysctlString("machdep.cpu.brand_string")
        let model = sysctlString("hw.model")

        // Apple Silicon reports performance levels and has no separate VRAM.
        let unified = performance != nil

        return HardwareProfile(
            physicalMemory: memory,
            performanceCores: performance,
            efficiencyCores: efficiency,
            totalCores: total,
            chipName: brand,
            modelIdentifier: model,
            isUnifiedMemory: unified
        )
    }

    /// A profile for tests and for machines whose sysctl calls fail.
    public static func synthetic(
        memoryGB: Double,
        performanceCores: Int = 8,
        efficiencyCores: Int = 4
    ) -> HardwareProfile {
        HardwareProfile(
            physicalMemory: UInt64(memoryGB * 1_073_741_824),
            performanceCores: performanceCores,
            efficiencyCores: efficiencyCores,
            totalCores: performanceCores + efficiencyCores,
            chipName: "Synthetic",
            modelIdentifier: "Test1,1",
            isUnifiedMemory: true
        )
    }

    /// How much memory a local model may use.
    ///
    /// 70% of physical memory. The remaining 30% covers macOS itself, whatever
    /// the user is running, and the fact that llama.cpp's real peak is always a
    /// little above the sum of its parts. A model that "fits" at 95% does not
    /// actually fit — it swaps, and swapping during generation is catastrophic
    /// for latency.
    public var memoryBudget: UInt64 {
        UInt64(Double(physicalMemory) * 0.70)
    }

    /// Above this the plan is workable but tight, and the optimiser will take
    /// the memory-saving options it would otherwise skip.
    public var comfortableBudget: UInt64 {
        UInt64(Double(physicalMemory) * 0.55)
    }

    /// Threads to hand llama.cpp.
    ///
    /// Performance cores only, when the machine reports them.
    public var recommendedThreads: Int {
        if let performanceCores, performanceCores > 0 { return performanceCores }
        return max(1, totalCores)
    }

    public var displayName: String {
        var parts: [String] = []
        if let chipName, !chipName.isEmpty { parts.append(chipName) }
        if let modelIdentifier, !modelIdentifier.isEmpty { parts.append("(\(modelIdentifier))") }
        parts.append("\(formattedMemory) RAM")
        if let performanceCores, let efficiencyCores {
            parts.append("\(performanceCores)P+\(efficiencyCores)E")
        }
        return parts.joined(separator: " · ")
    }

    public var formattedMemory: String {
        let gigabytes = Double(physicalMemory) / 1_073_741_824
        return String(format: "%.0f GB", gigabytes)
    }
}

// MARK: - sysctl

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

private func sysctlInt(_ name: String) -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return Int(value)
}
