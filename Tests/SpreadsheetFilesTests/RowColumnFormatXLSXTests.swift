import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// Whole-row and whole-column formats and hidden columns, in and out of
/// XLSX (`col@style`, `col@hidden`, `row@s` with `customFormat`).
@Suite("Row and column formats in XLSX")
struct RowColumnFormatXLSXTests {
    static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
    static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

    /// A file whose column B is bold and red-filled and row 3 is italic,
    /// with B1 styled as its column (as Excel writes it), B2 left plain on
    /// purpose (no s), and column D hidden.
    static func file() throws -> Data {
        let styles = header + """
        <styleSheet xmlns="\(main)"><fonts count="3"><font><sz val="11"/><name val="Calibri"/></font>\
        <font><b/><sz val="11"/><name val="Calibri"/></font><font><i/><sz val="11"/><name val="Calibri"/></font></fonts>\
        <fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>\
        <fill><patternFill patternType="solid"><fgColor rgb="FFFF0000"/></patternFill></fill></fills>\
        <borders count="1"><border/></borders><cellStyleXfs count="1"><xf/></cellStyleXfs>\
        <cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>\
        <xf numFmtId="0" fontId="1" fillId="2" borderId="0" applyFont="1" applyFill="1"/>\
        <xf numFmtId="0" fontId="2" fillId="0" borderId="0" applyFont="1"/></cellXfs></styleSheet>
        """
        let sheet = """
        <cols><col min="2" max="2" width="12" customWidth="1" style="1"/>\
        <col min="4" max="4" width="9" hidden="1"/></cols><sheetData>\
        <row r="1"><c r="A1"><v>1</v></c><c r="B1" s="1"><v>2</v></c></row>\
        <row r="2"><c r="B2"><v>3</v></c></row>\
        <row r="3" s="2" customFormat="1"><c r="A3" s="2"><v>4</v></c></row></sheetData>
        """
        let data = try UnsupportedContentTests.package(
            sheets: [("S", nil, sheet)],
            extraParts: [("xl/styles.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml",
                          Data(styles.utf8))])
        // The test package names no styles part: add the relationship.
        let zip = try ZipArchiveReader(data: data)
        var out = ZipArchiveWriter()
        for entry in zip.entries {
            var bytes = try zip.contents(of: entry)
            if entry.name == "xl/_rels/workbook.xml.rels" {
                bytes = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "</Relationships>", with:
                    "<Relationship Id=\"rIdSt\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>").utf8)
            }
            out.addEntry(name: entry.name, data: bytes)
        }
        return try out.finalize()
    }

    func a(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }

    @Test func readingKeepsRowAndColumnFormats() throws {
        var report = XLSXReadReport()
        let workbook = try XLSXReader.read(data: Self.file(), report: &report)
        #expect(report.unsupportedContent.isEmpty, "\(report.unsupportedContent)")
        let sheet = workbook.sheets[0]
        #expect(sheet.hiddenColumns == [3])
        #expect(sheet.columnStyles.keys.sorted() == [1])
        #expect(sheet.rowStyles.keys.sorted() == [2])
        func style(_ a1: String) -> CellStyle { workbook.style(at: sheet.styleIndex(at: a(a1))) }
        // B1 was written with its column's style: it inherits now.
        #expect(sheet.cell(at: a("B1")).styleIndex == 0)
        #expect(style("B1").bold && style("B1").fillColor != nil)
        // A blank in column B shows the column; the row's format beats it.
        #expect(style("B9").bold && style("B9").fillColor != nil)
        #expect(style("B3").italic && !style("B3").bold)
        #expect(style("Z3").italic)
        // B2 had no s: it's plain, whatever its column says.
        #expect(sheet.cell(at: a("B2")).styleIndex != 0)
        #expect(style("B2") == .default)
    }

    @Test func savingWritesThemBackAndCellsAsTheyLook() throws {
        let workbook = try XLSXReader.read(data: Self.file())
        let saved = try XLSXWriter.data(for: workbook)
        let sheet = try Package(saved).string("xl/worksheets/sheet1.xml")
        #expect(sheet.contains("<col min=\"2\" max=\"2\" width=\"12\" customWidth=\"1\" style="))
        #expect(sheet.contains("<col min=\"4\" max=\"4\" width=\"9\" customWidth=\"1\" hidden=\"1\"/>"))
        #expect(sheet.contains("<row r=\"3\" s="))
        #expect(sheet.contains("customFormat=\"1\""))
        // A cell inheriting is written with the style it shows (in the file a
        // cell without s is plain); the plain cell keeps a plain style.
        let again = try XLSXReader.read(data: saved)
        let reread = again.sheets[0]
        func style(_ a1: String) -> CellStyle { again.style(at: reread.styleIndex(at: a(a1))) }
        #expect(style("B1").bold && style("B9").bold && style("B3").italic)
        #expect(style("B2") == .default)
        #expect(reread.hiddenColumns == [3])
        // And our own file saves the same twice.
        let once = try XLSXWriter.data(for: again)
        let twice = try XLSXWriter.data(for: XLSXReader.read(data: once))
        #expect(try Package(once).part("xl/worksheets/sheet1.xml") == Package(twice).part("xl/worksheets/sheet1.xml"))
    }

    @Test func aFormatAcrossEveryColumnIsOneColElement() throws {
        let workbook = Workbook.newDocument()
        let sheet = workbook.sheets[0]
        let bold = workbook.styleIndex(for: CellStyle(bold: true))
        for column in 0..<CellAddress.maxColumns { sheet.columnStyles[column] = bold }
        let xml = XLSXWriter.colsXML(sheet)
        #expect(xml.components(separatedBy: "<col ").count == 2)
        #expect(xml.contains("min=\"1\" max=\"16384\""))
        let reread = try XLSXReader.read(data: XLSXWriter.data(for: workbook)).sheets[0]
        #expect(reread.columnStyles.count == CellAddress.maxColumns)
        #expect(reread.columnWidths.isEmpty)
    }

    @Test func insertsAndDeletesMoveThem() throws {
        let workbook = try XLSXReader.read(data: Self.file())
        let sheet = workbook.sheets[0]
        WorkbookOperations.insertColumns(in: workbook, sheetID: sheet.id, at: 0, count: 1)
        #expect(sheet.columnStyles.keys.sorted() == [2])
        #expect(sheet.hiddenColumns == [4])
        WorkbookOperations.deleteRows(in: workbook, sheetID: sheet.id, at: 0, count: 1)
        #expect(sheet.rowStyles.keys.sorted() == [1])
        let edit = try #require(WorkbookOperations.deleteColumns(in: workbook, sheetID: sheet.id, at: 2, count: 1))
        #expect(sheet.columnStyles.isEmpty)
        _ = edit.undo(in: workbook)
        #expect(sheet.columnStyles.keys.sorted() == [2])
    }
}
