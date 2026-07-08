import Foundation

/// Application Support directory scoped by the running bundle identifier.
/// Production (`com.idealapp.JXCODE`) keeps the historical `JXCODE` directory.
/// Any other bundle id (e.g. a dev build at `com.idealapp.JXCODE.dev`) maps to
/// `JXCODE.<suffix>` so alternate builds never share state with production.
public enum AppSupport {
    public static let bundleScopedURL: URL = {
        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return root.appendingPathComponent(directoryName, isDirectory: true)
    }()

    private static var directoryName: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.idealapp.JXCODE"
        if bundleID == "com.idealapp.JXCODE" { return "JXCODE" }
        let suffix = bundleID.split(separator: ".").last.map(String.init) ?? "dev"
        return "JXCODE.\(suffix)"
    }
}
