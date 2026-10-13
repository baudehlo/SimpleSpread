import Foundation
import Testing
@testable import SpreadsheetCore

private func at(_ sheet: Sheet, _ a1: String) -> AbsoluteAddress {
    AbsoluteAddress(sheetID: sheet.id, address: CellAddress(a1: a1)!)
}

private func seconds(_ body: () -> Void) -> Double {
    let start = Date()
    body()
    return Date().timeIntervalSince(start)
}

@Suite("Calculation engine: range dependencies")
struct RangeDependencyTests {
    @Test func distinctLargeRangesRecalculateOnlyWhatTheyCover() {
        // Sliding windows bigger than the per-cell edge limit, no two alike.
        let h = Harness()
        let sheet = h.workbook.sheets[0]
        var entries: [(AbsoluteAddress, CellValue, String?)] = []
        for r in 1...1_000 { entries.append((at(sheet, "A\(r)"), .number(1), nil)) }
        for r in 1...600 { entries.append((at(sheet, "B\(r)"), .empty, "SUM(A\(r):A\(r + 299))")) }
        h.engine.setCells(entries)
        #expect(h.value("B1") == .number(300))
        #expect(h.value("B600") == .number(300))
        h.set("A400", "11")
        #expect(h.value("B100") == .number(300))  // A100:A399
        #expect(h.value("B101") == .number(310))  // A101:A400
        #expect(h.value("B400") == .number(310))  // A400:A699
        #expect(h.value("B401") == .number(300))  // A401:A700
    }

    @Test func multiColumnAndWideRangesTrackEdits() {
        let h = Harness(cells: [
            "AB1": "=SUM(A1:C200)",          // 600 cells, three columns
            "AB2": "=SUM(A1:Z20)",           // 520 cells, wide
            "AB3": "=SUM(Sheet1!7:7)",       // whole row (AB3 is not on row 7)
            "AB4": "=SUM(A:A)",              // whole column
        ])
        h.set("B150", "5")
        #expect(h.value("AB1") == .number(5))
        #expect(h.value("AB2") == .number(0))
        h.set("Y7", "3")
        #expect(h.value("AB1") == .number(5))
        #expect(h.value("AB2") == .number(3))
        #expect(h.value("AB3") == .number(3))
        h.set("A7", "2")
        #expect(h.value("AB1") == .number(7))
        #expect(h.value("AB2") == .number(5))
        #expect(h.value("AB3") == .number(5))
        #expect(h.value("AB4") == .number(2))
        h.set("A900000", "4")
        #expect(h.value("AB4") == .number(6))
    }

    @Test func replacedRangeFormulaStopsListening() {
        let h = Harness(cells: ["A1": "1", "B1": "=SUM(A1:A1000)", "C1": "=SUM(A1:A1000)"])
        #expect(h.value("B1") == .number(1))
        h.set("B1", "=SUM(D1:D1000)")
        h.set("A5", "10")
        #expect(h.value("B1") == .number(0))
        #expect(h.value("C1") == .number(11))   // the shared range still feeds C1
        h.set("C1", "")
        h.set("D3", "4")
        #expect(h.value("B1") == .number(4))
    }

    @Test func formulaInsideARangeFeedsItsDependents() {
        // A chain through a range: A600 is a formula inside SUM's range.
        let h = Harness(cells: ["Z1": "2", "A600": "=Z1*10", "B1": "=SUM(A1:A1000)", "C1": "=B1+1"])
        #expect(h.value("C1") == .number(21))
        h.set("Z1", "3")
        #expect(h.value("B1") == .number(30))
        #expect(h.value("C1") == .number(31))
    }

    /// The review measured 4k formulas at 1.7 s per edit and 8k at 6.7 s
    /// (debug). The guard is generous so slow CI machines don't flake.
    @Test func oneEditUnderManySharedRangeFormulasIsFast() {
        let wb = Workbook()
        let sheet = wb.addSheet(named: "Sheet1")
        for r in 0..<300 { sheet.setCell(Cell(value: .number(1)), at: CellAddress(row: r, column: 0)) }
        let n = 8_000
        for r in 0..<n {
            sheet.setCell(Cell(formula: "SUM($A$1:$A$300)+\(r)"), at: CellAddress(row: r, column: 2))
        }
        let engine = CalculationEngine(workbook: wb)
        #expect(sheet.value(at: CellAddress(row: n - 1, column: 2)) == .number(Double(300 + n - 1)))
        let elapsed = seconds { engine.setCellValue(.number(2), at: at(sheet, "A5")) }
        #expect(sheet.value(at: CellAddress(row: n - 1, column: 2)) == .number(Double(301 + n - 1)))
        #expect(elapsed < 2, "one edit took \(elapsed)s")
    }

