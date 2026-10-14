import Foundation
import SpreadsheetCore
import SpreadsheetFiles

// Times each phase of loading a large file, in a release build:
//   swift run -c release spreadsheet-bench <file.csv|file.xlsx> [--save]
// or times editing and recalculation on synthetic workbooks built in memory:
//   swift run -c release spreadsheet-bench --edits
// or times saving a full synthetic sheet (snapshot, write, progress):
//   swift run -c release spreadsheet-bench --save-full-sheet
// Not part of the app; for measuring big-file performance.

@discardableResult
func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
    let start = Date()
    let result = try body()
    print(label.padding(toLength: 52, withPad: " ", startingAt: 0)
          + String(format: " %8.3fs", Date().timeIntervalSince(start)))
    return result
}

/// Synthetic workbooks for the calculation engine: one value edit under many
/// range formulas, whole-column/whole-row recalculation, and usedRange.
func runEditBenchmarks() {
    func addr(_ sheet: Sheet, _ row: Int, _ column: Int) -> AbsoluteAddress {
        AbsoluteAddress(sheetID: sheet.id, address: CellAddress(row: row, column: column))
    }

    // 1. n formulas over the same large range, filled down: one edit inside
    //    the range dirties all of them; one edit beside it dirties one.
    for n in [2_000, 10_000, 20_000] {
        let wb = Workbook()
        let sheet = wb.addSheet(named: "Sheet1")
        for r in 0..<1_000 { sheet.setCell(Cell(value: .number(Double(r))), at: CellAddress(row: r, column: 0)) }
        for r in 0..<n {
            sheet.setCell(Cell(value: .number(Double(r % 1_000))), at: CellAddress(row: r, column: 1))
            sheet.setCell(Cell(formula: "SUMIF($A$1:$A$1000,\">\"&B\(r + 1))"), at: CellAddress(row: r, column: 2))
        }
        let engine = time("engine init, \(n) SUMIF over A1:A1000") { CalculationEngine(workbook: wb) }
        time("edit A5 (dirties all \(n))") { _ = engine.setCellValue(.number(7), at: addr(sheet, 4, 0)) }
        // B1 = 0: every value but A1's 0 (and A5's new 7 in place of 4).
        precondition(sheet.value(at: CellAddress(row: 0, column: 2)) == .number(499_500 + 3))
        time("edit B5 (dirties one of \(n))") { _ = engine.setCellValue(.number(7), at: addr(sheet, 4, 1)) }
    }

    // 2. n distinct sliding-window ranges (no two alike): an edit hits ~300.
    do {
        let n = 10_000
        let wb = Workbook()
        let sheet = wb.addSheet(named: "Sheet1")
        for r in 0..<(n + 300) { sheet.setCell(Cell(value: .number(1)), at: CellAddress(row: r, column: 0)) }
        for r in 0..<n {
            sheet.setCell(Cell(formula: "SUM(A\(r + 1):A\(r + 300))"), at: CellAddress(row: r, column: 1))
        }
        let engine = time("engine init, \(n) sliding SUM(A_:A_+299)") { CalculationEngine(workbook: wb) }
        time("edit A5000 (dirties 300 of \(n))") { _ = engine.setCellValue(.number(2), at: addr(sheet, 4_999, 0)) }
        precondition(sheet.value(at: CellAddress(row: 4_999, column: 1)) == .number(301))
    }

    // 2b. Engine bookkeeping alone: n distinct ranges all covering A1, read
    //     by ROWS (which doesn't visit the cells); one edit dirties all.
    for n in [10_000, 20_000] {
        let wb = Workbook()
        let sheet = wb.addSheet(named: "Sheet1")
        for r in 0..<n {
            sheet.setCell(Cell(formula: "ROWS(A1:A\(r + 300))"), at: CellAddress(row: r, column: 1))
        }
        let engine = time("engine init, \(n) ROWS(A1:A_)") { CalculationEngine(workbook: wb) }
        time("edit A1 (dirties all \(n))") { _ = engine.setCellValue(.number(1), at: addr(sheet, 0, 0)) }
    }

    // 3. n whole-column formulas over 100k cells: each evaluation clamps
    //    A:A to the used range.
    do {
        let n = 10_000
        let wb = Workbook()
        let sheet = wb.addSheet(named: "Sheet1")
        for r in 0..<100_000 { sheet.setCell(Cell(value: .number(Double(r))), at: CellAddress(row: r, column: 0)) }
        for r in 0..<n {
            sheet.setCell(Cell(formula: "INDEX(A:A,\(r + 1))*2"), at: CellAddress(row: r, column: 2))
        }
        let engine = time("engine init, \(n) INDEX(A:A,…) over 100k") { CalculationEngine(workbook: wb) }
        time("recalculateAll") { _ = engine.recalculateAll() }
        precondition(sheet.value(at: CellAddress(row: 9, column: 2)) == .number(18))
        time("edit A5 (dirties all \(n))") { _ = engine.setCellValue(.number(7), at: addr(sheet, 4, 0)) }
    }

    // 4. usedRange: whole-row references, and raw calls on a big sheet.
    do {
        let wb = Workbook()
        let sheet = wb.addSheet(named: "Sheet1")
        for r in 0..<100_000 {
            for c in 0..<10 { sheet.setCell(Cell(value: .number(1)), at: CellAddress(row: r, column: c)) }
        }
        // On a second sheet, so no formula sits inside the rows it sums.
        let summary = wb.addSheet(named: "Summary")
        for r in 0..<5_000 {
            summary.setCell(Cell(formula: "SUM(Sheet1!\(r + 1):\(r + 1))"), at: CellAddress(row: r, column: 0))
        }
        let engine = time("engine init, 5k SUM(row:row) over 1M cells") { CalculationEngine(workbook: wb) }
        time("recalculateAll") { _ = engine.recalculateAll() }
        precondition(summary.value(at: CellAddress(row: 0, column: 0)) == .number(10))
        time("usedRange x1000 on 1M cells") {
            var rows = 0
            for _ in 0..<1_000 { rows &+= sheet.usedRange?.rowCount ?? 0 }
            return rows
        }
    }

    // 5. Graph build cost: a 200k-row running total plus 100k cell formulas.
    do {
        let wb = Workbook()
        let sheet = wb.addSheet(named: "Sheet1")
        sheet.setCell(Cell(value: .number(1)), at: CellAddress(row: 0, column: 0))
        for r in 1..<200_000 { sheet.setCell(Cell(formula: "A\(r)+1"), at: CellAddress(row: r, column: 0)) }
        for r in 0..<100_000 { sheet.setCell(Cell(formula: "A\(r + 1)*2"), at: CellAddress(row: r, column: 1)) }
        let engine = time("engine init, 300k cell-edge formulas") { CalculationEngine(workbook: wb) }
        time("edit A1 (dirties all 300k)") { _ = engine.setCellValue(.number(5), at: addr(sheet, 0, 0)) }
    }

    // 6. A full sheet of formulas (the README's 1M-formula open case).
    do {
        let wb = Workbook()
        let sheet = wb.addSheet(named: "Sheet1")
        let rows = CellAddress.maxRows
        sheet.reserveCellCapacity(rows * 2)
        for r in 0..<rows {
            sheet.setCell(Cell(value: .number(Double(r % 997))), at: CellAddress(row: r, column: 0))
            sheet.setCell(Cell(formula: "A\(r + 1)*2"), at: CellAddress(row: r, column: 1))
        }
        let engine = time("engine init, 1,048,576 formulas") { CalculationEngine(workbook: wb) }
        time("edit A1") { _ = engine.setCellValue(.number(5), at: addr(sheet, 0, 0)) }
    }
}

