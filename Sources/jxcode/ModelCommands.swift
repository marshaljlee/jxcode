import Foundation
import JXCodeCore

// Pillar 03 commands: the local GGUF library.
//
// These mirror what the app's Models pane does, so the same behaviour can be
// inspected and verified from a terminal — and so a failure can be reproduced
// without a GUI. All the actual rendering lives in `ModelReport` in the core, so
// the terminal and the window cannot disagree about what a plan says.

// MARK: - Shared helpers

/// Where to look for models.
///
/// The common case is `~/Models`, but nothing is assumed: the directory is a
/// parameter, and the default is used only when it exists.
func resolveModelRoots(flags: Flags) -> [URL] {
    let positional = flags.positional.map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
    }
    if !positional.isEmpty { return positional }

    if let configured = flags.value("--models"), !configured.isEmpty {
        return [URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)]
    }

    let home = URL(fileURLWithPath: NSHomeDirectory())
    return [home.appendingPathComponent("Models")]
}

func modelScanner(flags: Flags) -> ModelScanner {
    var options = ModelScanner.Options()
    // A name-only listing is much faster on a large library, and is enough when
    // the question is "what is in here" rather than "how would this run".
    options.readMetadata = !flags.has("--names-only")
    return ModelScanner(options: options)
}

func memoryPolicy(flags: Flags) -> MemoryPolicy {
    guard let raw = flags.value("--memory") else { return .safe }
    return MemoryPolicy(rawValue: raw) ?? .safe
}

func cachePolicy(flags: Flags) -> CachePolicy {
    guard let raw = flags.value("--cache") else { return .balanced }
    return CachePolicy(rawValue: raw) ?? .balanced
}

func makeOptimizer(flags: Flags) -> ModelOptimizer {
    ModelOptimizer(
        hardware: .current(),
        policy: memoryPolicy(flags: flags),
        cachePolicy: cachePolicy(flags: flags)
    )
}

/// Find a scanned model by the path the user typed.
///
/// The scan covers the file's own directory, so a projector sitting beside the
/// model is discovered too — `jxcode serve ~/Models/Ornith-1.5\ 9B\ Q8_0.gguf`
/// gets vision support without the projector ever being mentioned.
func resolveLocalModel(at path: String, scanner: ModelScanner) throws -> LocalModel {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        throw CLIError.usage("no such file: \(url.path)")
    }

    let directory = isDirectory.boolValue ? url : url.deletingLastPathComponent()
    let scan = scanner.scan(roots: [directory])

    if isDirectory.boolValue {
        guard let model = scan.models.first else {
            throw CLIError.usage("no GGUF models found in \(directory.path)")
        }
        return model
    }

    let target = url.resolvingSymlinksInPath().path
    guard let model = scan.models.first(where: {
        $0.model.resolvedURL?.path == target
            || $0.model.url.path == url.path
            || $0.model.url.path == target
    }) else {
        // The file exists but is not a language model — most likely a projector,
        // which is worth saying explicitly rather than reporting a generic
        // "not found" for a file the user can see right there.
        if scan.orphanProjectors.contains(where: { $0.url.path == url.path }) {
            throw CLIError.usage(
                "\(url.lastPathComponent) is a vision projector, not a model. "
                    + "Point this at the model it belongs to and the projector will be found automatically."
            )
        }
        throw CLIError.usage("\(url.lastPathComponent) could not be read as a GGUF model")
    }
    return model
}

// MARK: - scan

func cmdScan(sandbox: Sandbox, flags: Flags) throws {
    let roots = resolveModelRoots(flags: flags)
    let existing = roots.filter { FileManager.default.fileExists(atPath: $0.path) }

    guard !existing.isEmpty else {
        print("No model directory found. Looked in:")
        for root in roots { print("  \(root.path)") }
        print("\nPass a directory: jxcode scan ~/Models")
        return
    }

    print("Scanning \(existing.map(\.path).joined(separator: ", ")) …")
    let scan = modelScanner(flags: flags).scan(roots: existing, onProgress: { name in
        if flags.has("--verbose") { FileHandle.standardError.write(Data("  \(name)\n".utf8)) }
    })

    print("")
    print(ModelReport.scan(
        scan,
        optimizer: flags.has("--plan") ? makeOptimizer(flags: flags) : nil,
        options: ModelReport.ScanOptions(
            showPaths: flags.has("--paths"),
            showPlan: flags.has("--plan"),
            verbose: flags.has("--verbose")
        )
    ))
}

// MARK: - model-info

