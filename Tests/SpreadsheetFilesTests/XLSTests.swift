import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

@Suite("Legacy XLS import")
struct XLSTests {
    private func fixture(_ name: String = "business-export") throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "xls", subdirectory: "Fixtures/LegacyXLS"))
        return try Data(contentsOf: url)
    }

    private func address(_ text: String) -> CellAddress { CellAddress(a1: text)! }

    @Test func independentlyWrittenBusinessExport() throws {
        var warnings: [String] = []
        let workbook = try XLSReader.read(data: fixture(), unsupportedContent: &warnings)
        #expect(workbook.sheets.map(\.name) == ["业务报表", "明细", "隐藏"])
        let sheet = try #require(workbook.sheets.first)
        #expect(sheet.value(at: address("A1")) == .string("年度业务汇总"))
        #expect(sheet.value(at: address("A4")) == .string("华东"))
        #expect(sheet.value(at: address("B4")) == .number(1234.5))
        #expect(sheet.value(at: address("B5")) == .number(-42.25))
        #expect(sheet.value(at: address("C4")) == .number(46312))
        #expect(sheet.value(at: address("D4")) == .number(0.125))
        #expect(sheet.value(at: address("C5")) == .bool(true))
        #expect(sheet.value(at: address("D5")) == .bool(false))
        #expect(sheet.value(at: address("A6")) == .string("00123"))
        #expect(sheet.value(at: address("B6")) == .number(1.23456789))
        #expect(sheet.value(at: address("D6")) == .string("café"))
        #expect(sheet.mergedRanges == [CellRange(a1: "A1:D2")!])
        #expect(sheet.columnWidths[0] == 145)
        #expect(sheet.rowHeights[0] == 30)
        #expect(sheet.hiddenRows.contains(6))
        #expect(sheet.hiddenColumns.contains(4))
        #expect(sheet.frozenRows == 3)
        #expect(sheet.frozenColumns == 1)
        #expect(workbook.sheets[2].isHidden)

        let header = workbook.style(at: sheet.cell(at: address("A1")).styleIndex)
        #expect(header.fontName == "Arial")
        #expect(header.fontSize == 14)
        #expect(header.bold)
        #expect(header.textColor == .white)
        #expect(header.fillColor == RGBAColor(red: 36, green: 88, blue: 132))
        #expect(header.horizontalAlignment == .center)
        #expect(header.verticalAlignment == .middle)
        #expect(header.wrapText)
        #expect(header.borders.bottom?.style == .double)
        #expect(header.borders.left?.style == .thin)
        #expect(workbook.style(at: sheet.cell(at: address("B4")).styleIndex).numberFormat.code == "#,##0.00")
        #expect(workbook.style(at: sheet.cell(at: address("C4")).styleIndex).numberFormat.code == "yyyy-mm-dd")
        #expect(warnings.contains { $0.lowercased().contains("formula") })
        #expect(workbook.sheets[1].cell(at: address("A6")).formula == nil)
    }

    @Test func continuedSharedStringsPreserveUnicodeAndCompression() throws {
        let workbook = try XLSReader.read(data: fixture())
        let sheet = workbook.sheets[1]
        #expect(sheet.value(at: address("A1")) == .string("重复文本"))
        #expect(sheet.value(at: address("A2")) == .string("重复文本"))
        #expect(sheet.value(at: address("A3")) == .string(String(repeating: "长文本", count: 4000)))
        #expect(sheet.value(at: address("A4")) == .string(String(repeating: "ASCII-", count: 2000)))
        #expect(sheet.value(at: address("A5")) == .string("emoji 😀"))
    }

    @Test func dates1904NormalizeWithoutChangingOrdinaryNumbers() throws {
        let workbook = try XLSReader.read(data: fixture("dates-1904"))
        #expect(workbook.sheets[0].value(at: address("A1")) == .number(46312))
        #expect(workbook.sheets[0].value(at: address("A2")) == .number(42.5))
    }

    @Test func tabOrderPaletteAndDefaultLayout() throws {
        let workbook = try XLSReader.read(data: fixture("layout-and-tab-order"))
        #expect(workbook.sheets.map(\.name) == ["PhysicalSecond", "PhysicalFirst"])
        let sheet = workbook.sheets[1]
        #expect(sheet.defaultRowHeight == 20)
        #expect(sheet.value(at: address("A4")) == .string("control \u{0080}"))
        #expect(sheet.frozenRows == 0)
        #expect(sheet.frozenColumns == 0)
        #expect(workbook.style(at: sheet.cell(at: address("A1")).styleIndex).textColor
                == RGBAColor(red: 255, green: 0, blue: 0))
        #expect(workbook.style(at: sheet.cell(at: address("A2")).styleIndex).fillColor == .white)
        #expect(workbook.style(at: sheet.cell(at: address("A5")).styleIndex).fillColor == nil)
        #expect(workbook.style(at: sheet.styleIndex(at: address("B20"))).numberFormat.code == "0.00%")
        #expect(workbook.style(at: sheet.styleIndex(at: address("F3"))).bold)
    }

    @Test func formulaCachesBecomeValuesAndSurviveRecalculation() throws {
        var warnings: [String] = []
        let workbook = try XLSReader.read(data: fixture("formula-caches"), unsupportedContent: &warnings)
        let sheet = workbook.sheets[0]
        let engine = CalculationEngine(workbook: workbook)
        engine.recalculateAll()
        #expect(sheet.value(at: address("A1")) == .number(3))
        #expect(sheet.value(at: address("A2")) == .bool(true))
        #expect(sheet.value(at: address("A3")) == .error(.div0))
        #expect(sheet.value(at: address("A4")).isEmpty)
        #expect(sheet.value(at: address("A5")) == .string("缓存结果"))
        #expect(sheet.cells.values.allSatisfy { $0.formula == nil })
        #expect(warnings.contains { $0.contains("cached values") })
    }

    @Test func editAndSaveAsXLSXPreservesImportedContent() throws {
        let workbook = try XLSReader.read(data: fixture())
        workbook.sheets[0].setCell(Cell(value: .string("已编辑")), at: address("A4"))
        let saved = try XLSXWriter.data(for: workbook)
        let reopened = try XLSXReader.read(data: saved)
        #expect(reopened.sheets.count == workbook.sheets.count)
        for (before, after) in zip(workbook.sheets, reopened.sheets) {
            #expect(after.name == before.name)
            #expect(after.mergedRanges == before.mergedRanges)
            #expect(after.hiddenRows == before.hiddenRows)
            #expect(after.hiddenColumns == before.hiddenColumns)
            #expect(after.isHidden == before.isHidden)
            #expect(after.frozenRows == before.frozenRows)
            #expect(after.frozenColumns == before.frozenColumns)
            for (cellAddress, cell) in before.cells {
                #expect(after.value(at: cellAddress) == cell.value, "\(before.name) \(cellAddress)")
                let beforeStyle = workbook.style(at: before.styleIndex(at: cellAddress))
                let afterStyle = reopened.style(at: after.styleIndex(at: cellAddress))
                #expect(afterStyle == beforeStyle, "\(before.name) \(cellAddress)")
            }
            for (column, width) in before.columnWidths {
                #expect(abs((after.columnWidths[column] ?? 0) - width) < 0.01)
            }
            for (row, height) in before.rowHeights {
                #expect(abs((after.rowHeights[row] ?? 0) - height) < 0.01)
            }
        }
        #expect(reopened.sheets[0].value(at: address("A4")) == .string("已编辑"))
    }

    @Test func cancellationStopsImport() throws {
        let data = try fixture()
        var warnings: [String] = []
        #expect(throws: XLSError.cancelled) {
            _ = try XLSReader.read(data: data, unsupportedContent: &warnings, progress: { _ in false })
        }
    }

    @Test func invalidAndTruncatedFilesThrow() throws {
        #expect(throws: (any Error).self) {
            _ = try XLSReader.read(data: Data("not an XLS workbook".utf8))
        }
        let data = try fixture()
        for length in [0, 8, 511, 512, 1024, data.count - 512] {
            #expect(throws: (any Error).self) {
                _ = try XLSReader.read(data: Data(data.prefix(length)))
            }
        }
    }
}
