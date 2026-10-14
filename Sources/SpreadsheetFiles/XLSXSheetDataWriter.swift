import Foundation
import SpreadsheetCore

/// Writes `<sheetData>` straight to bytes: what `cellXML` and the row loop
/// in `worksheetXML` produce, byte for byte (tests compare the two), without
/// building a String per cell.
extension XLSXWriter {
    /// `progress` gets the fraction of the sheet done, every 64K cells; it
    /// throws to stop (Cancel).
    static func appendSheetData(of sheet: Sheet, to out: inout [UInt8], strings: inout SharedStringBuilder,
                                progress: (Double) throws -> Void) rethrows {
        // Rows in order, cells in order: one sort of packed keys,
        // row * 32768 + column + 1. A row written only for its height or
        // hidden flag gets "column" 0, so it sorts first in its row.
        let stride = 32_768
        var keys: [Int] = []
        keys.reserveCapacity(sheet.cells.count)
        for address in sheet.cells.keys where address.row >= 0 && address.column >= 0 && address.column < stride - 1 {
            keys.append(address.row &* stride &+ address.column &+ 1)
        }
        var extraRows = Set<Int>()
        for row in sheet.rowHeights.keys where row >= 0 { extraRows.insert(row) }
        for row in sheet.hiddenRows where row >= 0 && row < CellAddress.maxRows { extraRows.insert(row) }
        for key in keys { extraRows.remove(key / stride) }
        for row in extraRows { keys.append(row &* stride) }
        keys.sort()
        // Collecting and sorting the keys: about a quarter of the time.
        let sortShare = 0.25
        try progress(sortShare)

        out.append(contentsOf: "<sheetData>".utf8)
        var currentRow = Int.min
        let total = Double(max(1, keys.count))
        for (index, key) in keys.enumerated() {
            if index & 0xFFFF == 0xFFFF {
                try progress(sortShare + (1 - sortShare) * Double(index) / total)
            }
            let row = key / stride
            let isRowOnly = key % stride == 0
            if row != currentRow {
                if currentRow != Int.min { out.append(contentsOf: "</row>".utf8) }
                currentRow = row
                out.append(contentsOf: "<row r=\"".utf8)
                appendInt(row + 1, to: &out)
                out.append(0x22)
                if let height = sheet.rowHeights[row] {
                    out.append(contentsOf: " ht=\"\(trimNumber(height))\" customHeight=\"1\"".utf8)
                }
                if sheet.hiddenRows.contains(row) {
                    out.append(contentsOf: " hidden=\"1\"".utf8)
                }
                out.append(0x3E)
            }
            if isRowOnly { continue }
            let address = CellAddress(row: row, column: key % stride - 1)
            if let cell = sheet.cells[address] {
                appendCell(cell, at: address, to: &out, strings: &strings)
            }
        }
        if currentRow != Int.min { out.append(contentsOf: "</row>".utf8) }
        out.append(contentsOf: "</sheetData>".utf8)
        try progress(1)
    }

    /// `cellXML` as bytes.
    static func appendCell(_ cell: Cell, at address: CellAddress, to out: inout [UInt8],
                           strings: inout SharedStringBuilder) {
        let hasFormula = cell.formula != nil
        // The type attribute and <v> body depend on the value.
        var type: StaticString?
        enum Body { case none, number(Double), int(Int), text(String) }
        var body = Body.none
        switch cell.value {
        case .empty: break
        case .number(let n): body = .number(n)
        case .bool(let b): type = "b"; body = .int(b ? 1 : 0)
        case .error(let e): type = "e"; body = .text(e.xlsxRepresentation)
        case .string(let text):
            if hasFormula {
                type = "str"
                body = .text(XML.escapeText(XML.encodeIllegalCharacters(text)))
            } else {
                type = "s"
                body = .int(strings.index(for: text))
            }
        }
        if case .none = body, !hasFormula, cell.styleIndex <= 0 { return }

        out.append(contentsOf: "<c r=\"".utf8)
        appendColumnName(address.column, to: &out)
        appendInt(address.row + 1, to: &out)
        out.append(0x22)
        if cell.styleIndex > 0 {
            out.append(contentsOf: " s=\"".utf8)
            appendInt(cell.styleIndex, to: &out)
            out.append(0x22)
        }
        if let type {
            out.append(contentsOf: " t=\"".utf8)
            out.append(contentsOf: UnsafeBufferPointer(start: type.utf8Start, count: type.utf8CodeUnitCount))
            out.append(0x22)
        }
        out.append(0x3E)
        if let formula = cell.formula {
            out.append(contentsOf: "<f>".utf8)
            out.append(contentsOf: XML.escapeText(FormulaFunctionPrefixes.adding(formula)).utf8)
            out.append(contentsOf: "</f>".utf8)
        }
        switch body {
        case .none: break
        case .number(let n):
            out.append(contentsOf: "<v>".utf8)
            if n == n.rounded(), abs(n) < 1e15 {
                appendInt(Int(n), to: &out)
            } else {
                out.append(contentsOf: serialNumberString(n).utf8)
            }
            out.append(contentsOf: "</v>".utf8)
        case .int(let i):
            out.append(contentsOf: "<v>".utf8)
            appendInt(i, to: &out)
            out.append(contentsOf: "</v>".utf8)
        case .text(let text):
            out.append(contentsOf: "<v>".utf8)
            out.append(contentsOf: text.utf8)
            out.append(contentsOf: "</v>".utf8)
        }
        out.append(contentsOf: "</c>".utf8)
    }

    /// Decimal digits of an integer (with a minus sign when negative).
    static func appendInt(_ value: Int, to out: inout [UInt8]) {
        if value == 0 { out.append(0x30); return }
        var v = value.magnitude
        if value < 0 { out.append(0x2D) }
        var digits: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var count = 0
        withUnsafeMutableBytes(of: &digits) { buffer in
            while v > 0 {
                buffer[count] = UInt8(v % 10) + 0x30
                v /= 10
                count += 1
            }
            for k in stride(from: count - 1, through: 0, by: -1) { out.append(buffer[k]) }
        }
    }

    /// Column letters ("A", "AB", "XFD").
    static func appendColumnName(_ column: Int, to out: inout [UInt8]) {
        // Up to three letters (XFD); longer only for out-of-range columns.
        let n = column + 1
        if n <= 26 {
            out.append(UInt8(64 + n))
        } else if n <= 702 {
            out.append(UInt8(64 + (n - 1) / 26))
            out.append(UInt8(65 + (n - 1) % 26))
        } else if n <= 18_278 {
            let m = n - 703
            out.append(UInt8(65 + m / 676))
            out.append(UInt8(65 + (m / 26) % 26))
            out.append(UInt8(65 + m % 26))
        } else {
            out.append(contentsOf: CellAddress.columnName(column).utf8)
        }
    }
}