func cmdModelInfo(sandbox: Sandbox, flags: Flags) throws {
    guard let path = flags.positional.first else {
        throw CLIError.usage("jxcode model-info <file.gguf>")
    }
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

    let started = Date()
    let header = try GGUFReader.readHeader(at: url)
    let info = GGUFModelInfo(header: header)
    let elapsed = Date().timeIntervalSince(started)

    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

    print(ModelReport.modelInfo(
        url: url,
        header: header,
        info: info,
        fileSizeBytes: size,
        elapsed: elapsed,
        options: ModelReport.InfoOptions(
            showAllKeys: flags.has("--all-keys"),
            showTemplate: flags.has("--template")
        )
    ))
}

// MARK: - llama-plan

func cmdLlamaPlan(sandbox: Sandbox, flags: Flags) throws {
    guard let path = flags.positional.first else {
        throw CLIError.usage(
            "jxcode llama-plan <file.gguf> [--memory safe|balanced|maximal] [--cache quality|balanced|context]"
        )
    }

    let model = try resolveLocalModel(at: path, scanner: modelScanner(flags: flags))
    let plan = try makeOptimizer(flags: flags).plan(for: model)
    print(ModelReport.plan(plan, title: model.displayName))
}

// MARK: - runtime

func cmdRuntime(sandbox: Sandbox, flags: Flags) throws {
    let locator = LlamaRuntimeLocator(paths: sandbox.paths)
    print(ModelReport.runtime(locator))
}

// MARK: - serve

func cmdServe(sandbox: Sandbox, flags: Flags) throws {
    guard let path = flags.positional.first else {
        throw CLIError.usage("jxcode serve <file.gguf> [--port 8080] [--memory safe] [--register]")
    }

    try sandbox.prepare()

    guard let runtime = LlamaRuntimeLocator(paths: sandbox.paths).locate() else {
        throw CLIError.usage(
            "no llama-server found. Run `jxcode runtime` to see where it was looked for."
        )
    }

    let model = try resolveLocalModel(at: path, scanner: modelScanner(flags: flags))
    let plan = try makeOptimizer(flags: flags).plan(for: model)

    let preferred = flags.value("--port").flatMap(Int.init) ?? 8_080
    guard let port = PortAllocator.firstFree(from: preferred) else {
        throw CLIError.usage("no free port at or above \(preferred)")
    }

    let slug = model.model.filename
        .replacingOccurrences(of: ".gguf", with: "")
        .replacingOccurrences(of: " ", with: "-")
    let logURL = sandbox.paths.logs.appendingPathComponent("llama-server-\(slug).log")

    print("Serving \(model.displayName)")
    print("  runtime     \(runtime.binary.path)  (\(runtime.origin.rawValue))")
    print("  context     \(plan.contextLength) tokens, \(plan.cacheTypeK.rawValue) cache")
    print("  memory      \(OptimizationPlan.formatBytes(plan.estimatedTotalBytes))"
        + " of \(OptimizationPlan.formatBytes(plan.memoryBudgetBytes)) budget")
    print("  endpoint    http://127.0.0.1:\(port)")
    print("  log         \(logURL.path)")
    if let projector = model.projector {
        print("  vision      \(projector.filename)")
    }
    for warning in plan.warnings { print("⚠︎  \(warning)") }
    print("")
    print("Loading the model…")

    let server = LlamaServer(
        configuration: LlamaServerConfiguration(
            binary: runtime.binary,
            plan: plan,
            port: port,
            logURL: logURL
        ),
        paths: sandbox.paths
    )

    // The same semaphore bridge the router commands use to run async work from
    // this synchronous entry point.
    try awaitBlocking {
        try await server.start()
    }

    print("Ready. \(server.state)")
    print("")
    print("  OpenAI      http://127.0.0.1:\(port)/v1")
    print("  Health      http://127.0.0.1:\(port)/health")

    if flags.has("--register") {
        let store = ProviderStore(paths: sandbox.paths)
        let provider = Provider(
            name: "\(model.displayName) (local)",
            kind: .localGGUF,
            baseURL: "http://127.0.0.1:\(port)",
            models: [model.model.filename]
        )
        try store.add(provider)
        print("")
        print("Registered as a provider: \(provider.name)")
        print("  Agents routed through the model router will use it once it is selected.")
    }

    print("")
    print("Press Ctrl-C to stop.")

    // Stop the child on the way out. An orphaned llama-server holding several
    // gigabytes and a port is exactly the outcome this class exists to prevent,
    // so the handler stops it explicitly rather than relying on the deinit.
    signal(SIGINT) { _ in
        FileHandle.standardError.write(Data("\nstopping…\n".utf8))
        exit(0)
    }

    while server.state.isRunning {
        sleep(1)
    }

    print("llama-server stopped: \(server.state)")
    server.stop()
}
