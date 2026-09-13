import Testing
@testable import SpreadsheetCore

@Suite("Calculation engine")
struct CalculationEngineTests {
    @Test func dependencyChainRecalculates() {
        let h = Harness(cells: ["A1": "1", "B1": "=A1*2", "C1": "=B1+10"])
        #expect(h.value("C1") == .number(12))
        h.set("A1", "5")
        #expect(h.value("B1") == .number(10))
        #expect(h.value("C1") == .number(20))
    }

    @Test func rangeDependencyRecalculates() {
        let h = Harness(cells: ["A1": "1", "A2": "2", "B1": "=SUM(A1:A10)"])
        #expect(h.value("B1") == .number(3))
        h.set("A7", "10")
        #expect(h.value("B1") == .number(13))
    }

    @Test func wholeColumnDependencyRecalculates() {
        let h = Harness(cells: ["A1": "1", "B1": "=SUM(A:A)"])
        #expect(h.value("B1") == .number(1))
        h.set("A500", "9")
        #expect(h.value("B1") == .number(10))
    }

    @Test func clearingCellRecalculates() {
        let h = Harness(cells: ["A1": "5", "B1": "=A1+1"])
        #expect(h.value("B1") == .number(6))
        let addr = AbsoluteAddress(sheetID: h.sheetID, address: CellAddress(a1: "A1")!)
        h.engine.clearCell(at: addr)
        #expect(h.value("B1") == .number(1))
    }

    @Test func replacingFormulaUpdatesGraph() {
        let h = Harness(cells: ["A1": "1", "B1": "10", "C1": "=A1"])
        #expect(h.value("C1") == .number(1))
        h.set("C1", "=B1")
        #expect(h.value("C1") == .number(10))
        // Old edge must be gone: changing A1 leaves C1 alone.
        h.set("A1", "99")
        #expect(h.value("C1") == .number(10))
    }

    @Test func directCircularReference() {
        let h = Harness()
        h.set("A1", "=A1+1")
        #expect(h.value("A1").errorValue == .circular)
    }

    @Test func mutualCircularReference() {
        let h = Harness()
        h.set(cells: ["A1": "=B1", "B1": "=A1"])
        // Both cells end up errored (circular or propagated).
        #expect(h.value("A1").errorValue != nil)
        #expect(h.value("B1").errorValue != nil)
    }

    @Test func cycleBrokenByEditRecovers() {
        let h = Harness()
        h.set(cells: ["A1": "=B1", "B1": "=A1"])
        h.set("B1", "7")
        #expect(h.value("A1") == .number(7))
        #expect(h.value("B1") == .number(7))
    }

    @Test func selfRangeCircular() {
        let h = Harness()
        h.set("A1", "=SUM(A1:A3)")
        #expect(h.value("A1").errorValue == .circular)
    }

    final class CounterBox: @unchecked Sendable {
        var value = 0.0
    }

    @Test func volatileRecalculatesOnAnyEdit() {
        let counter = CounterBox()
        let clock = EvalClock(
            todaySerial: { counter.value },
            nowSerial: { counter.value },
            random: { counter.value }
        )
        let wb = Workbook.newDocument()
        let engine = CalculationEngine(workbook: wb, clock: clock)
        let sheetID = wb.sheets[0].id
        engine.setCellFormula("RAND()", at: AbsoluteAddress(sheetID: sheetID, address: CellAddress(a1: "A1")!))
        counter.value = 42
        // Editing an unrelated cell re-rolls the volatile cell.
        engine.setCellValue(.number(1), at: AbsoluteAddress(sheetID: sheetID, address: CellAddress(a1: "Z9")!))
        #expect(wb.sheets[0].value(at: CellAddress(a1: "A1")!) == .number(42))
    }

    @Test func parseErrorCommitsAsErrorValue() {
        let h = Harness()
        h.set("A1", "=1+")
        #expect(h.value("A1").errorValue == .parse)
        // The broken formula text is preserved.
        #expect(h.workbook.sheets[0].cell(at: CellAddress(a1: "A1")!).formula == "1+")
        // Fixing it recovers.
        h.set("A1", "=1+1")
        #expect(h.value("A1") == .number(2))
    }

    @Test func crossSheetDependency() {
        let h = Harness()
        let sheet2 = h.workbook.addSheet(named: "Data")
        h.engine.setCellValue(.number(5), at: AbsoluteAddress(sheetID: sheet2.id, address: CellAddress(a1: "A1")!))
        h.set("B1", "=Data!A1*3")
        #expect(h.value("B1") == .number(15))
        h.engine.setCellValue(.number(7), at: AbsoluteAddress(sheetID: sheet2.id, address: CellAddress(a1: "A1")!))
        #expect(h.value("B1") == .number(21))
    }

