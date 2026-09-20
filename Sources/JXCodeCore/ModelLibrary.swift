import Foundation

// MARK: - Matching a projector to its model
//
// A vision model needs two files: the language model, and a multimodal
// projector (the "mmproj") that turns image patches into embeddings the model
// can read. llama.cpp takes the projector as a separate `--mmproj` argument, so
// before it can serve a vision model the app has to work out which projector
// belongs to which model.
//
// There is no manifest and no registry — the only signal is the filename. Worse,
// the ecosystem has never agreed on one convention. All four of these are real
// and all four are present on this machine:
//
//     Ornith-1.5 9B Q8_0.gguf   +  Ornith-1.5 9B Q8_0 mmproj.gguf   (suffix, space)
//     Ornith-1.5 9B Q8_0.gguf   +  mmproj Ornith-1.5 9B Q8_0.gguf   (prefix, space)
//     Ornith-1.5-9B.Q8_0.gguf   +  mmproj-Ornith-1.5-9B-Q8_0.gguf   (prefix, dash)
//     Qwen3.5-4B_Q8_0.gguf      +  mmproj-Qwen3.5-4B_Q8_0.gguf      (prefix, dash)
//
// Note the third: the separator between the model name and the quantisation is a
// dot in one file and a dash in the other, and the quantisation itself is
// spelled `Q8_0` in one and `Q8-0` in the other. A matcher that compares raw
// filenames fails on it.
//
// The approach here is to reduce every filename to a *key* — lowercase, with
// separators flattened, and with the projector markers and quantisation tokens
// removed — so that all four pairs above collapse to the same two keys.
//
// Filenames are only the fallback, though. The authoritative signal is the
// file's own metadata: llama.cpp tags projectors with
// `general.architecture = "clip"`. When metadata is readable it decides, and
// names are used only to work out *which* model a projector belongs to.

public enum ProjectorNameMatcher {

    /// Words that identify a *projector* file. Only stripped from projector
    /// names, never from model names — see `key(for:role:)`.
    ///
    /// This distinction matters more than it looks. `Llama-3.2-11B-Vision.gguf`
    /// is a real model whose name contains "Vision"; stripping that word from
    /// the model side would make it indistinguishable from the plain
    /// `Llama-3.2-11B.gguf`, and a directory containing both would have the
    /// projector attached to whichever happened to be processed first.
    static let projectorMarkers: Set<String> = [
        "mmproj", "projector", "clip", "vit", "siglip", "visual",
    ]

    /// Words strong enough to classify a file as a projector when its metadata
    /// cannot be read. Deliberately narrower than `projectorMarkers`: "vision"
    /// and "image" appear in ordinary model names, so they are not evidence.
    static let projectorClassifierMarkers: Set<String> = [
        "mmproj", "projector", "clip", "vit", "siglip",
    ]

    /// Quantisation tokens, written the way they appear after separators have
    /// been flattened to dashes. Sorted by descending length at use so that
    /// `q4-0-4-4` is removed before `q4-0` can eat its prefix.
    static let quantisationTokens: [String] = [
        "q4-0-4-4", "q4-0-4-8", "q4-0-8-8",
        "q2-k", "q3-k-s", "q3-k-m", "q3-k-l",
        "q4-k-s", "q4-k-m", "q5-k-s", "q5-k-m", "q6-k",
        "q4-0", "q4-1", "q5-0", "q5-1", "q8-0",
        "iq1-s", "iq1-m",
        "iq2-xxs", "iq2-xs", "iq2-s", "iq2-m",
        "iq3-xxs", "iq3-xs", "iq3-s", "iq3-m",
        "iq4-nl", "iq4-xs",
        "tq1-0", "tq2-0",
        "f16", "f32", "bf16",
    ]

    /// Which side of a pairing a filename belongs to.
    public enum Role: Sendable {
        case model
        case projector
    }

    /// A filename reduced to something comparable.
    public struct Key: Sendable, Equatable, CustomStringConvertible {
        /// Separators removed entirely, so `Qwen3.5-4B` and `Qwen3.5_4B` agree.
        public let compact: String
        /// The surviving tokens, for a fallback similarity score.
        public let tokens: Set<String>

        public var description: String { compact }
    }

