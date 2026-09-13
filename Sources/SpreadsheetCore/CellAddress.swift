import Foundation

/// A zero-based (row, column) cell coordinate. Row 0 / column 0 is A1.
public struct CellAddress: Hashable, Sendable, Comparable, CustomStringConvertible, Codable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    /// Parse an A1-style reference such as "B12". Absolute markers ($) are accepted and ignored.
    public init?(a1 : String) {
        guard let (addr, _, _) = CellAddress.parseA1(a1) else { return nil }
        self = addr
    }

    /// Parse A1 text returning the address plus absolute flags: ($col, $row).
    public static func parseA1(_ text: String) -> (CellAddress, colAbsolute: Bool, rowAbsolute: Bool)? {
        var chars = Substring(text)
        var colAbs = false, rowAbs = false
        if chars.first == "$" { colAbs = true; chars = chars.dropFirst() }
        var col = 0, colDigits = 0
        while let c = chars.first, c.isLetter, let ascii = c.uppercased().unicodeScalars.first?.value,
              ascii >= 65, ascii <= 90 {
            col = col * 26 + Int(ascii - 64)
            colDigits += 1
            chars = chars.dropFirst()
        }
        guard colDigits > 0, colDigits <= 3 else { return nil }
        if chars.first == "$" { rowAbs = true; chars = chars.dropFirst() }
        guard !chars.isEmpty, chars.allSatisfy({ $0.isNumber }), let row = Int(chars), row >= 1 else { return nil }
        return (CellAddress(row: row - 1, column: col - 1), colAbs, rowAbs)
    }

    /// Column letters for a zero-based column index (0 -> "A", 26 -> "AA").
    public static func columnName(_ column: Int) -> String {
        var n = column + 1
        var name = ""
        while n > 0 {
            let rem = (n - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + rem))) + name
            n = (n - 1) / 26
        }
        return name
    }

    /// Zero-based column index for column letters ("A" -> 0). Case-insensitive.
    public static func columnIndex(_ name: String) -> Int? {
        guard !name.isEmpty else { return nil }
        var col = 0
        for c in name.uppercased().unicodeScalars {
            guard c.value >= 65, c.value <= 90 else { return nil }
            col = col * 26 + Int(c.value - 64)
        }
        return col - 1
    }

    /// A1 representation, e.g. "C4".
    public var a1: String {
        CellAddress.columnName(column) + String(row + 1)
    }

    public var description: String { a1 }

    public static func < (lhs: CellAddress, rhs: CellAddress) -> Bool {
        if lhs.row != rhs.row { return lhs.row < rhs.row }
        return lhs.column < rhs.column
    }

    public func offset(rows: Int, columns: Int) -> CellAddress {
        CellAddress(row: row + rows, column: column + columns)
    }

    public var isValid: Bool { row >= 0 && column >= 0 && row < CellAddress.maxRows && column < CellAddress.maxColumns }

    /// Generous fixed bounds (Excel allows 1,048,576 x 16,384; we cap lower).
    public static let maxRows = 1_048_576
    public static let maxColumns = 16_384
}

/// A normalized rectangular range of cells (start <= end on both axes).
public struct CellRange: Hashable, Sendable, CustomStringConvertible, Codable {
    public var start: CellAddress
    public var end: CellAddress

    public init(start: CellAddress, end: CellAddress) {
        self.start = CellAddress(row: min(start.row, end.row), column: min(start.column, end.column))
        self.end = CellAddress(row: max(start.row, end.row), column: max(start.column, end.column))
    }

    public init(_ single: CellAddress) {
        self.start = single
        self.end = single
    }

    /// Parse "A1:B3" or a single "A1".
    public init?(a1: String) {
        let parts = a1.split(separator: ":", maxSplits: 1)
        if parts.count == 2 {
            guard let s = CellAddress(a1: String(parts[0])), let e = CellAddress(a1: String(parts[1])) else { return nil }
            self.init(start: s, end: e)
        } else if let s = CellAddress(a1: a1) {
            self.init(s)
        } else {
            return nil
        }
    }

    public var a1: String {
        start == end ? start.a1 : "\(start.a1):\(end.a1)"
    }

    public var description: String { a1 }

    public var rowCount: Int { end.row - start.row + 1 }
    public var columnCount: Int { end.column - start.column + 1 }
    public var cellCount: Int { rowCount * columnCount }
    public var isSingleCell: Bool { start == end }

    public func contains(_ address: CellAddress) -> Bool {
        address.row >= start.row && address.row <= end.row &&
        address.column >= start.column && address.column <= end.column
    }

    public func intersects(_ other: CellRange) -> Bool {
        !(other.start.row > end.row || other.end.row < start.row ||
          other.start.column > end.column || other.end.column < start.column)
    }

    public func union(_ other: CellRange) -> CellRange {
        CellRange(
            start: CellAddress(row: min(start.row, other.start.row), column: min(start.column, other.start.column)),
            end: CellAddress(row: max(end.row, other.end.row), column: max(end.column, other.end.column))
        )
    }

    /// Iterate addresses in row-major order.
    public var addresses: [CellAddress] {
        var out: [CellAddress] = []
        out.reserveCapacity(cellCount)
        for r in start.row...end.row {
            for c in start.column...end.column {
                out.append(CellAddress(row: r, column: c))
            }
        }
        return out
    }

    public func forEachAddress(_ body: (CellAddress) -> Void) {
        for r in start.row...end.row {
            for c in start.column...end.column {
                body(CellAddress(row: r, column: c))
            }
        }
    }
}
