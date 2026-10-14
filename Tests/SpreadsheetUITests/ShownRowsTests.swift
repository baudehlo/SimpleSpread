import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetUI

/// Drawing visits the rows that show, skipping runs of hidden rows in one
/// step (review #33: a filtered million-row sheet showing a few rows far
/// apart walked every hidden row between them).
@Suite("Shown rows")
struct ShownRowsTests {
    @Test func matchesCheckingEveryRow() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<100 {
            let sheet = Sheet(id: 1, name: "S")
            for row in 0..<300 where Int.random(in: 0..<3, using: &rng) == 0 {
                sheet.hiddenRows.insert(row)
            }
            for _ in 0..<10 {
                sheet.rowHeights[Int.random(in: 0..<300, using: &rng)] = [0, 30, 40].randomElement(using: &rng)!
            }
            let layout = GridLayout(sheet: sheet)
            let lower = Int.random(in: 0..<300, using: &rng)
            let upper = Int.random(in: lower..<320, using: &rng)
            let naive = (lower...upper).filter { layout.rowHeight($0) > 0 }
            #expect(layout.shownRows(in: lower...upper) == naive)
        }
    }

    @Test func noHiddenRowsShowsTheWholeRange() {
        let layout = GridLayout(sheet: Sheet(id: 1, name: "S"))
        #expect(layout.shownRows(in: 5...9) == [5, 6, 7, 8, 9])
    }

    @Test func aFilteredMillionRowsSkipsTheHiddenOnes() {
        let sheet = Sheet(id: 1, name: "S")
        let shown: Set<Int> = [10, 500_000, 999_999]
        sheet.hiddenRows = Set((0..<1_000_000).filter { !shown.contains($0) })
        sheet.setCell(Cell(value: .number(1)), at: CellAddress(row: 1_000_000, column: 0))
        let layout = GridLayout(sheet: sheet)
        let start = Date()
        var rows: [Int] = []
        for _ in 0..<200 {
            rows = layout.shownRows(in: 0...1_000_001)
        }
        let time = Date().timeIntervalSince(start)
        #expect(rows == [10, 500_000, 999_999, 1_000_000, 1_000_001])
        #expect(time < 1, "200 lookups took \(time)s")
        // The rows a screenful at the top shows.
        let visible = layout.visibleRows(in: CGRect(x: 0, y: 0, width: 100, height: 200))
        #expect(layout.shownRows(in: visible) == visible.filter { layout.rowHeight($0) > 0 })
        #expect(layout.shownRows(in: visible).prefix(4) == [10, 500_000, 999_999, 1_000_000])
    }
}
