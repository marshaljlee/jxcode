import Foundation
import JXCODECore
import os

actor UsageService {
    static let shared = UsageService()
    private let logger = Logger(subsystem: "com.claudework", category: "UsageService")

    struct UsageEntry: Identifiable, Codable, Hashable {
        public var id = UUID()
        let timestamp: Date
        let model: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int
        let cost: Double
        let sessionId: String
        let projectPath: String
    }

    func loadAllUsage() async -> [UsageEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = home.appendingPathComponent(".claude/projects")
        
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectsDir.path) else {
            return []
        }
        
        var allEntries: [UsageEntry] = []
        var processedHashes = Set<String>()
        
        let projectFolders = (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        
        for folder in projectFolders where folder.hasDirectoryPath {
            let encodedProjectName = folder.lastPathComponent
            let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            
            while let fileURL = enumerator?.nextObject() as? URL {
                if fileURL.pathExtension == "jsonl" {
                    let fileEntries = parseJsonlFile(url: fileURL, encodedProjectName: encodedProjectName, processedHashes: &processedHashes)
                    allEntries.append(contentsOf: fileEntries)
                }
            }
        }
        
        allEntries.sort { $0.timestamp < $1.timestamp }
        return allEntries
    }

    private func parseJsonlFile(url: URL, encodedProjectName: String, processedHashes: inout Set<String>) -> [UsageEntry] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        
        let sessionId = url.deletingPathExtension().lastPathComponent
        var actualProjectPath: String? = nil
        var fileEntries: [UsageEntry] = []
        
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            
            guard let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            
            if actualProjectPath == nil {
                if let cwd = json["cwd"] as? String {
                    actualProjectPath = cwd
                }
            }
            
            guard let type = json["type"] as? String, type == "message",
                  let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }
            
            let msgId = message["id"] as? String ?? ""
            let requestId = json["request_id"] as? String ?? ""
            let uniqueHash = "\(msgId):\(requestId)"
            
            if !msgId.isEmpty && !requestId.isEmpty {
                if processedHashes.contains(uniqueHash) {
                    continue
                }
                processedHashes.insert(uniqueHash)
            }
            
            let inputTokens = usage["input_tokens"] as? Int ?? 0
            let outputTokens = usage["output_tokens"] as? Int ?? 0
            let cacheCreationTokens = usage["cache_creation_input_tokens"] as? Int ?? 0
            let cacheReadTokens = usage["cache_read_input_tokens"] as? Int ?? 0
            
            if inputTokens == 0 && outputTokens == 0 && cacheCreationTokens == 0 && cacheReadTokens == 0 {
                continue
            }
            
            let model = message["model"] as? String ?? "unknown"
            let cost = calculateCost(model: model, input: inputTokens, output: outputTokens, cacheCreate: cacheCreationTokens, cacheRead: cacheReadTokens)
            
            let timestampStr = json["timestamp"] as? String ?? ""
            let timestamp = parseISO8601(timestampStr) ?? Date()
            
            let entry = UsageEntry(
                timestamp: timestamp,
                model: model,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheCreationTokens: cacheCreationTokens,
                cacheReadTokens: cacheReadTokens,
                cost: cost,
                sessionId: sessionId,
                projectPath: actualProjectPath ?? encodedProjectName
            )
            fileEntries.append(entry)
        }
        
        return fileEntries
    }

    private func calculateCost(model: String, input: Int, output: Int, cacheCreate: Int, cacheRead: Int) -> Double {
        let inputPrice: Double
        let outputPrice: Double
        let cacheCreatePrice: Double
        let cacheReadPrice: Double
        
        if model.contains("opus") {
            inputPrice = 15.0
            outputPrice = 75.0
            cacheCreatePrice = 18.75
            cacheReadPrice = 1.50
        } else if model.contains("haiku") {
            inputPrice = 0.25
            outputPrice = 1.25
            cacheCreatePrice = 0.30
            cacheReadPrice = 0.03
        } else {
            inputPrice = 3.00
            outputPrice = 15.00
            cacheCreatePrice = 3.75
            cacheReadPrice = 0.30
        }
        
        let cost = (Double(input) * inputPrice +
                    Double(output) * outputPrice +
                    Double(cacheCreate) * cacheCreatePrice +
                    Double(cacheRead) * cacheReadPrice) / 1_000_000.0
        return cost
    }

    private func parseISO8601(_ str: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: str) { return d }
        let fallback = ISO8601DateFormatter()
        return fallback.date(from: str)
    }
}