/// Saving a full sheet (1,048,576 rows × 10 columns, one column of
/// formulas): what the main thread pays (the snapshot) and what the
/// background save pays, phase by phase.
func runSaveBenchmark() throws {
    let wb = Workbook.newDocument()
    let sheet = wb.sheets[0]
    let rows = CellAddress.maxRows
    time("build 1,048,576 x 10") {
        sheet.reserveCellCapacity(rows * 10)
        for r in 0..<rows {
            for c in 0..<8 {
                sheet.setCell(Cell(value: .number(Double(r &* 31 &+ c) / 7)), at: CellAddress(row: r, column: c))
            }
            sheet.setCell(Cell(value: .string("item \(r % 5_000)")), at: CellAddress(row: r, column: 8))
            sheet.setCell(Cell(value: .number(Double(r)), formula: "A\(r + 1)*2"), at: CellAddress(row: r, column: 9))
        }
    }
    // The main thread's part of a background save: one snapshot.
    var snapshot = wb
    for _ in 0..<3 { snapshot = time("Workbook.copy() (main thread)") { wb.copy() } }
    // Editing the live sheet while the snapshot is shared copies its cell
    // table once (the first edit after a save starts).
    time("first edit after the snapshot (copy-on-write)") {
        sheet.setCell(Cell(value: .number(1)), at: CellAddress(row: 0, column: 0))
    }
    time("second edit") { sheet.setCell(Cell(value: .number(2)), at: CellAddress(row: 1, column: 0)) }

    for _ in 0..<2 {
        _ = try time("XLSXWriter.data (no progress)") { try XLSXWriter.data(for: snapshot) }
        _ = try time("XLSXWriter.data (progress, ignored)") { try XLSXWriter.data(for: snapshot) { _ in true } }
    }
    let start = Date()
    var marks: [(Double, TimeInterval)] = []
    var calls = 0
    let data = try time("XLSXWriter.data (with progress)") {
        try XLSXWriter.data(for: snapshot) { fraction in
            calls += 1
            if marks.isEmpty || fraction - marks.last!.0 >= 0.1 || fraction == 1 {
                marks.append((fraction, Date().timeIntervalSince(start)))
            }
            return true
        }
    }
    print("progress calls: \(calls)")
    for (fraction, t) in marks { print(String(format: "  %5.1f%% at %6.3fs", fraction * 100, t)) }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("spreadsheet-bench-save.xlsx")
    try time("write (atomic), \(data.count / 1_000_000) MB") { try data.write(to: url, options: .atomic) }
    try? FileManager.default.removeItem(at: url)
}

