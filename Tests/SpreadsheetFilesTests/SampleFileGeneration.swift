import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// When SIMPLESPREAD_SAMPLE_DIR is set, writes sample .xlsx/.csv files there
/// for external validation (xmllint, Excel/Numbers/Sheets manual checks).
/// Skipped in normal runs.
@Suite("Sample file generation")
struct SampleFileGeneration {
    @Test func writeSampleFiles() throws {
        guard let dir = ProcessInfo.processInfo.environment["SIMPLESPREAD_SAMPLE_DIR"] else {
            return
        }
        let wb = Workbook.newDocument()
        let engine = CalculationEngine(workbook: wb)
        let id = wb.sheets[0].id
        func addr(_ a1: String) -> AbsoluteAddress {
            AbsoluteAddress(sheetID: id, address: CellAddress(a1: a1)!)
        }
        engine.setCellValue(.string("Item"), at: addr("A1"))
        engine.setCellValue(.string("Price"), at: addr("B1"))
        engine.setCellValue(.string("When"), at: addr("C1"))
        engine.setCellValue(.string("Widget"), at: addr("A2"))
        engine.setCellValue(.number(9.99), at: addr("B2"))
        engine.setCellValue(.string("Gadget & \"Co\" <tags>"), at: addr("A3"))
        engine.setCellValue(.number(24.5), at: addr("B3"))
        engine.setCellFormula("SUM(B2:B3)", at: addr("B4"))
        engine.setCellFormula("IF(B4>30,\"big\",\"small\")", at: addr("C4"))
        wb.modifyStyle(in: CellRange(a1: "A1:C1")!, ofSheetID: id) { $0.bold = true }
        var dateStyle = CellStyle()
        dateStyle.numberFormat = .date
        let dateIdx = wb.styles.index(for: dateStyle)
        engine.setCellValue(.number(ExcelDate.serial(year: 2026, month: 9, day: 13)), at: addr("C2"))
        var cell = wb.sheets[0].cell(at: CellAddress(a1: "C2")!)
        cell.styleIndex = dateIdx
        wb.sheets[0].setCell(cell, at: CellAddress(a1: "C2")!)
        wb.sheets[0].columnWidths[0] = 140
        wb.sheets[0].frozenRows = 1
        let extra = wb.addSheet(named: "Summary")
        extra.setCell(Cell(value: .empty, formula: "Sheet1!B4*2"), at: CellAddress(a1: "A1")!)
        engine.rebuildAll()

        let xlsx = try XLSXWriter.data(for: wb)
        try xlsx.write(to: URL(fileURLWithPath: dir).appendingPathComponent("sample.xlsx"))
        let csv = CSV.export(sheet: wb.sheets[0], workbook: wb)
        try csv.write(to: URL(fileURLWithPath: dir).appendingPathComponent("sample.csv"))
        try layoutSample().write(to: URL(fileURLWithPath: dir).appendingPathComponent("layout.xlsx"))
    }

    /// Borders, merged cells, frozen panes, hidden rows and an AutoFilter
    /// with value and condition criteria, on a sheet whose name needs quotes.
    func layoutSample() throws -> Data {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        _ = wb.renameSheet(withID: sheet.id, to: "Fruit Sales")
        let engine = CalculationEngine(workbook: wb)
        func put(_ a1: String, _ value: CellValue) {
            engine.setCellValue(value, at: AbsoluteAddress(sheetID: sheet.id, address: CellAddress(a1: a1)!))
        }
        put("A1", .string("Quarterly fruit sales"))
        sheet.mergedRanges = [CellRange(a1: "A1:C1")!]
        put("A2", .string("Fruit")); put("B2", .string("Region")); put("C2", .string("Qty"))
        let rows: [(String, String, Double)] = [("Apple", "North", 12), ("Pear", "South", 3),
                                                 ("Fig", "North", 45), ("Apple", "South", 7),
                                                 ("Plum", "East", 20)]
        for (i, row) in rows.enumerated() {
            put("A\(i + 3)", .string(row.0)); put("B\(i + 3)", .string(row.1)); put("C\(i + 3)", .number(row.2))
        }
        wb.modifyStyle(in: CellRange(a1: "A1")!, ofSheetID: sheet.id) {
            $0.bold = true; $0.horizontalAlignment = .center; $0.fontSize = 14
            $0.borders = CellBorders(bottom: BorderLine(.double))
        }
        wb.modifyStyle(in: CellRange(a1: "A2:C2")!, ofSheetID: sheet.id) {
            $0.bold = true
            $0.borders.bottom = BorderLine(.medium, color: RGBAColor(red: 0x1F, green: 0x4E, blue: 0x79))
        }
        wb.modifyStyle(in: CellRange(a1: "A3:C7")!, ofSheetID: sheet.id) {
            $0.borders = CellBorders(top: BorderLine(.hair), bottom: BorderLine(.hair),
                                     left: BorderLine(.dotted), right: BorderLine(.dashed))
        }
        sheet.frozenRows = 2
        sheet.frozenColumns = 1
        sheet.autoFilter = AutoFilter(range: CellRange(a1: "A2:C7")!, columns: [
            0: ColumnFilter(values: ["Apple", "Fig", "Plum"]),
            2: ColumnFilter(conditions: [FilterCondition(.greaterThan, "5")]),
        ])
        wb.applyAutoFilter(onSheetID: sheet.id)
        engine.rebuildAll()
        return try XLSXWriter.data(for: wb)
    }

    @Test func layoutSampleFiltersAsExpected() throws {
        let wb = try XLSXReader.read(data: layoutSample())
        let sheet = wb.sheets[0]
        // Pear (row 4) fails the values; nothing else fails Qty > 5.
        #expect(sheet.hiddenRows == [3])
        #expect(sheet.mergedRanges == [CellRange(a1: "A1:C1")!])
        #expect(sheet.autoFilter?.columns.count == 2)
    }
}
