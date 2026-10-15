import Testing
@testable import SpreadsheetCore

/// `CalculationEngine.apply(_:)` updates the graph for a row or column
/// insert or delete in place and recalculates only what can change. These
/// tests hold it to a full rebuild: after every edit, a fresh engine over a
/// copy of the workbook must compute the same values, and later edits must
/// still reach every dependent.
@Suite("Structural edits in the engine")
struct StructuralEditEngineTests {
    /// SplitMix64: the same workbooks and edits on every run.
    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let rows = 14
    static let columns = 6

    /// Formula templates; {r} and {s} are random row numbers, {c} a column letter.
    static let templates = [
        "A{r}*2", "$B$3+C{r}", "B{r}+{c}{s}", "SUM(A1:A{r})", "SUM(A{r}:C{s})", "SUM(A:A)", "SUM(B:C)",
        "SUM(2:3)", "COUNTBLANK(A2:B9)", "ROWS(A1:A{r})", "COLUMNS(A{r}:D{r})", "ROW()", "COLUMN()",
        "ROW(C{r})", "COLUMN({c}{r})", "Sheet2!B{r}+1", "SUM(Sheet2!A1:A{r})", "'My Sheet'!A{r}*3",
        "IF(ISBLANK(B{r}),0,B{r})", "INDEX(A1:A12,{r})", "MATCH(4,A:A,0)", "SUM(A1:F60)",
        "SUMIF(A1:F60,\">3\")", "Rate*2", "SUM(Block)", "Local+1", "COUNT($A$1:$F$12)", "{c}{r}&\"x\"",
        "Sheet1!A{r}+Sheet1!B{s}", "IFERROR(1/{c}{r},-1)",
    ]

    static func makeWorkbook(_ g: inout Generator) -> Workbook {
        let wb = Workbook.newDocument()
        _ = wb.addSheet(named: "Sheet2")
        _ = wb.addSheet(named: "My Sheet")
        let sheet1 = wb.sheets[0]
        wb.definedNames = [
            DefinedName(name: "Rate", formula: "Sheet1!$A$2"),
            DefinedName(name: "Block", formula: "Sheet1!$A$1:$B$6"),
            DefinedName(name: "Local", scopeSheetID: sheet1.id, formula: "Sheet1!$C$4"),
        ]
        sheet1.mergedRanges = [CellRange(start: CellAddress(row: 2, column: 1), end: CellAddress(row: 4, column: 2))]
        sheet1.hiddenRows = [6]
        sheet1.rowHeights = [3: 30]
        for sheet in wb.sheets {
            for r in 0..<rows {
                for c in 0..<columns {
                    let roll = Int.random(in: 0..<10, using: &g)
                    let address = CellAddress(row: r, column: c)
                    if roll < 4 {
                        sheet.setCell(Cell(value: .number(Double(Int.random(in: 0..<9, using: &g)))), at: address)
                    } else if roll < 8 {
                        sheet.setCell(Cell(formula: randomFormula(&g)), at: address)
                    }
                }
            }
        }
        return wb
    }

    static func randomFormula(_ g: inout Generator) -> String {
        var text = templates.randomElement(using: &g)!
        let a = Int.random(in: 1...rows, using: &g)
        let b = Int.random(in: a...rows + 4, using: &g)
        text = text.replacingOccurrences(of: "{r}", with: String(a))
        text = text.replacingOccurrences(of: "{s}", with: String(b))
        text = text.replacingOccurrences(of: "{c}", with: CellAddress.columnName(Int.random(in: 0..<columns, using: &g)))
        return text
    }

    /// Every cell's value, as a fresh engine over a copy computes it.
    static func rebuiltValues(_ wb: Workbook) -> [AbsoluteAddress: CellValue] {
        let copy = wb.copy()
        _ = CalculationEngine(workbook: copy, clock: testClock)
        return values(copy)
    }

    static func values(_ wb: Workbook) -> [AbsoluteAddress: CellValue] {
        var out: [AbsoluteAddress: CellValue] = [:]
        for sheet in wb.sheets {
            for (address, cell) in sheet.cells where !cell.value.isEmpty {
                out[AbsoluteAddress(sheetID: sheet.id, address: address)] = cell.value
            }
        }
        return out
    }

    struct Contents: Equatable {
        var cells: [AbsoluteAddress: Cell]
        var names: [DefinedName]
        var layouts: [SheetLayoutState]
    }

    static func contents(_ wb: Workbook) -> Contents {
        var cells: [AbsoluteAddress: Cell] = [:]
        for sheet in wb.sheets {
            for (address, cell) in sheet.cells { cells[AbsoluteAddress(sheetID: sheet.id, address: address)] = cell }
        }
        return Contents(cells: cells, names: wb.definedNames, layouts: wb.sheets.map(\.layoutState))
    }

    static func mismatches(_ wb: Workbook) -> [String] {
        let expected = rebuiltValues(wb)
        let actual = values(wb)
        var out: [String] = []
        for key in Set(expected.keys).union(actual.keys) where expected[key] != actual[key] {
            let formula = wb.sheet(withID: key.sheetID)?.cells[key.address]?.formula ?? "-"
            out.append("\(key) =\(formula): \(String(describing: actual[key])) != \(String(describing: expected[key]))")
        }
        return out.sorted()
    }