    /// Split a filename into lowercased tokens with every separator flattened.
    ///
    /// `.gguf` is dropped first. Note that `deletingPathExtension` removes only
    /// the *last* extension, which is what is wanted: `Ornith-1.5-9B.Q8_0.gguf`
    /// keeps its `Q8_0` and only loses `.gguf`.
    static func tokens(for filename: String) -> [String] {
        let stem = (filename as NSString).deletingPathExtension
        var flattened = ""
        flattened.reserveCapacity(stem.count)
        for character in stem.lowercased() {
            if character == "." || character == "_" || character == " " || character == "-" {
                if flattened.last != "-" { flattened.append("-") }
            } else {
                flattened.append(character)
            }
        }
        return flattened.split(separator: "-").map(String.init)
    }

    /// Whether a filename alone suggests a projector. Used only when metadata is
    /// unavailable; metadata is authoritative.
    public static func looksLikeProjector(_ filename: String) -> Bool {
        !projectorClassifierMarkers.isDisjoint(with: Set(tokens(for: filename)))
    }

    /// Reduce a filename to a comparable key.
    ///
    /// Order matters: flatten separators, strip multi-token quantisation
    /// patterns, then strip single-token projector markers. Stripping markers
    /// first would break `q4-k-m`, whose `k` sits between two tokens that look
    /// like they could be markers.
    public static func key(for filename: String, role: Role = .model) -> Key {
        var working = tokens(for: filename)

        for pattern in quantisationTokens.sorted(by: { $0.count > $1.count }) {
            let parts = pattern.split(separator: "-").map(String.init)
            guard !parts.isEmpty else { continue }
            var kept: [String] = []
            var index = 0
            while index < working.count {
                if index + parts.count <= working.count,
                   Array(working[index..<(index + parts.count)]) == parts {
                    index += parts.count
                } else {
                    kept.append(working[index])
                    index += 1
                }
            }
            working = kept
        }

        // Markers are stripped from the projector side only. On the model side
        // the same word is part of the model's identity, not a label.
        if role == .projector {
            working = working.filter { !projectorMarkers.contains($0) }
        }

        // Version fragments are kept in `compact` — `Qwen-1.5` and `Qwen-15`
        // must not compare equal — but excluded from the token set used for
        // fuzzy scoring, because a lone digit carries no identity. Without this,
        // `Ornith-1.5-9B` and `Qwen3.5-4B` share the token `5` and score a
        // non-zero similarity purely because both are version 1.5 and 3.5.
        let identity = working.filter { token in
            !(token.count == 1 && token.allSatisfy(\.isNumber))
        }

        return Key(compact: working.joined(), tokens: Set(identity))
    }

    /// How strongly a projector filename suggests a model filename.
    ///
    /// Returns 0 when there is no plausible relationship at all, so callers can
    /// treat "no match" as a first-class outcome rather than pairing whatever is
    /// left over.
    public static func score(model: Key, projector: Key) -> Double {
        guard !model.compact.isEmpty, !projector.compact.isEmpty else { return 0 }
        if model.compact == projector.compact { return 1.0 }

        // A projector is often named after a base model while the model file
        // carries an extra suffix (`-Instruct`, `-abliterated`), so containment
        // is a strong signal — but only when the shorter side is substantial,
        // otherwise a key of "4b" would match half the directory.
        let shorter = min(model.compact.count, projector.compact.count)
        if shorter >= 4,
           model.compact.contains(projector.compact) || projector.compact.contains(model.compact) {
            return 0.8
        }

        // Otherwise fall back to token overlap.
        let union = model.tokens.union(projector.tokens)
        guard !union.isEmpty else { return 0 }
        let intersection = model.tokens.intersection(projector.tokens)
        let jaccard = Double(intersection.count) / Double(union.count)
        // Scaled below containment so it can never outrank it.
        return jaccard * 0.6
    }

    /// Score below which a pairing is not worth making.
    public static let minimumScore: Double = 0.5
}

// MARK: - Discovered files