    @Test func oneEditUnderManyDistinctRangeFormulasIsFast() {
        // Growing ranges, no two alike, all covering A1. ROWS doesn't read
        // the cells, so the time is the engine's bookkeeping.
        let wb = Workbook()
        let sheet = wb.addSheet(named: "Sheet1")
        let n = 8_000
        for r in 0..<n {
            sheet.setCell(Cell(formula: "ROWS(A1:A\(r + 300))+B\(r + 1)"), at: CellAddress(row: r, column: 2))
        }
        let engine = CalculationEngine(workbook: wb)
        let elapsed = seconds {
            // Beside the ranges: one dependent each.
            for r in 0..<200 { engine.setCellValue(.number(1), at: at(sheet, "B\(r + 1)")) }
            // Inside every range: all n recalculate.
            engine.setCellValue(.number(2), at: at(sheet, "A1"))
        }
        #expect(sheet.value(at: CellAddress(row: 0, column: 2)) == .number(301))
        #expect(sheet.value(at: CellAddress(row: n - 1, column: 2)) == .number(Double(n + 299)))
        #expect(elapsed < 2, "edits took \(elapsed)s")
    }
}

@Suite("Calculation engine: determinism")
struct CalculationDeterminismTests {
    @Test func everyCellInACycleIsCircular() {
        // Each cell would swallow the other's error: whichever one the walk
        // happened to mark first used to decide the result.
        let h = Harness()
        h.set(cells: ["A1": "=IFERROR(B1,5)", "B1": "=IFERROR(C1,6)", "C1": "=IFERROR(A1,7)",
                      "D1": "=IFERROR(A1,8)"])
        #expect(h.value("A1").errorValue == .circular)
        #expect(h.value("B1").errorValue == .circular)
        #expect(h.value("C1").errorValue == .circular)
        #expect(h.value("D1") == .number(8))  // downstream, not in the cycle
        // Breaking the cycle recovers every member.
        h.set("C1", "1")
        #expect(h.value("A1") == .number(1))
        #expect(h.value("B1") == .number(1))
        #expect(h.value("D1") == .number(1))
    }

    @Test func cycleThroughALargeRangeMarksItsMembers() {
        let h = Harness()
        h.set(cells: ["A500": "=IFERROR(B1,1)", "B1": "=IFERROR(SUM(A1:A1000),2)", "C1": "=IFERROR(B1,3)"])
        #expect(h.value("A500").errorValue == .circular)
        #expect(h.value("B1").errorValue == .circular)
        #expect(h.value("C1") == .number(3))
    }

    @Test func sparseRangeValuesComeInRowMajorOrder() {
        let sheet = Sheet(id: 1, name: "S")
        var expected: [CellValue] = []
        for i in 0..<40 {
            let address = CellAddress(row: (i * 7_919) % 90_000, column: i % 3)
            sheet.setCell(Cell(value: .number(Double(i))), at: address)
        }
        sheet.setCell(Cell(value: .number(-1)), at: CellAddress(row: 99_999, column: 2))
        let sorted = sheet.cells.keys.sorted { ($0.row, $0.column) < ($1.row, $1.column) }
        expected = sorted.map { sheet.value(at: $0) }
        let range = ResolvedRange(sheet: sheet, sheetID: 1,
                                  range: CellRange(start: CellAddress(row: 0, column: 0),
                                                   end: CellAddress(row: 99_999, column: 2)),
                                  isSingleCell: false, isEmpty: false)
        var seen: [CellValue] = []
        range.forEachValue { seen.append($0) }
        #expect(seen.filter { !$0.isEmpty } == expected)
    }

    @Test func sparseWholeColumnSumAddsInRowOrder() {
        // In row order 1e16 + 1 rounds back to 1e16 each time: the result is 0.
        var cells = ["A1": "1E16", "A10": "-1E16", "A200000": "0"]
        for r in 2...9 { cells["A\(r)"] = "1" }
        let h = Harness(cells: cells)
        #expect(h.eval("SUM(A:A)") == .number(0))
    }
}

@Suite("Calculation engine: sheets added later")
struct LateSheetReferenceTests {
    @Test func referenceResolvesWhenSheetIsAdded() {
        let h = Harness(cells: ["A1": "=Data!A1*2", "A2": "=SUM(Data!B1:B1000)", "A3": "=A1+1"])
        #expect(h.value("A1").errorValue == .ref)
        let data = h.workbook.addSheet(named: "Data")
        h.engine.sheetsDidChange()
        #expect(h.value("A1") == .number(0))
        #expect(h.value("A3") == .number(1))
        h.engine.setCellValue(.number(3), at: at(data, "A1"))
        h.engine.setCellValue(.number(4), at: at(data, "B7"))
        #expect(h.value("A1") == .number(6))
        #expect(h.value("A2") == .number(4))
        #expect(h.value("A3") == .number(7))
    }

    @Test func referenceResolvesOnTheNextEditWithoutNotification() {
        let h = Harness(cells: ["A1": "=Data!A1*2"])
        let data = h.workbook.addSheet(named: "data") // names match case-insensitively
        h.engine.setCellValue(.number(5), at: at(data, "A1"))
        #expect(h.value("A1") == .number(10))
    }

    @Test func referenceResolvesWhenASheetIsRenamedToTheName() {
        let h = Harness(cells: ["A1": "=Budget!A1+1"])
        let other = h.workbook.addSheet(named: "Other")
        h.engine.setCellValue(.number(9), at: at(other, "A1"))
        #expect(h.value("A1").errorValue == .ref)
        h.workbook.renameSheet(withID: other.id, to: "Budget")
        h.engine.sheetsDidChange()
        #expect(h.value("A1") == .number(10))
    }
}
