import Foundation
import Testing
@testable import SpreadsheetCore

/// AutoFilter and current-region results on larger sheets, with timing
/// guards for paths that used to be quadratic (review #16). The limits are
/// generous (debug build, slow CI); the quadratic versions took tens of
/// seconds at these sizes.
@Suite("Filter and region scaling")
struct DataCommandScalingTests {
    func a(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }
    func r(_ a1: String) -> CellRange { CellRange(a1: a1)! }

    func seconds(_ body: () -> Void) -> Double {
        let start = Date()
        body()
        return Date().timeIntervalSince(start)
    }

    // MARK: Filter values

    @Test func filterValuesMergeCaseVariantsAndKeepTheFirstSpelling() {
        let sheet = Sheet(id: 1, name: "S")
        let wb = Workbook()
        wb.insertSheet(sheet, at: 0)
        let texts = ["Head", "apple", "APPLE", "Pear", "", "Straße", "STRASSE", "pear", "Apple"]
        for (i, text) in texts.enumerated() where !text.isEmpty {
            sheet.setCell(Cell(value: .string(text)), at: CellAddress(row: i, column: 0))
        }
        sheet.autoFilter = AutoFilter(range: CellRange(start: a("A1"), end: CellAddress(row: texts.count - 1, column: 0)))
        let result = wb.filterValues(onSheetID: 1, columnOffset: 0)
        // Case-insensitive, as caseInsensitiveCompare was (ß folds to ss).
        #expect(result.values == ["apple", "Pear", "Straße"])
        #expect(result.hasBlanks)
    }

    @Test func valueFilterMatchesCaseInsensitively() {
        let filter = ColumnFilter(values: ["APPLE", "straße"], includeBlanks: false)
        #expect(filter.passes(.string("apple"), displayText: "apple"))
        #expect(filter.passes(.string("Strasse"), displayText: "Strasse"))
        #expect(!filter.passes(.string("pear"), displayText: "pear"))
        #expect(!filter.passes(.empty, displayText: ""))
        var edited = filter
        edited.values = ["Pear"]
        #expect(edited.passes(.string("PEAR"), displayText: "PEAR"))
        #expect(!edited.passes(.string("apple"), displayText: "apple"))
    }

    @Test func filterOverManyDistinctValuesIsQuick() {
        let wb = Workbook()
        let sheet = wb.addSheet()
        let n = 20_000
        sheet.setCell(Cell(value: .string("Name")), at: CellAddress(row: 0, column: 0))
        for i in 1...n {
            sheet.setCell(Cell(value: .string("item \(i)")), at: CellAddress(row: i, column: 0))
        }
        sheet.autoFilter = AutoFilter(range: CellRange(start: a("A1"), end: CellAddress(row: n, column: 0)))
        var values: [String] = []
        let listTime = seconds { values = wb.filterValues(onSheetID: sheet.id, columnOffset: 0).values }
        #expect(values.count == n)
        #expect(listTime < 3, "value list took \(listTime)s")

        // Keep half the values shown.
        let shown = Set(values.enumerated().filter { $0.offset.isMultiple(of: 2) }.map { $0.element.uppercased() })
        sheet.autoFilter?.columns[0] = ColumnFilter(values: shown)
        let applyTime = seconds { wb.applyAutoFilter(onSheetID: sheet.id) }
        #expect(sheet.hiddenRows.count == n / 2)
        #expect(applyTime < 3, "applying the filter took \(applyTime)s")
    }

    // MARK: Current region

    /// The original pass-by-pass algorithm, as the reference for semantics.
    func naiveRegion(_ sheet: Sheet, _ address: CellAddress) -> CellRange {
        var region = CellRange(address)
        func filled(_ row: Int, _ column: Int) -> Bool {
            row >= 0 && column >= 0 && !sheet.value(at: CellAddress(row: row, column: column)).isEmpty
        }
        var changed = true
        while changed {
            changed = false
            let rows = max(0, region.start.row - 1)...(region.end.row + 1)
            let columns = max(0, region.start.column - 1)...(region.end.column + 1)
            if columns.contains(where: { filled(region.start.row - 1, $0) }) { region.start.row -= 1; changed = true }
            if columns.contains(where: { filled(region.end.row + 1, $0) }) { region.end.row += 1; changed = true }
            if rows.contains(where: { filled($0, region.start.column - 1) }) { region.start.column -= 1; changed = true }
            if rows.contains(where: { filled($0, region.end.column + 1) }) { region.end.column += 1; changed = true }
        }
        return region
    }

    @Test func currentRegionMatchesTheReferenceOnRandomSheets() {
        var rng = SplitMix(seed: 7)
        for _ in 0..<200 {
            let sheet = Sheet(id: 1, name: "S")
            let density = Double(rng.next() % 50) / 100 + 0.05
            for row in 0..<12 {
                for column in 0..<12 where Double(rng.next() % 1000) / 1000 < density {
                    sheet.setCell(Cell(value: .number(1)), at: CellAddress(row: row, column: column))
                }
            }
            let start = CellAddress(row: Int(rng.next() % 12), column: Int(rng.next() % 12))
            #expect(sheet.currentRegion(around: start) == naiveRegion(sheet, start))
        }
    }

    @Test func currentRegionFollowsDiagonalsAndStaircases() {
        let sheet = Sheet(id: 1, name: "S")
        for i in 0..<30 { sheet.setCell(Cell(value: .number(1)), at: CellAddress(row: 5 + i, column: 3 + i)) }
        #expect(sheet.currentRegion(around: CellAddress(row: 20, column: 18))
                == CellRange(start: CellAddress(row: 5, column: 3), end: CellAddress(row: 34, column: 32)))
        // An empty cell next to nothing is its own region.
        #expect(sheet.currentRegion(around: a("A1")) == r("A1"))
    }

    @Test func currentRegionOfATallTableIsQuick() {
        let sheet = Sheet(id: 1, name: "S")
        let rows = 20_000
        for row in 0..<rows {
            for column in 0..<5 {
                sheet.setCell(Cell(value: .number(Double(row))), at: CellAddress(row: row, column: column))
            }
        }
        var region = CellRange(a("A1"))
        let time = seconds { region = sheet.currentRegion(around: CellAddress(row: 500, column: 2)) }
        #expect(region == CellRange(start: a("A1"), end: CellAddress(row: rows - 1, column: 4)))
        #expect(time < 3, "current region took \(time)s")
    }
}

/// A small deterministic generator for randomized tests.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
