import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// The pivot engine against Excel itself: for every pivot kept from the
/// fixtures, recompute it from cache + definition alone and compare with what
/// Excel wrote — axis lines, geometry, every cell, buttons, indents, formats.
@Suite("Pivot engine: Excel's own output", .serialized)
struct PivotEngineFixtureTests {
    /// Captions are in the UI language of the Excel that saved each file.
    static let captionsByFile: [String: PivotCaptions] = [
        "closedxml-TwoPivotTablesWithSingleSource-input.xlsx": PivotCaptions(
            rowLabels: "Названия строк", columnLabels: "Названия столбцов", grandTotal: "Общий итог",
            total: "Итог", all: "(Все)", multipleItems: "(несколько элементов)"),
        "libreoffice-shared-nested-dategroup.xlsx": PivotCaptions(
            rowLabels: "Sorcímkék", columnLabels: "Oszlopcímkék", grandTotal: "Végösszeg",
            total: "Összeg", all: "(Mind)", multipleItems: "(Több elem)"),
        "libreoffice-shared-numgroup.xlsx": PivotCaptions(
            rowLabels: "Sorcímkék", columnLabels: "Oszlopcímkék", grandTotal: "Végösszeg",
            total: "Összeg", all: "(Mind)", multipleItems: "(Több elem)"),
        "poi-ExcelPivotTableSample.xlsx": PivotCaptions(
            rowLabels: "Zeilenbeschriftungen", columnLabels: "Spaltenbeschriftungen", grandTotal: "Gesamtergebnis",
            total: "Ergebnis", all: "(Alle)", multipleItems: "(Mehrere Elemente)"),
    ]

    /// Not oracles: written by LibreOffice (its own captions and encodings).
    static let excludedFiles: Set<String> = ["libreoffice-calcfields.xlsx"]

    struct Outcome {
        var computed = 0
        var skipped: [String] = []
        var mismatches: [String] = []
    }

