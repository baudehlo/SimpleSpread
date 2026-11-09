import Foundation
import Testing
@testable import SpreadsheetUI

/// Opening a file already in a window brings that window forward, so the
/// match must see through the different ways one file can be named.
@Suite("Same file on disk")
struct SameFileTests {
    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SameFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func matchesThroughSymlinksCaseAndHardLinks() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Budget.xlsx")
        try Data("x".utf8).write(to: file)
        let other = dir.appendingPathComponent("Other.xlsx")
        try Data("y".utf8).write(to: other)

        let symlink = dir.appendingPathComponent("link.xlsx")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
        let hardLink = dir.appendingPathComponent("hard.xlsx")
        try FileManager.default.linkItem(at: file, to: hardLink)

        #expect(file.refersToSameFile(as: file))
        #expect(file.refersToSameFile(as: dir.appendingPathComponent("sub/../Budget.xlsx")))
        #expect(symlink.refersToSameFile(as: file))
        #expect(hardLink.refersToSameFile(as: file))
        #expect(!file.refersToSameFile(as: other))
        // The default APFS volume is case-insensitive.
        #expect(dir.appendingPathComponent("budget.XLSX").refersToSameFile(as: file))
        // A file that doesn't exist matches only itself.
        let missing = dir.appendingPathComponent("missing.xlsx")
        #expect(missing.refersToSameFile(as: missing))
        #expect(!missing.refersToSameFile(as: file))
    }
}
