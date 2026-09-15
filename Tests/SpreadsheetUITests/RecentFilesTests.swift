import Foundation
import Testing
@testable import SpreadsheetUI

@Suite("Recent files list logic")
struct RecentFilesListTests {
    func entry(_ path: String) -> RecentEntry {
        RecentEntry(path: path, bookmark: Data())
    }

    @Test func addsMostRecentFirst() {
        var list: [RecentEntry] = []
        list = RecentFilesList.adding(entry("/a.xlsx"), to: list)
        list = RecentFilesList.adding(entry("/b.xlsx"), to: list)
        list = RecentFilesList.adding(entry("/c.xlsx"), to: list)
        #expect(list.map(\.path) == ["/c.xlsx", "/b.xlsx", "/a.xlsx"])
    }

    @Test func deduplicatesAndPromotes() {
        var list = [entry("/a.xlsx"), entry("/b.xlsx"), entry("/c.xlsx")]
        // Re-adding an existing path moves it to the front, no duplicate.
        list = RecentFilesList.adding(entry("/c.xlsx"), to: list)
        #expect(list.map(\.path) == ["/c.xlsx", "/a.xlsx", "/b.xlsx"])
        #expect(list.count == 3)
    }

    @Test func dedupIsPathStandardized() {
        var list = [entry("/dir/a.xlsx")]
        list = RecentFilesList.adding(entry("/dir/./a.xlsx"), to: list)
        #expect(list.count == 1)
    }

    @Test func capsAtMax() {
        var list: [RecentEntry] = []
        for i in 0..<15 {
            list = RecentFilesList.adding(entry("/f\(i).xlsx"), to: list, max: 10)
        }
        #expect(list.count == 10)
        // Newest kept, oldest dropped.
        #expect(list.first?.path == "/f14.xlsx")
        #expect(list.last?.path == "/f5.xlsx")
        #expect(!list.contains { $0.path == "/f4.xlsx" })
    }

    @Test func defaultMaxIsTen() {
        #expect(RecentFilesList.maxCount == 10)
    }
}

@MainActor
@Suite("Recent files manager")
struct RecentFilesManagerTests {
    func freshManager() -> (RecentFilesManager, URL) {
        let suite = "simplespread-recent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recent-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (RecentFilesManager(defaults: defaults), dir)
    }

    func makeFile(_ dir: URL, _ name: String) -> URL {
        let url = dir.appendingPathComponent(name)
        try? Data("x".utf8).write(to: url)
        return url
    }

    @Test func recordAddsEntries() {
        let (mgr, dir) = freshManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        mgr.record(makeFile(dir, "a.xlsx"))
        mgr.record(makeFile(dir, "b.xlsx"))
        #expect(mgr.entries.map(\.displayName) == ["b.xlsx", "a.xlsx"])
        #expect(mgr.entries.allSatisfy { $0.exists })
    }

    @Test func recordDeduplicates() {
        let (mgr, dir) = freshManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = makeFile(dir, "a.xlsx")
        mgr.record(a)
        mgr.record(makeFile(dir, "b.xlsx"))
        mgr.record(a) // re-open a → moves to front
        #expect(mgr.entries.map(\.displayName) == ["a.xlsx", "b.xlsx"])
    }

    @Test func persistsAcrossManagers() {
        let suite = "simplespread-recent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recent-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("keep.xlsx")
        try? Data("x".utf8).write(to: url)

        let first = RecentFilesManager(defaults: defaults)
        first.record(url)
        // A new manager on the same defaults reloads the list.
        let second = RecentFilesManager(defaults: defaults)
        #expect(second.entries.map(\.displayName) == ["keep.xlsx"])
    }

    @Test func clearEmptiesList() {
        let (mgr, dir) = freshManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        mgr.record(makeFile(dir, "a.xlsx"))
        #expect(!mgr.entries.isEmpty)
        mgr.clear()
        #expect(mgr.entries.isEmpty)
    }

    @Test func missingFileReportsNotExists() {
        let (mgr, dir) = freshManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = makeFile(dir, "gone.xlsx")
        mgr.record(url)
        try? FileManager.default.removeItem(at: url)
        #expect(mgr.entries.first?.exists == false)
    }
}