    @Test func randomEditsMatchAFullRebuild() {
        var g = Generator(state: 2026_10_15)
        for trial in 0..<150 {
            let wb = Self.makeWorkbook(&g)
            let engine = CalculationEngine(workbook: wb, clock: testClock)
            for step in 0..<4 {
                let sheet = wb.sheets[Int.random(in: 0..<2, using: &g)]
                let axisIsRow = Bool.random(using: &g)
                let size = Int.random(in: 1...3, using: &g)
                let change = StructuralChange(
                    sheetID: sheet.id, axisIsRow: axisIsRow,
                    index: Int.random(in: 0..<(axisIsRow ? Self.rows : Self.columns), using: &g),
                    count: Bool.random(using: &g) ? size : -size)
                let before = Self.contents(wb)
                guard let result = WorkbookOperations.apply(change, to: wb) else { continue }
                engine.apply(result)
                let wrong = Self.mismatches(wb)
                #expect(wrong.isEmpty, "trial \(trial) step \(step) \(change): \(wrong.prefix(5))")
                if !wrong.isEmpty { return }

                // Undo puts everything back; redo is the edit again.
                if Int.random(in: 0..<3, using: &g) == 0 {
                    engine.apply(result.undo(in: wb)!)
                    #expect(Self.contents(wb) == before, "trial \(trial) step \(step) undo \(change)")
                    let afterUndo = Self.mismatches(wb)
                    #expect(afterUndo.isEmpty, "trial \(trial) step \(step) undo \(change): \(afterUndo.prefix(5))")
                    if !afterUndo.isEmpty { return }
                    engine.apply(WorkbookOperations.apply(change, to: wb)!)
                }

                // The graph still reaches every dependent.
                for _ in 0..<3 {
                    let target = wb.sheets[Int.random(in: 0..<3, using: &g)]
                    let address = CellAddress(row: Int.random(in: 0..<Self.rows + 3, using: &g),
                                              column: Int.random(in: 0..<Self.columns + 2, using: &g))
                    let at = AbsoluteAddress(sheetID: target.id, address: address)
                    if Bool.random(using: &g) {
                        engine.setCellValue(.number(Double(Int.random(in: 0..<9, using: &g))), at: at)
                    } else {
                        engine.setCellFormula(Self.randomFormula(&g), at: at)
                    }
                }
                let afterEdits = Self.mismatches(wb)
                #expect(afterEdits.isEmpty, "trial \(trial) step \(step) edits after \(change): \(afterEdits.prefix(5))")
                if !afterEdits.isEmpty { return }
            }
        }
    }

    /// The parse trees the engine adjusts in place say what the rewritten
    /// formula text says.
    @Test func adjustedTreesMatchTheRewrittenText() throws {
        var g = Generator(state: 7)
        for _ in 0..<400 {
            let wb = Workbook.newDocument()
            let sheet = wb.sheets[0]
            _ = wb.addSheet(named: "Sheet2")
            let text = Self.randomFormula(&g)
            sheet.setCell(Cell(formula: text), at: CellAddress(row: 40, column: 30)) // never deleted
            let change = StructuralChange(sheetID: sheet.id, axisIsRow: Bool.random(using: &g),
                                          index: Int.random(in: 0..<16, using: &g),
                                          count: Bool.random(using: &g) ? 2 : -2)
            let tree = try FormulaParser.parse(text).mappingReferences { ref in
                ref.sheetName == nil || ref.sheetName == "Sheet1" ? change.adjusting(ref) : ref
            }
            WorkbookOperations.apply(change, to: wb)
            let rewritten = try #require(sheet.cells.values.compactMap(\.formula).first)
            #expect(try FormulaParser.parse(rewritten) == tree, "\(text) after \(change): \(rewritten)")
        }
    }

    @Test func movedFormulasKeepTheirValuesWithoutRecalculating() {
        let h = Harness()
        let sheet = h.workbook.sheets[0]
        for r in 0..<100 {
            h.set("A\(r + 1)", "\(r)")
            h.set("B\(r + 1)", "=A\(r + 1)*2")
        }
        h.set("C1", "=SUM(B1:B100)")
        h.set("D1", "=ROW(B50)")
        let result = WorkbookOperations.apply(
            StructuralChange(sheetID: sheet.id, axisIsRow: true, index: 10, count: 1), to: h.workbook)!
        let recalculated = h.engine.apply(result)
        // The sum (its range grew) and ROW (its reference moved) only.
        #expect(recalculated == [AbsoluteAddress(sheetID: sheet.id, address: CellAddress(row: 0, column: 2)),
                                 AbsoluteAddress(sheetID: sheet.id, address: CellAddress(row: 0, column: 3))])
        #expect(h.value("D1") == .number(51))
        // The moved cells are wired up at their new addresses.
        h.set("A51", "1000")
        #expect(h.value("B51") == .number(2000))
        // A51 held 49 (old A50): 2 * (0 + ... + 99) - 98 + 2000.
        #expect(h.value("C1") == .number(11_802))
    }
}
