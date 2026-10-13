import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetUI

/// Opening the editor and pressing Return must not change a cell (review #2).
@MainActor
@Suite("Editor round trip")
struct EditorRoundTripTests {
    func a(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }

    func put(_ doc: SpreadsheetDocument, _ a1: String, _ value: Double, format: NumberFormat = .general) {
        let style = doc.workbook.styleIndex(for: CellStyle(numberFormat: format))
        doc.activeSheet.setCell(Cell(value: .number(value), styleIndex: style), at: a(a1))
    }

    @Test func editStringCommitsBackToTheSameValue() {
        let doc = SpreadsheetDocument()
        let dateTime = ExcelDate.serial(year: 2024, month: 1, day: 15, hour: 15, minute: 45, second: 10)
        let cases: [(Double, NumberFormat)] = [
            (3.14159265358979, .general), (1234567890123.45, .general), (0.1 + 0.2, .general),
            (dateTime, .date), (0.123456, .percent), (45306.65636574074, .dateTime), (1e20, .decimal2),
        ]
        for (i, (value, format)) in cases.enumerated() {
            let cell = "A\(i + 1)"
            put(doc, cell, value, format: format)
            // Retype the editor's text (as if the user changed it and back).
            let text = doc.editString(at: a(cell))
            doc.activeSheet.setCell(Cell(value: .empty, styleIndex: doc.activeSheet.cell(at: a(cell)).styleIndex),
                                    at: a(cell))
            doc.commitInput(text, at: a(cell))
            #expect(doc.activeSheet.value(at: a(cell)) == .number(value), "\(value) as \(text)")
        }
        #expect(doc.editString(at: a("A4")) == "1/15/2024 3:45:10 PM")
        #expect(doc.editString(at: a("A5")) == "12.3456%")
    }

    @Test func unchangedCommitIsNotAnEdit() {
        let doc = SpreadsheetDocument()
        put(doc, "A1", 1234567890123.45)
        doc.activeSheet.setCell(Cell(value: .number(3), formula: "1+2"), at: a("A2"))
        doc.commitInput(doc.editString(at: a("A1")), at: a("A1"))
        doc.commitInput(doc.editString(at: a("A2")), at: a("A2"))
        #expect(!doc.isModified)
        #expect(!doc.undoManager.canUndo)
        #expect(doc.activeSheet.value(at: a("A1")) == .number(1234567890123.45))
        doc.commitInput("7", at: a("A1"))
        #expect(doc.isModified)
        #expect(doc.activeSheet.value(at: a("A1")) == .number(7))
    }
}
