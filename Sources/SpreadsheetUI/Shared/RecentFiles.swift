import Foundation

/// One remembered document: its path (for display + existence checks) and a
/// security-scoped bookmark (so a sandboxed app can actually reopen it).
public struct RecentEntry: Codable, Equatable, Sendable {
    public var path: String
    public var bookmark: Data

    public var url: URL { URL(fileURLWithPath: path) }
    public var displayName: String { (path as NSString).lastPathComponent }
    public var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// Pure most-recent-first list logic (dedup by path, capped) — the researched
/// "Open Recent" behavior, kept separate so it's unit-testable.
public enum RecentFilesList {
    public static let maxCount = 10

    /// Insert `entry` at the front, remove any prior entry for the same path,
    /// and cap the list. Paths are compared by standardized file path.
    public static func adding(_ entry: RecentEntry, to list: [RecentEntry],
                              max: Int = maxCount) -> [RecentEntry] {
        let key = standardized(entry.path)
        var result = list.filter { standardized($0.path) != key }
        result.insert(entry, at: 0)
        if result.count > max { result.removeLast(result.count - max) }
        return result
    }

    static func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