if CommandLine.arguments.contains("--save-full-sheet") {
    try runSaveBenchmark()
    exit(0)
}

if CommandLine.arguments.contains("--edits") {
    let total = Date()
    runEditBenchmarks()
    print("TOTAL".padding(toLength: 52, withPad: " ", startingAt: 0)
          + String(format: " %8.3fs", Date().timeIntervalSince(total)))
    exit(0)
}

guard CommandLine.arguments.count > 1 else {
    print("usage: spreadsheet-bench <file.csv|file.xlsx> [--save] | --edits")
    exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let total = Date()
let data = try time("read (mapped)") { try Data(contentsOf: url, options: .alwaysMapped) }
let workbook: Workbook
if url.pathExtension.lowercased() == "xlsx" {
    let zip = try ZipArchiveReader(data: data)
    if let entry = zip.entries.first(where: { $0.name.hasPrefix("xl/worksheets/") }) {
        _ = try time("inflate+crc first sheet") { try zip.contents(of: entry) }
    }
    workbook = try time("XLSXReader.read") { try XLSXReader.read(data: data) }
} else {
    workbook = time("CSV.importWorkbook") { CSV.importWorkbook(data: data, sheetName: "Data") }
}
let sheet = workbook.sheets[0]
print("cells: \(sheet.cells.count)  used: \(sheet.usedRange?.a1 ?? "-")")
let used = time("usedRange") { sheet.usedRange }
print("used again: \(used?.a1 ?? "-")")
_ = time("CalculationEngine init") { CalculationEngine(workbook: workbook) }
if CommandLine.arguments.contains("--save") {
    let xlsx = try time("XLSXWriter.data") { try XLSXWriter.data(for: workbook) }
    print("saved xlsx: \(xlsx.count / 1_000_000) MB")
}
print("TOTAL".padding(toLength: 52, withPad: " ", startingAt: 0)
      + String(format: " %8.2fs", Date().timeIntervalSince(total)))
