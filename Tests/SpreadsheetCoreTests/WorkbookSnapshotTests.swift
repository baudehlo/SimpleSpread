import Foundation
import Testing
@testable import SpreadsheetCore

@Suite("Workbook snapshots for undo")
struct WorkbookSnapshotTests {
    func a(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }

    func workbook() -> Workbook {
        let wb = Workbook.newDocument()
        wb.sheets[0].setCell(Cell(value: .number(1)), at: a("A1"))
        let other = wb.addSheet(named: "Other")
        other.setCell(Cell(value: .number(2)), at: a("B2"))
        return wb
    }

    @Test func keepsOnlyTheCellTablesTheCommandChanged() {
        let wb = workbook()
        let (first, other) = (wb.sheets[0], wb.sheets[1])
        let snapshot = WorkbookSnapshot(of: wb)
        first.setCell(Cell(value: .number(10)), at: a("A1"))
        snapshot.releaseUnchangedCells(comparedTo: wb)
        #expect(snapshot.sheetsWithSavedCells == [first.id])

        snapshot.restore(into: wb)
        #expect(wb.sheets[0] !== first) // restored copies, ids kept
        #expect(wb.sheets.map(\.id) == [first.id, other.id])
        #expect(wb.sheets[0].value(at: a("A1")) == .number(1))
        #expect(wb.sheets[1].value(at: a("B2")) == .number(2))
        #expect(wb.sheets[1].usedRange == CellRange(a1: "B2"))
    }

    @Test func rebuildingTheEngineDoesNotCountAsAChange() {
        let wb = workbook()
        wb.sheets[1].setCell(Cell(formula: "B2*2"), at: a("C2"))
        wb.sheets[1].setCell(Cell(formula: "SUM("), at: a("C3")) // can't be read
        let engine = CalculationEngine(workbook: wb)
        let snapshot = WorkbookSnapshot(of: wb)
        wb.sheets[0].setCell(Cell(value: .number(10)), at: a("A1"))
        engine.rebuildAll()
        snapshot.releaseUnchangedCells(comparedTo: wb)
        #expect(snapshot.sheetsWithSavedCells == [wb.sheets[0].id])
    }

    @Test func aCommandThatChangesNoCellsKeepsNoCellTables() {
        let wb = workbook()
        let snapshot = WorkbookSnapshot(of: wb)
        wb.moveSheet(withID: wb.sheets[1].id, to: 0)
        wb.renameSheet(withID: wb.sheets[0].id, to: "Renamed")
        snapshot.releaseUnchangedCells(comparedTo: wb)
        #expect(snapshot.sheetsWithSavedCells.isEmpty)
        snapshot.restore(into: wb)
        #expect(wb.sheets.map(\.name) == ["Sheet1", "Other"])
        #expect(wb.sheets[0].value(at: a("A1")) == .number(1))
    }

    @Test func aDeletedSheetComesBackWithItsCells() {
        let wb = workbook()
        let otherID = wb.sheets[1].id
        let snapshot = WorkbookSnapshot(of: wb)
        wb.removeSheet(withID: otherID)
        snapshot.releaseUnchangedCells(comparedTo: wb)
        #expect(snapshot.sheetsWithSavedCells == [otherID])
        snapshot.restore(into: wb)
        #expect(wb.sheet(withID: otherID)?.value(at: a("B2")) == .number(2))
        // Sheet ids are never handed out twice, even after a restore.
        #expect(wb.addSheet().id > otherID)
    }

    @Test func frozenPanesAreAViewSettingAndStay() {
        let wb = workbook()
        let snapshot = WorkbookSnapshot(of: wb)
        wb.sheets[0].setCell(Cell(value: .number(5)), at: a("C3"))
        wb.sheets[0].frozenRows = 2
        snapshot.releaseUnchangedCells(comparedTo: wb)
        snapshot.restore(into: wb)
        #expect(wb.sheets[0].frozenRows == 2)
        #expect(wb.sheets[0].value(at: a("C3")) == .empty)
    }
}
