import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles
@testable import SpreadsheetUI

/// ⌘S over a file holding things SimpleSpread can't write back asks first.
@MainActor
@Suite("Saving files with unsupported content")
struct SaveFidelityTests {
    func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simplespread-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// An .xlsx with a comments part and conditional formatting.
    func fileWithComments(in dir: URL) throws -> URL {
        let workbook = Workbook.newDocument()
        workbook.sheets[0].setCell(Cell(value: .number(1)), at: CellAddress(row: 0, column: 0))
        let reader = try ZipArchiveReader(data: XLSXWriter.data(for: workbook))
        var writer = ZipArchiveWriter()
        for entry in reader.entries {
            var data = try reader.contents(of: entry)
            if entry.name == "[Content_Types].xml" {
                data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(
                    of: "</Types>",
                    with: "<Override PartName=\"/xl/comments1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.comments+xml\"/></Types>").utf8)
            } else if entry.name == "xl/worksheets/sheet1.xml" {
                data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(
                    of: "<pageMargins",
                    with: "<conditionalFormatting sqref=\"A1\"><cfRule type=\"cellIs\" priority=\"1\" operator=\"greaterThan\"><formula>0</formula></cfRule></conditionalFormatting><pageMargins").utf8)
            }
            writer.addEntry(name: entry.name, data: data)
        }
        writer.addEntry(name: "xl/comments1.xml", data: Data("<comments/>".utf8))
        let url = dir.appendingPathComponent("Budget.xlsx")
        try writer.finalize().write(to: url)
        return url
    }

    @Test func openingListsWhatSavingWouldRemove() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try SpreadsheetDocument.open(url: fileWithComments(in: dir))
        #expect(doc.unsupportedContent == ["comments", "conditional formatting"])
    }

    @Test func theFirstSaveInPlaceAsksAndThenNotAgain() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try fileWithComments(in: dir)
        let doc = try SpreadsheetDocument.open(url: url)
        #expect(DocumentSaving.plan(for: doc) == .confirmLoss(url, ["comments", "conditional formatting"]))
        // Save As says what the copy leaves out, without asking.
        #expect(DocumentSaving.plan(for: doc, as: true)
                == .choose(lossNote: "This copy won’t include the comments and conditional formatting from “Budget.xlsx”, which SimpleSpread can’t save. The original file is not changed."))

        // "Save Anyway" (or saving a copy) is the answer for this document.
        try doc.save(to: url)
        #expect(DocumentSaving.plan(for: doc) == .write(url))
        #expect(DocumentSaving.plan(for: doc, as: true) == .choose(lossNote: nil))
    }

    @Test func plainFilesSaveWithoutAsking() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("plain.xlsx")
        try SpreadsheetDocument().save(to: url)
        let doc = try SpreadsheetDocument.open(url: url)
        #expect(doc.unsupportedContent.isEmpty)
        #expect(DocumentSaving.plan(for: doc) == .write(url))
        #expect(DocumentSaving.plan(for: SpreadsheetDocument()) == .choose(lossNote: nil))
    }

    @Test func listsReadNaturally() {
        #expect(DocumentSaving.list(["comments"]) == "comments")
        #expect(DocumentSaving.list(["3 charts", "comments"]) == "3 charts and comments")
        #expect(DocumentSaving.list(["3 charts", "comments", "hyperlinks"]) == "3 charts, comments and hyperlinks")
        #expect(DocumentSaving.copyName(for: "Budget.xlsx") == "Budget copy.xlsx")
    }
}
