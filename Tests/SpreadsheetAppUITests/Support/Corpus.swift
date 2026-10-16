#if os(macOS)
import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles
@testable import SpreadsheetUI

/// The documents the UI tests use: small ones, and ones the size and shape
/// of real work (a 20,000-row table with formulas, pivots and charts, as
/// the benchmark's complex.xlsx), opened from files as the app opens them.
@MainActor
enum Corpus {
    enum Kind: String, CaseIterable, CustomTestStringConvertible {
        case blank, sample, sales, complex, excelCharts
        var testDescription: String { rawValue }
    }

    static func document(_ kind: Kind) throws -> SpreadsheetDocument {
        switch kind {
        case .blank: return SpreadsheetDocument()
        case .sample:
            let doc = SpreadsheetDocument()
            DocumentStore.seedDemoContent(doc)
            doc.selection.select(CellAddress(a1: "A1")!)
            return doc
        case .sales: return sales()
        case .complex: return try open(complexData())
        case .excelCharts:
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("SpreadsheetFilesTests/Fixtures/ExcelOracle/charts-by-excel.xlsx")
            return try open(Data(contentsOf: url))
        }
    }

    /// Opened as the app opens a file: read, then a document over it.
    static func open(_ data: Data) throws -> SpreadsheetDocument {
        let doc = SpreadsheetDocument(workbook: try XLSXReader.read(data: data))
        doc.undoManager.removeAllActions()
        return doc
    }

    /// Month and three regions' sales, A1:D7.
    static func sales() -> SpreadsheetDocument {
        let doc = SpreadsheetDocument()
        let rows = [["Month", "North", "South", "West"], ["Jan", "120", "90", "60"], ["Feb", "135", "95", "72"],
                    ["Mar", "150", "110", "80"], ["Apr", "142", "125", "95"], ["May", "168", "130", "101"],
                    ["Jun", "181", "142", "118"]]
        for (r, row) in rows.enumerated() {
            for (c, text) in row.enumerated() { doc.commitInput(text, at: CellAddress(row: r, column: c)) }
        }
        doc.selection.select(CellAddress(a1: "A1")!)
        doc.undoManager.removeAllActions()
        return doc
    }

    /// Like complex.xlsx: a Data sheet of 20,000 orders (8 columns), a Calc
    /// sheet of formulas over it, and summary sheets holding four pivot
    /// tables and a chart. Built once per run, saved, and read back.
    static func complexData() throws -> Data {
        if let cached = complexCache { return cached }
        let wb = Workbook()
        let data = wb.addSheet(named: "Data")
        let headers = ["Date", "Region", "Channel", "Product", "Units", "Price", "Revenue", "Rep"]
        for (c, h) in headers.enumerated() { data.setCell(Cell(value: .string(h)), at: CellAddress(row: 0, column: c)) }
        let regions = ["North", "South", "East", "West", "Central"]
        let channels = ["Online", "Retail", "Partner"]
        let products = ["Widget", "Gadget", "Gizmo", "Doohickey", "Sprocket", "Flange"]
        var seed: UInt64 = 42
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        for r in 1...20_000 {
            let units = Double(1 + next(40)), price = Double(5 + next(95))
            let values: [CellValue] = [.number(Double(45_000 + next(365))), .string(regions[next(5)]),
                                       .string(channels[next(3)]), .string(products[next(6)]), .number(units),
                                       .number(price), .number(units * price), .string("Rep \(1 + next(25))")]
            for (c, v) in values.enumerated() { data.setCell(Cell(value: v), at: CellAddress(row: r, column: c)) }
        }
        let calc = wb.addSheet(named: "Calc")
        for r in 0..<10_000 {
            calc.setCell(Cell(value: .empty, formula: "Data!G\(r + 2)*1.1"), at: CellAddress(row: r, column: 0))
            calc.setCell(Cell(value: .empty, formula: "A\(r + 1)-Data!F\(r + 2)"), at: CellAddress(row: r, column: 1))
        }
        let doc = SpreadsheetDocument(workbook: wb)
        doc.confirm = { _, _, _ in true }
        // Four pivots over the orders, on their own sheets.
        let layouts: [(rows: [Int], columns: [Int], values: [Int])] = [
            ([1], [], [6]), ([1], [2], [4]), ([3], [], [6, 4]), ([2], [], [6]),
        ]
        for layout in layouts {
            doc.activeSheetID = data.id
            doc.selection.select(CellAddress(a1: "A1")!)
            guard doc.insertPivotTable(source: CellRange(a1: "A1:H20001")!),
                  let index = doc.activePivotIndex else { continue }
            doc.editPivot(index, actionName: "Fields") { d, c in
                for f in layout.rows { d.place(field: f, in: .rows, cache: c) }
                for f in layout.columns { d.place(field: f, in: .columns, cache: c) }
                for f in layout.values { d.place(field: f, in: .values, cache: c) }
            }
        }
        // A chart of the first pivot's region totals.
        if let first = wb.pivotTables.first, let sheet = wb.sheet(withID: first.sheetID) {
            doc.activeSheetID = sheet.id
            doc.selection.select(range: first.location)
            doc.insertChart(.column)
        }
        let bytes = try XLSXWriter.data(for: wb)
        complexCache = bytes
        return bytes
    }

    private static var complexCache: Data?
}
#endif