/// One GGUF file found on disk, with symlinks already resolved.
public struct ModelFile: Sendable, Codable, Identifiable, Equatable {
    /// The path as discovered — what the user sees.
    public let url: URL
    /// The real file, after resolving symlinks. `nil` when the symlink dangles.
    public let resolvedURL: URL?
    public let isSymlink: Bool
    /// A symlink whose target does not exist. Common in HuggingFace caches that
    /// have been partially moved, and it must be reported rather than silently
    /// skipped, because the user believes the model is there.
    public let isDangling: Bool
    public let sizeBytes: Int64
    /// Parsed model card. `nil` when the file could not be read.
    public let info: GGUFModelInfo?
    public let readError: String?

    public var id: String { url.path }

    public var filename: String { url.lastPathComponent }

    /// True when this file is a multimodal projector. Metadata decides; the
    /// filename is only consulted when metadata is unavailable.
    public var isProjector: Bool {
        if let info { return info.isProjector }
        return ProjectorNameMatcher.looksLikeProjector(filename)
    }

    public var isUsable: Bool { resolvedURL != nil }

    /// A name to show a person. `general.name` is preferred over the filename
    /// because filenames lie: `DeepSeek-R1-0528.gguf` on this machine is
    /// actually a Qwen3 8B fine-tune, and only the metadata says so.
    public var displayName: String {
        if let name = info?.name, !name.isEmpty { return name }
        return (filename as NSString).deletingPathExtension
    }