    @Test func batchSetRecalculatesOnce() {
        let h = Harness()
        h.set(cells: ["A1": "1", "A2": "2", "A3": "3", "B1": "=SUM(A1:A3)"])
        #expect(h.value("B1") == .number(6))
    }

    @Test func diamondDependencyEvaluatesCorrectly() {
        // A1 -> B1, A1 -> C1, (B1,C1) -> D1
        let h = Harness(cells: [
            "A1": "1", "B1": "=A1*2", "C1": "=A1*3", "D1": "=B1+C1",
        ])
        #expect(h.value("D1") == .number(5))
        h.set("A1", "10")
        #expect(h.value("D1") == .number(50))
    }

    @Test func rebuildAfterStructuralChange() {
        let h = Harness(cells: ["A1": "1", "A2": "2", "A3": "=SUM(A1:A2)"])
        WorkbookOperations.insertRows(in: h.workbook, sheetID: h.sheetID, at: 1, count: 1)
        h.engine.rebuildAll()
        // Formula moved to A4 and expanded to A1:A3.
        #expect(h.workbook.sheets[0].cell(at: CellAddress(a1: "A4")!).formula == "SUM(A1:A3)")
        h.set("A2", "10")
        #expect(h.value("A4") == .number(13))
    }
}

@Suite("Workbook model")
struct WorkbookTests {
    @Test func sheetManagement() {
        let wb = Workbook.newDocument()
        #expect(wb.sheets.count == 1)
        #expect(wb.sheets[0].name == "Sheet1")
        let s2 = wb.addSheet()
        #expect(s2.name == "Sheet2")
        let named = wb.addSheet(named: "Budget")
        #expect(named.name == "Budget")
        // Names unique, case-insensitive.
        let dup = wb.addSheet(named: "budget")
        #expect(dup.name == "budget 2")
        // Cannot remove the last sheet.
        wb.removeSheet(withID: s2.id)
        wb.removeSheet(withID: named.id)
        wb.removeSheet(withID: dup.id)
        #expect(wb.removeSheet(withID: wb.sheets[0].id) == nil)
        #expect(wb.sheets.count == 1)
    }

    @Test func sheetNameSanitization() {
        #expect(Workbook.sanitizeSheetName("a/b:c?d") == "abcd")
        #expect(Workbook.sanitizeSheetName(String(repeating: "x", count: 40)).count == 31)
        #expect(Workbook.sanitizeSheetName("  padded  ") == "padded")
    }

    @Test func sheetReorder() {
        let wb = Workbook.newDocument()
        let s2 = wb.addSheet()
        wb.moveSheet(withID: s2.id, to: 0)
        #expect(wb.sheets[0].id == s2.id)
    }

    @Test func styleTableDeduplicates() {
        var table = StyleTable()
        var bold = CellStyle()
        bold.bold = true
        let i1 = table.index(for: bold)
        let i2 = table.index(for: bold)
        #expect(i1 == i2)
        #expect(i1 != 0)
        #expect(table[i1].bold)
        #expect(table[0] == .default)
        #expect(table[999] == .default) // out of range -> default
    }

    @Test func cellStorageDropsDefaults() {
        let sheet = Sheet(id: 1, name: "S")
        sheet.setCell(Cell(value: .number(1)), at: CellAddress(a1: "A1")!)
        #expect(sheet.cells.count == 1)
        sheet.setCell(Cell(), at: CellAddress(a1: "A1")!)
        #expect(sheet.cells.isEmpty)
    }

    @Test func usedRange() {
        let sheet = Sheet(id: 1, name: "S")
        #expect(sheet.usedRange == nil)
        sheet.setCell(Cell(value: .number(1)), at: CellAddress(a1: "B2")!)
        sheet.setCell(Cell(value: .number(2)), at: CellAddress(a1: "D7")!)
        #expect(sheet.usedRange?.a1 == "B2:D7")
    }

    @Test func modifyStyleInRange() {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        sheet.setCell(Cell(value: .number(1)), at: CellAddress(a1: "A1")!)
        wb.modifyStyle(in: CellRange(a1: "A1:B2")!, ofSheetID: sheet.id) { $0.bold = true }
        // Existing cell got bold; empty cells materialized with style.
        #expect(wb.style(at: sheet.cell(at: CellAddress(a1: "A1")!).styleIndex).bold)
        #expect(wb.style(at: sheet.cell(at: CellAddress(a1: "B2")!).styleIndex).bold)
        #expect(sheet.cells.count == 4)
    }
}

