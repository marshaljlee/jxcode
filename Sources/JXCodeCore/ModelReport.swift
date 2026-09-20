import Foundation

// MARK: - Rendering model information as text
//
// This lives in the core rather than in the CLI because both front ends need
// it: `jxcode scan` prints it, and the app's Models pane shows the same facts.
// Keeping one renderer means the terminal and the window can never disagree
// about what a plan says — and it makes the output testable, which a function
// buried in an executable target is not.

public enum ModelReport {

    public struct ScanOptions: Sendable {
        public var showPaths: Bool
        public var showPlan: Bool
        public var verbose: Bool

        public init(showPaths: Bool = false, showPlan: Bool = false, verbose: Bool = false) {
            self.showPaths = showPaths
            self.showPlan = showPlan
            self.verbose = verbose
        }
    }

    public struct InfoOptions: Sendable {
        public var showAllKeys: Bool
        public var showTemplate: Bool

        public init(showAllKeys: Bool = false, showTemplate: Bool = false) {
            self.showAllKeys = showAllKeys
            self.showTemplate = showTemplate
        }
    }

    // MARK: Library scan

    public static func scan(
        _ scan: ModelLibraryScan,
        optimizer: ModelOptimizer? = nil,
        options: ScanOptions = ScanOptions()
    ) -> String {
        var lines: [String] = []

        lines.append("\(scan.totalModels) model\(scan.totalModels == 1 ? "" : "s"), "
            + "\(scan.visionModels) with vision, "
            + "in \(String(format: "%.1f", scan.duration))s")
        lines.append("")

        for model in scan.models {
            lines.append("  \(model.displayName)")
            lines.append("    \(model.model.summary)  ·  \(OptimizationPlan.formatBytes(UInt64(max(0, model.totalSizeBytes))))")

            if options.showPaths {
                lines.append("    model      \(model.model.url.path)")
                if let projector = model.projector {
                    lines.append("    projector  \(projector.url.path)")
                }
            }

            if let projector = model.projector {
                let how = model.pairing?.rawValue ?? "paired"
                lines.append("    vision     \(projector.filename)  (\(how))")
            } else if options.verbose {
                lines.append("    vision     none")
            }

            if let problem = model.projectorProblem {
                lines.append("    ⚠︎ \(problem)")
            }

            if options.showPlan, let optimizer, model.model.info != nil,
               let plan = try? optimizer.plan(for: model) {
                lines.append("    plan       \(plan.summary)")
            }
        }

        if !scan.orphanProjectors.isEmpty {
            lines.append("")
            lines.append("Projectors with no model:")
            for projector in scan.orphanProjectors {
                lines.append("  \(projector.filename)")
            }
        }

        if !scan.unreadable.isEmpty {
            lines.append("")
            lines.append("Unreadable:")
            for file in scan.unreadable {
                let why = file.isDangling ? "broken symlink" : (file.readError ?? "unreadable")
                lines.append("  \(file.filename)  — \(why)")
            }
        }

        if !scan.warnings.isEmpty {
            lines.append("")
            for warning in scan.warnings { lines.append("⚠︎  \(warning)") }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: Model card

    public static func modelInfo(
        url: URL,
        header: GGUFHeader,
        info: GGUFModelInfo,
        fileSizeBytes: Int64,
        elapsed: TimeInterval,
        options: InfoOptions = InfoOptions()
    ) -> String {
        var lines: [String] = []

        lines.append(url.lastPathComponent)
        lines.append("")
        lines.append("  format        GGUF v\(header.version), \(header.tensorCount) tensors, \(header.metadataCount) metadata keys")
        lines.append("  read          \(header.bytesRead) bytes in \(String(format: "%.2f", elapsed))s "
            + "of a \(OptimizationPlan.formatBytes(UInt64(max(0, fileSizeBytes)))) file")

        lines.append("")
        lines.append("  architecture  \(info.architecture ?? "unknown")")
        lines.append("  name          \(info.name ?? "—")")
        lines.append("  size label    \(info.sizeLabel ?? "—")")
        if let fileType = info.fileType {
            lines.append("  quantisation  \(fileType.label) (\(String(format: "%.2f", fileType.bitsPerWeight)) bits/weight)")
        } else {
            lines.append("  quantisation  —")
        }

        lines.append("")
        lines.append("  context       \(info.contextLength.map { "\($0) tokens" } ?? "—")")
        lines.append("  layers        \(info.blockCount.map(String.init) ?? "—")")
        lines.append("  embedding     \(info.embeddingLength.map(String.init) ?? "—")")
        lines.append("  heads         \(info.headCount.map(String.init) ?? "—") query, "
            + "\(info.resolvedKVHeadCount.map(String.init) ?? "—") KV")
        lines.append("  head dim      \(info.headDimension.map(String.init) ?? "—")")

        if let perToken = info.kvBytesPerToken(bytesPerElement: 2) {
            lines.append("")
            lines.append("  KV per token  \(OptimizationPlan.formatBytes(UInt64(perToken))) at f16")
            if let context = info.contextLength {
                let full = UInt64(perToken * Double(context))
                lines.append("  KV at full    \(OptimizationPlan.formatBytes(full)) for \(context) tokens")
            }
        }

        if info.isProjector {
            lines.append("")
            lines.append("  projector     \(info.vision?.projectorType ?? "unknown type")")
            lines.append("  vision        \(info.isVisionCapable ? "yes" : "no")")
            lines.append("  image size    \(info.vision?.imageSize.map(String.init) ?? "—")"
                + "  patch \(info.vision?.patchSize.map(String.init) ?? "—")")
            lines.append("  projects to   \(info.vision?.projectionDim.map(String.init) ?? "—")")
        }

        lines.append("")
        if let template = info.chatTemplate {
            lines.append("  chat template \(template.count) characters")
            if options.showTemplate {
                lines.append("")
                lines.append(template)
            }
        } else {
            lines.append("  chat template absent — llama.cpp will use its built-in default")
        }

        if options.showAllKeys {
            lines.append("")
            lines.append("  metadata keys")
            for key in header.sortedKeys {
                lines.append("    \(key) = \(header.metadata[key]?.displayDescription ?? "")")
            }
            for key in header.sortedSkippedKeys {
                lines.append("    \(key) = <present, not loaded>")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: Optimisation plan

    public static func plan(_ plan: OptimizationPlan, title: String) -> String {
        var lines: [String] = []

        lines.append(title)
        lines.append("")
        lines.append("  hardware      \(plan.hardware.displayName)")
        lines.append("  policy        \(plan.policy.rawValue) memory "
            + "(\(Int(plan.policy.fraction * 100))% of \(plan.hardware.formattedMemory)), "
            + "\(plan.cachePolicy.rawValue) cache")

        lines.append("")
        lines.append("  memory")
        lines.append("    weights     \(OptimizationPlan.formatBytes(plan.estimatedWeightsBytes))")
        lines.append("    KV cache    \(OptimizationPlan.formatBytes(plan.estimatedKVCacheBytes))"
            + "   (\(plan.contextLength) tokens at \(plan.cacheTypeK.rawValue))")
        lines.append("    compute     \(OptimizationPlan.formatBytes(plan.estimatedComputeBytes))")
        if plan.estimatedProjectorBytes > 0 {
            lines.append("    projector   \(OptimizationPlan.formatBytes(plan.estimatedProjectorBytes))")
        }
        lines.append("    ─────────────────────")
        lines.append("    total       \(OptimizationPlan.formatBytes(plan.estimatedTotalBytes))"
            + " of \(OptimizationPlan.formatBytes(plan.memoryBudgetBytes)) budget"
            + "  (\(Int(plan.memoryUsedFraction * 100))%)")

        lines.append("")
        lines.append("  arguments")
        for argument in plan.arguments {
            lines.append("    \(pad(argument.rendered, to: 46))\(argument.reason)")
        }

        lines.append("")
        lines.append("  command")
        lines.append("    \(plan.commandLine())")

        if !plan.warnings.isEmpty {
            lines.append("")
            for warning in plan.warnings { lines.append("⚠︎  \(warning)") }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: Runtime discovery

    public static func runtime(_ locator: LlamaRuntimeLocator) -> String {
        var lines: [String] = []

        lines.append("llama-server search")
        lines.append("")
        for entry in locator.diagnostics() {
            let mark = entry.exists ? "✓" : " "
            let origin = entry.origin == .sandbox ? "sandbox" : "host   "
            lines.append("  [\(mark)] \(origin)  \(entry.path.path)")
        }

        lines.append("")
        if let runtime = locator.locate() {
            lines.append("found: \(runtime.binary.path)")
            lines.append("  origin  \(runtime.origin.rawValue)")
            lines.append("  \(runtime.isolationNote)")
        } else {
            lines.append("No llama-server found.")
            lines.append("")
            lines.append("  \(locator.installationHint)")
            lines.append("")
            lines.append("  A local GGUF model cannot be served without it. The app's Models")
            lines.append("  pane offers to install it into the sandbox.")
        }

        return lines.joined(separator: "\n")
    }

    static func pad(_ value: String, to width: Int) -> String {
        value.count >= width ? value + " " : value.padding(toLength: width, withPad: " ", startingAt: 0)
    }
}