    static func sameValue(_ expected: CellValue, _ got: CellValue) -> Bool {
        switch (expected, got) {
        case (.number(let a), .number(let b)): return abs(a - b) <= 1e-6 * max(1, abs(a))
        case (.empty, .empty): return true
        case (.string(let a), .string(let b)): return a == b
        // Excel stores some numeric labels as text (and vice versa) — compare text forms.
        case (.string(let a), .number(let b)): return a == (b == b.rounded() ? String(Int64(b)) : "\(b)")
        case (.error(let a), .error(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        default: return false
        }
    }

    static func check(_ name: String) throws -> Outcome {
        var outcome = Outcome()
        let (workbook, _) = try PivotFixtures.read(name)
        let captions = captionsByFile[name] ?? .english
        for table in workbook.pivotTables {
            let sheet = workbook.sheet(withID: table.sheetID)!
            let tag = "\(name) :: \(sheet.name) :: \(table.name)"
            guard let cache = workbook.pivotCache(withID: table.cacheID) else { continue }
            let data = try cache.parsedData(styles: workbook.preservedStyles)
            let definition = try table.parsedDefinition(styles: workbook.preservedStyles)
            let engine = PivotEngine(cache: data, definition: definition, captions: captions)
            let result: PivotLayoutResult
            do {
                result = try engine.compute()
            } catch let error as PivotEngineError {
                outcome.skipped.append("\(tag): \(error.reason)")
                continue
            }
            outcome.computed += 1
            var problems: [String] = []
            func normalized(_ lines: [PivotAxisLine]) -> [PivotAxisLine] {
                lines.map { var l = $0; if l.kind == .grand { l.dataFieldIndex = 0 }; return l }
            }
            if result.isEmpty {
                if !definition.rowLines.isEmpty || !definition.columnLines.isEmpty { problems.append("expected an empty pivot") }
                if !problems.isEmpty { outcome.mismatches.append("\(tag): " + problems.joined(separator: "; ")) }
                continue
            }
            if normalized(result.rowLines) != normalized(definition.rowLines) {
                problems.append("rowItems differ: got \(result.rowLines.count) expected \(definition.rowLines.count)")
                for (i, (g, e)) in zip(normalized(result.rowLines), normalized(definition.rowLines)).enumerated() where g != e {
                    problems.append("  row[\(i)] got \(g) expected \(e)"); break
                }
            }
            if normalized(result.columnLines) != normalized(definition.columnLines) {
                problems.append("colItems differ: got \(result.columnLines.count) expected \(definition.columnLines.count)")
            }
            if (result.firstHeaderRow, result.firstDataRow, result.firstDataCol)
                != (definition.firstHeaderRow, definition.firstDataRow, definition.firstDataCol) {
                problems.append("location got \((result.firstHeaderRow, result.firstDataRow, result.firstDataCol)) expected \((definition.firstHeaderRow, definition.firstDataRow, definition.firstDataCol))")
            }
            if (result.rowCount, result.columnCount) != (table.location.rowCount, table.location.columnCount) {
                problems.append("size got \(result.rowCount)x\(result.columnCount) expected \(table.location.rowCount)x\(table.location.columnCount)")
            }

            let origin = table.location.start
            var cellProblems = 0
            func note(_ s: String) { cellProblems += 1; if cellProblems <= 8 { problems.append("  " + s) } }
            // Body: every cell, rendered or not.
            for r in 0..<table.location.rowCount {
                for c in 0..<table.location.columnCount {
                    let addr = CellAddress(row: origin.row + r, column: origin.column + c)
                    let expected = sheet.value(at: addr)
                    let rendered = result.cells[PivotOffset(row: r, column: c)]
                    let got = rendered?.value ?? .empty
                    if !sameValue(expected, got) { note("\(addr.a1) got \(got) expected \(expected)") }
                    let style = workbook.style(at: sheet.cell(at: addr).styleIndex)
                    if !definition.layout.gridDropZones, (rendered?.pivotButton ?? false) != style.pivotButton {
                        note("\(addr.a1) button got \(rendered?.pivotButton ?? false)")
                    }
                    if let rendered, rendered.indent != style.indent {
                        note("\(addr.a1) indent got \(rendered.indent) expected \(style.indent)")
                    }
                    if let rendered, let format = rendered.numberFormat, sheet.cells[addr] != nil,
                       format.isGeneral != style.numberFormat.isGeneral
                        || (!format.isGeneral && format.code != style.numberFormat.code) {
                        note("\(addr.a1) format got \(format.code) expected \(style.numberFormat.code)")
                    }
                }
            }
            // Report filters (negative rows).
            for (offset, rendered) in result.cells where offset.row < 0 {
                let addr = CellAddress(row: origin.row + offset.row, column: origin.column + offset.column)
                let expected = sheet.value(at: addr)
                if !sameValue(expected, rendered.value) { note("page \(addr.a1) got \(rendered.value) expected \(expected)") }
                if rendered.pivotButton != workbook.style(at: sheet.cell(at: addr).styleIndex).pivotButton {
                    note("page \(addr.a1) button")
                }
            }
            if cellProblems > 0 { problems.append("\(cellProblems) cell mismatches") }
            if !problems.isEmpty { outcome.mismatches.append("\(tag):\n" + problems.joined(separator: "\n")) }
        }
        return outcome
    }

    @Test(arguments: PivotFixtures.all.filter { !excludedFiles.contains($0) })
    func engineReproducesExcel(_ name: String) throws {
        let outcome = try Self.check(name)
        for mismatch in outcome.mismatches { Issue.record(Comment(rawValue: mismatch)) }
    }

    @Test func coverage() throws {
        var computed = 0
        var skipped: [String] = []
        for name in PivotFixtures.all where !Self.excludedFiles.contains(name) {
            let outcome = try Self.check(name)
            computed += outcome.computed
            skipped += outcome.skipped
        }
        print("PIVOT-ENGINE computed \(computed) pivots; skipped \(skipped.count):")
        for s in skipped { print("PIVOT-ENGINE skip \(s)") }
        #expect(computed >= 30)
    }
}
