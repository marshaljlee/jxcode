import Foundation

struct EnvFileParser {
    static func parse(filePath: String) -> [String: String] {
        var env: [String: String] = [:]
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return env
        }
        
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                env[key] = value
            }
        }
        return env
    }
    
    static func update(filePath: String, key: String, value: String) throws {
        let content: String
        if FileManager.default.fileExists(atPath: filePath) {
            content = try String(contentsOfFile: filePath, encoding: .utf8)
        } else {
            content = ""
        }
        
        var lines = content.components(separatedBy: .newlines)
        var keyFound = false
        
        for i in 0..<lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let currentKey = String(parts[0]).trimmingCharacters(in: .whitespaces)
                if currentKey == key {
                    lines[i] = "\(key)=\(value)"
                    keyFound = true
                    break
                }
            }
        }
        
        if !keyFound {
            if lines.last?.isEmpty == false {
                lines.append("")
            }
            lines.append("\(key)=\(value)")
        }
        
        let newContent = lines.joined(separator: "\n")
        
        // Ensure parent folder exists
        let dirPath = (filePath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: dirPath) {
            try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true, attributes: nil)
        }
        
        try newContent.write(toFile: filePath, atomically: true, encoding: .utf8)
    }
}
