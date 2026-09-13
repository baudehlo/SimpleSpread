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
    }
}
