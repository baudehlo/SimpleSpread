import AppKit
import SwiftUI

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

/// Owns the Open Recent list: persistence (UserDefaults), security-scoped
/// bookmarks for sandbox-safe reopening, and system menu/Dock integration.
@MainActor
public final class RecentFilesManager: ObservableObject {
    public static let shared = RecentFilesManager()

    @Published public private(set) var entries: [RecentEntry] = []

    private let defaults: UserDefaults
    private let storageKey = "SSRecentDocuments"
    /// Scoped resources we've started accessing this session; relinquished at quit.
    private var activeScopes: Set<URL> = []

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    private func load() {
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([RecentEntry].self, from: data) {
            entries = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: storageKey)
        }
    }

    /// Record a just-opened or just-saved document. Creates a security-scoped
    /// bookmark (the file must currently be accessible) and moves it to the top.
    public func record(_ url: URL) {
        let standardized = url.standardizedFileURL
        let bookmark = (try? standardized.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)) ?? Data()
        let entry = RecentEntry(path: standardized.path, bookmark: bookmark)
        entries = RecentFilesList.adding(entry, to: entries)
        persist()
        // System integration (Dock menu / app-icon recents).
        NSDocumentController.shared.noteNewRecentDocumentURL(standardized)
    }

    /// Resolve an entry's bookmark and begin security-scoped access, returning a
    /// URL the app may read. Access is held for the session (released at quit)
    /// so subsequent saves to the same file also work. Returns nil if the
    /// bookmark can't be resolved (file moved/deleted).
    public func urlForOpening(_ entry: RecentEntry) -> URL? {
        guard !entry.bookmark.isEmpty else {
            // No bookmark (unsandboxed record); fall back to the raw path.
            return entry.exists ? entry.url : nil
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: entry.bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale) else {
            return nil
        }
        if url.startAccessingSecurityScopedResource() {
            activeScopes.insert(url)
        }
        // Refresh a stale bookmark now that we have access again.
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                    includingResourceValuesForKeys: nil,
                                                    relativeTo: nil) {
            let refreshed = RecentEntry(path: url.path, bookmark: fresh)
            entries = RecentFilesList.adding(refreshed, to: entries)
            persist()
        }
        return url
    }

    /// Relinquish all scoped resources (call at app termination).
    public func releaseAllScopes() {
        for url in activeScopes { url.stopAccessingSecurityScopedResource() }
        activeScopes.removeAll()
    }

    public func clear() {
        entries = []
        persist()
        NSDocumentController.shared.clearRecentDocuments(nil)
    }
}