@Suite("Workbook structural operations")
struct WorkbookOperationTests {
    @Test func insertRowsMovesCellsAndMetadata() {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        sheet.setCell(Cell(value: .number(1)), at: CellAddress(a1: "A1")!)
        sheet.setCell(Cell(value: .number(2)), at: CellAddress(a1: "A3")!)
        sheet.rowHeights[2] = 40
        WorkbookOperations.insertRows(in: wb, sheetID: sheet.id, at: 1, count: 2)
        #expect(sheet.value(at: CellAddress(a1: "A1")!) == .number(1))
        #expect(sheet.value(at: CellAddress(a1: "A3")!) == .empty)
        #expect(sheet.value(at: CellAddress(a1: "A5")!) == .number(2))
        #expect(sheet.rowHeights[4] == 40)
        #expect(sheet.rowHeights[2] == nil)
    }

    @Test func deleteRowsRemovesCells() {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        for r in 1...5 {
            sheet.setCell(Cell(value: .number(Double(r))), at: CellAddress(a1: "A\(r)")!)
        }
        WorkbookOperations.deleteRows(in: wb, sheetID: sheet.id, at: 1, count: 2) // rows 2-3
        #expect(sheet.value(at: CellAddress(a1: "A1")!) == .number(1))
        #expect(sheet.value(at: CellAddress(a1: "A2")!) == .number(4))
        #expect(sheet.value(at: CellAddress(a1: "A3")!) == .number(5))
        #expect(sheet.value(at: CellAddress(a1: "A4")!) == .empty)
    }

    @Test func insertColumnsAdjustsFormulas() {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        sheet.setCell(Cell(value: .number(5)), at: CellAddress(a1: "B1")!)
        sheet.setCell(Cell(value: .empty, formula: "B1*2"), at: CellAddress(a1: "C1")!)
        WorkbookOperations.insertColumns(in: wb, sheetID: sheet.id, at: 1, count: 1)
        // B1 moved to C1; formula (now at D1) follows it.
        #expect(sheet.cell(at: CellAddress(a1: "D1")!).formula == "C1*2")
    }

    @Test func deleteReferencedRowYieldsRefError() {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        sheet.setCell(Cell(value: .number(5)), at: CellAddress(a1: "A5")!)
        sheet.setCell(Cell(value: .empty, formula: "A5+1"), at: CellAddress(a1: "B1")!)
        WorkbookOperations.deleteRows(in: wb, sheetID: sheet.id, at: 4, count: 1)
        #expect(sheet.cell(at: CellAddress(a1: "B1")!).formula == "#REF!+1")
    }

    @Test func renameSheetRewritesFormulas() {
        let wb = Workbook.newDocument()
        let data = wb.addSheet(named: "Data")
        let sheet1 = wb.sheets[0]
        sheet1.setCell(Cell(value: .empty, formula: "Data!A1+1"), at: CellAddress(a1: "A1")!)
        WorkbookOperations.renameSheet(in: wb, sheetID: data.id, to: "My Data")
        #expect(sheet1.cell(at: CellAddress(a1: "A1")!).formula == "'My Data'!A1+1")
    }

    @Test func deleteSheetPoisonsReferences() {
        let wb = Workbook.newDocument()
        let data = wb.addSheet(named: "Data")
        let sheet1 = wb.sheets[0]
        sheet1.setCell(Cell(value: .empty, formula: "SUM(Data!A1:A5)"), at: CellAddress(a1: "A1")!)
        WorkbookOperations.deleteSheet(in: wb, sheetID: data.id)
        #expect(sheet1.cell(at: CellAddress(a1: "A1")!).formula == "SUM(#REF!)")
    }

    @Test func mergedRangesFollowStructuralEdits() {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        sheet.mergedRanges = [CellRange(a1: "B2:C3")!]
        WorkbookOperations.insertRows(in: wb, sheetID: sheet.id, at: 0, count: 1)
        #expect(sheet.mergedRanges == [CellRange(a1: "B3:C4")!])
        WorkbookOperations.deleteRows(in: wb, sheetID: sheet.id, at: 2, count: 2)
        #expect(sheet.mergedRanges.isEmpty) // fully swallowed merge is dropped
    }

    @Test func translatedFormulaForCopy() {
        #expect(WorkbookOperations.translatedFormula("A1+$B$1", byRows: 2, columns: 1) == "B3+$B$1")
        #expect(WorkbookOperations.translatedFormula("A1", byRows: -5, columns: 0) == "#REF!")
        #expect(WorkbookOperations.translatedFormula("1+", byRows: 1, columns: 0) == "1+") // unparseable unchanged
    }
}