    /// What the file is, in a few words, for a list row.
    public var summary: String {
        guard let info else {
            return isDangling ? "broken symlink" : "unreadable"
        }
        var parts: [String] = []
        if let label = info.fileType?.label { parts.append(label) }
        if let size = info.sizeLabel { parts.append(size) }
        if let context = info.contextLength { parts.append("\(context / 1024)k ctx") }
        if info.isProjector, let projector = info.vision?.projectorType {
            parts.append(projector)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Paired model

/// A servable model: the language model plus, when it has one, its projector.
public struct LocalModel: Sendable, Codable, Identifiable, Equatable {
    public let model: ModelFile
    public let projector: ModelFile?
    /// How the pairing was decided, so the UI can show its confidence.
    public let pairing: Pairing?
    /// Other paths that resolve to the same file — HuggingFace `blobs/` and
    /// `snapshots/` entries pointing at one physical model.
    public let aliases: [URL]

    public enum Pairing: String, Sendable, Codable {
        /// The projector's key matched the model's key exactly.
        case exactName
        /// One key contained the other.
        case relatedName
        /// Token overlap, or the only projector in the directory.
        case heuristic
    }

    public var id: String { model.id }

    public var displayName: String { model.displayName }

    public var hasVision: Bool { projector != nil }

    public var isUsable: Bool { model.isUsable }

    public var totalSizeBytes: Int64 {
        model.sizeBytes + (projector?.sizeBytes ?? 0)
    }

    /// Everything llama-server needs to serve this model, or `nil` when the
    /// model itself cannot be read.
    public var modelPath: String? { model.resolvedURL?.path }
    public var mmprojPath: String? { projector?.resolvedURL?.path }

    /// Why a projector is unusable, when one was found but cannot be opened.
    /// Worth surfacing: "vision is unavailable because the projector symlink is
    /// broken" is a much better message than silently serving text-only.
    public var projectorProblem: String? {
        guard let projector, !projector.isUsable else { return nil }
        return "the projector at \(projector.filename) is a broken symlink"
    }
}

// MARK: - Scan result

public struct ModelLibraryScan: Sendable, Codable {
    public let roots: [URL]
    public let models: [LocalModel]
    /// Projectors with no model to attach to.
    public let orphanProjectors: [ModelFile]
    /// Files that looked like GGUF but could not be opened, including dangling
    /// symlinks.
    public let unreadable: [ModelFile]
    public let scannedAt: Date
    public let duration: TimeInterval

    public var totalModels: Int { models.count }
    public var visionModels: Int { models.filter(\.hasVision).count }

    /// Everything the user should probably fix, in one list.
    public var warnings: [String] {
        var out: [String] = []
        for file in unreadable where file.isDangling {
            out.append("\(file.filename) is a symlink to a file that is not there")
        }
        for file in orphanProjectors {
            out.append("\(file.filename) looks like a projector with no model to go with it")
        }
        for model in models where model.projectorProblem != nil {
            out.append(model.projectorProblem!)
        }
        return out
    }
}

// MARK: - Scanner

public struct ModelScanner: Sendable {

    public struct Options: Sendable {
        /// Read each file's GGUF header. Costs ~0.4s per multi-gigabyte model,
        /// and buys authoritative classification plus the metadata the optimiser
        /// needs. Turn it off for a name-only listing.
        public var readMetadata: Bool
        /// Follow symlinks and collapse duplicates by their real path.
        public var resolveSymlinks: Bool
        public var skipHiddenFiles: Bool
        /// Directory names never descended into.
        public var excludedDirectories: Set<String>

        public init(
            readMetadata: Bool = true,
            resolveSymlinks: Bool = true,
            skipHiddenFiles: Bool = true,
            excludedDirectories: Set<String> = [".git", ".cache", ".Trash", "node_modules"]
        ) {
            self.readMetadata = readMetadata
            self.resolveSymlinks = resolveSymlinks
            self.skipHiddenFiles = skipHiddenFiles
            self.excludedDirectories = excludedDirectories
        }

        public static let `default` = Options()
    }

    public var options: Options

    public init(options: Options = .default) {
        self.options = options
    }

    // MARK: Scanning

    public func scan(roots: [URL], onProgress: (@Sendable (String) -> Void)? = nil) -> ModelLibraryScan {
        let started = Date()
        var discovered: [ModelFile] = []

        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            for candidate in enumerateGGUF(at: root) {
                onProgress?(candidate.lastPathComponent)
                if let file = describe(candidate) {
                    discovered.append(file)
                }
            }
        }

        // Collapse files that are the same physical model reached by different
        // paths. HuggingFace caches do this constantly: `blobs/x` and
        // `snapshots/<sha>/x` both point at one file, and a naive scan reports
        // the model two or three times.
        let grouped = group(discovered)

        // Dangling symlinks are reported but never listed as models. A broken
        // link is not a servable model, and including it would put an entry in
        // the library that can only ever fail — while the *real* file it was
        // meant to point at may well be present and listed separately.
        let usable = grouped.filter { $0.representative.isUsable }
        let unreadable = grouped.map(\.representative).filter { !$0.isUsable }

        let (models, orphans) = pair(usable)

        return ModelLibraryScan(
            roots: roots,
            models: models.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending },
            orphanProjectors: orphans,
            unreadable: unreadable.sorted { $0.filename < $1.filename },
            scannedAt: started,
            duration: Date().timeIntervalSince(started)
        )
    }

    // MARK: Enumeration

    /// Walk `root` and return every path that is a GGUF file.
    ///
    /// Extension is not enough. A HuggingFace `blobs/` directory stores files
    /// under names like `blob_ornith_q8_0` with no extension at all, so
    /// anything without a recognised extension is checked for the four magic
    /// bytes instead. Reading 4 bytes per file is cheap enough to do blindly.
    /// Extensions never worth opening in search of GGUF magic.
    ///
    /// Files with no extension are always sniffed, because that is exactly how a
    /// HuggingFace `blobs/` directory stores its models (`blob_ornith_q8_0`).
    /// Files with an extension are only sniffed when the extension is not on
    /// this list — otherwise a scan would open every README, PNG and JSON file
    /// in the tree to look at four bytes that are never going to say `GGUF`.
    static let nonModelExtensions: Set<String> = [
        "txt", "md", "markdown", "rst", "json", "yaml", "yml", "toml", "ini",
        "cfg", "conf", "lock", "plist", "csv", "tsv", "log",
        "py", "js", "ts", "sh", "rb", "go", "rs", "c", "h", "cpp", "swift",
        "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "pdf",
        "zip", "tar", "gz", "bz2", "xz", "7z",
        "safetensors", "pt", "pth", "onnx", "pkl", "npz", "bin",
        "html", "css", "xml",
    ]

    /// Whether a filename is worth opening to check for GGUF magic.
    static func isSniffCandidate(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasSuffix(".gguf") { return true }
        let ext = (lower as NSString).pathExtension
        return !nonModelExtensions.contains(ext)
    }

    private func enumerateGGUF(at root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent

            if options.skipHiddenFiles, name.hasPrefix(".") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if options.excludedDirectories.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }

            if Self.hasGGUFExtension(name)
                || (Self.isSniffCandidate(name) && Self.hasGGUFMagic(at: url)) {
                found.append(url)
            }
        }
        return found
    }

    static func hasGGUFExtension(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".gguf")
    }

    /// GGUF files begin with the ASCII bytes `GGUF` (0x47 0x47 0x55 0x46).
    static func hasGGUFMagic(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        return data[data.startIndex] == 0x47
            && data[data.startIndex + 1] == 0x47
            && data[data.startIndex + 2] == 0x55
            && data[data.startIndex + 3] == 0x46
    }

    // MARK: Describing a file

    private func describe(_ url: URL) -> ModelFile? {
        let path = url.path
        let isSymlink = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil

        var resolved: URL?
        if options.resolveSymlinks {
            let target = url.resolvingSymlinksInPath()
            if FileManager.default.fileExists(atPath: target.path) {
                resolved = target
            }
        } else if FileManager.default.fileExists(atPath: path) {
            resolved = url
        }

        let dangling = isSymlink && resolved == nil
        guard resolved != nil || isSymlink else { return nil }

        var size: Int64 = 0
        if let resolved,
           let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
           let number = attributes[.size] as? NSNumber {
            size = number.int64Value
        }

        var info: GGUFModelInfo?
        var readError: String?
        if options.readMetadata, let resolved {
            do {
                info = GGUFModelInfo(header: try GGUFReader.readHeader(at: resolved))
            } catch {
                readError = "\(error)"
            }
        } else if dangling {
            readError = "the symlink target does not exist"
        }

        return ModelFile(
            url: url,
            resolvedURL: resolved,
            isSymlink: isSymlink,
            isDangling: dangling,
            sizeBytes: size,
            info: info,
            readError: readError
        )
    }

    // MARK: Deduplication

    struct Group {
        var representative: ModelFile
        var aliases: [URL]
    }

    /// Collapse files by their real path, keeping the most presentable path as
    /// the representative.
    ///
    /// "Most presentable" means: not buried in a cache directory, has a real
    /// `.gguf` extension, and is the shortest. Given a choice between
    /// `~/Models/Ornith.gguf` and
    /// `~/Models/models--local--ornith/blobs/blob_ornith_q8_0`, the user wants to
    /// see the first one.
    func group(_ files: [ModelFile]) -> [Group] {
        var byPath: [String: [ModelFile]] = [:]
        var order: [String] = []

        for file in files {
            let key = file.resolvedURL?.path ?? "dangling:" + file.url.path
            if byPath[key] == nil { order.append(key) }
            byPath[key, default: []].append(file)
        }

        return order.compactMap { key in
            guard let bucket = byPath[key] else { return nil }
            let sorted = bucket.sorted { presentationScore($0.url) > presentationScore($1.url) }
            guard let best = sorted.first else { return nil }
            return Group(representative: best, aliases: sorted.dropFirst().map(\.url))
        }
    }

    private func presentationScore(_ url: URL) -> Int {
        var score = 0
        if Self.hasGGUFExtension(url.lastPathComponent) { score += 100 }
        let path = url.path
        if !path.contains("/blobs/") { score += 50 }
        if !path.contains("/snapshots/") { score += 50 }
        if !path.contains("/.cache/") { score += 20 }
        // Shorter paths are the ones a person made deliberately.
        score -= min(path.count, 200) / 4
        return score
    }

    // MARK: Pairing

    /// Attach projectors to models.
    ///
    /// Takes the deduplicated groups rather than raw files, so the alias list
    /// survives into the result — a model reachable through `blobs/` and
    /// `snapshots/` should report both paths, not forget one.
    func pair(_ groups: [Group]) -> (models: [LocalModel], orphans: [ModelFile]) {
        let all = groups.map(\.representative)
        var aliasesByID: [String: [URL]] = [:]
        for group in groups {
            aliasesByID[group.representative.id] = group.aliases
        }

        // A file's role comes from its metadata when readable, and from its name
        // otherwise. This is why `DeepSeek-R1-0528.gguf` is treated as the Qwen3
        // model it actually is.
        let projectors = all.filter(\.isProjector)
        let models = all.filter { !$0.isProjector }

        var claimed: Set<String> = []
        var paired: [LocalModel] = []

        // Best matches first, so a confident pairing is never stolen by a
        // weaker one that happened to be processed earlier.
        struct Candidate {
            let modelIndex: Int
            let projectorIndex: Int
            let score: Double
        }

        var candidates: [Candidate] = []
        for (modelIndex, model) in models.enumerated() {
            for (projectorIndex, projector) in projectors.enumerated() {
                // A projector and its model live together. Searching further
                // afield would start pairing a model with an unrelated
                // projector from a different family in the same parent folder.
                guard Self.sameDirectory(model.url, projector.url) else { continue }

                let modelKey = ProjectorNameMatcher.key(for: model.filename, role: .model)
                let projectorKey = ProjectorNameMatcher.key(for: projector.filename, role: .projector)
                let score = ProjectorNameMatcher.score(model: modelKey, projector: projectorKey)

                // A projector's output dimension has to equal the language
                // model's hidden size, or llama.cpp refuses to load the pair.
                // That makes a *mismatch* a hard veto.
                //
                // A match is deliberately not treated as evidence. An earlier
                // version boosted the score when the two were equal, which
                // attached a projector to any model in the folder that happened
                // to share a hidden size — and 4096 is shared by thousands of
                // models. Equality is a necessary condition, not a sufficient
                // one, so it can only ever rule a pairing out.
                if let projected = projector.info?.vision?.projectionDim,
                   let hidden = model.info?.embeddingLength,
                   projected != hidden {
                    continue
                }

                guard score >= ProjectorNameMatcher.minimumScore else { continue }
                candidates.append(Candidate(modelIndex: modelIndex, projectorIndex: projectorIndex, score: score))
            }
        }

        candidates.sort { $0.score > $1.score }

        var assignment: [Int: Int] = [:]
        for candidate in candidates {
            guard assignment[candidate.modelIndex] == nil,
                  !claimed.contains(projectors[candidate.projectorIndex].id) else { continue }
            assignment[candidate.modelIndex] = candidate.projectorIndex
            claimed.insert(projectors[candidate.projectorIndex].id)
        }

        // Last resort: a directory holding exactly one unclaimed projector and
        // one unpaired model is unambiguous even if the names share nothing.
        let unpairedModels = models.indices.filter { assignment[$0] == nil }
        let unclaimedProjectors = projectors.indices.filter { !claimed.contains(projectors[$0].id) }
        if unpairedModels.count == 1, unclaimedProjectors.count == 1,
           let modelIndex = unpairedModels.first, let projectorIndex = unclaimedProjectors.first,
           Self.sameDirectory(models[modelIndex].url, projectors[projectorIndex].url) {
            assignment[modelIndex] = projectorIndex
            claimed.insert(projectors[projectorIndex].id)
        }

        for (modelIndex, model) in models.enumerated() {
            let projectorIndex = assignment[modelIndex]
            let projector = projectorIndex.map { projectors[$0] }
            let pairing = projectorIndex.map { _ -> LocalModel.Pairing in
                let modelKey = ProjectorNameMatcher.key(for: model.filename, role: .model)
                let projectorKey = ProjectorNameMatcher.key(for: projector!.filename, role: .projector)
                if modelKey.compact == projectorKey.compact { return .exactName }
                if ProjectorNameMatcher.score(model: modelKey, projector: projectorKey) >= 0.8 {
                    return .relatedName
                }
                return .heuristic
            }

            paired.append(LocalModel(
                model: model,
                projector: projector,
                pairing: pairing,
                aliases: aliasesByID[model.id] ?? []
            ))
        }

        let orphans = projectors.enumerated()
            .filter { !claimed.contains($0.element.id) }
            .map(\.element)

        return (paired, orphans)
    }

    /// True when two files sit in the same directory, comparing resolved paths
    /// so that a symlink in `snapshots/` and its target in `blobs/` are not
    /// treated as neighbours.
    static func sameDirectory(_ a: URL, _ b: URL) -> Bool {
        (a.resolvingSymlinksInPath().deletingLastPathComponent().path
            == b.resolvingSymlinksInPath().deletingLastPathComponent().path)
            || (a.deletingLastPathComponent().path == b.deletingLastPathComponent().path)
    }
}
