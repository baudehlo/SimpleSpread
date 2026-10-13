import Foundation
import SpreadsheetCore
import SpreadsheetFiles

// Times each phase of loading a large file, in a release build:
//   swift run -c release spreadsheet-bench <file.csv|file.xlsx> [--save]
// Not part of the app; for measuring big-file performance.

func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
    let start = Date()
    let result = try body()
    print(String(format: "%-28@ %8.2fs", label as NSString, Date().timeIntervalSince(start)))
    return result
}

guard CommandLine.arguments.count > 1 else {
    print("usage: spreadsheet-bench <file.csv|file.xlsx>")
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
print(String(format: "%-28@ %8.2fs", "TOTAL" as NSString, Date().timeIntervalSince(total)))
