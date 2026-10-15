import Foundation

/// Rows or columns inserted or deleted on one sheet.
///
/// The one description of a structural edit: everything that holds a
/// position (cell storage, formula references, the calculation graph,
/// layout tables, pivot tables, and any other part of a file anchored to
/// cells) is moved by it, so the parts agree on where each row or column
/// went.
public struct StructuralChange: Hashable, Sendable {
    public let sheetID: Int
    /// Rows when true, columns when false.
    public let axisIsRow: Bool
    /// The first row or column inserted or deleted (zero-based).
    public let index: Int
    /// Positive: inserted; negative: deleted.
    public let count: Int

    public init(sheetID: Int, axisIsRow: Bool, index: Int, count: Int) {
        self.sheetID = sheetID
        self.axisIsRow = axisIsRow
        self.index = index
        self.count = count
    }

    public var isInsert: Bool { count > 0 }

    /// The opposite change: the same rows or columns deleted again, or
    /// inserted back (empty).
    public var inverse: StructuralChange {
        StructuralChange(sheetID: sheetID, axisIsRow: axisIsRow, index: index, count: -count)
    }

    /// The last deleted row or column (deletes only).
    private var deletedEnd: Int { index - count - 1 }

    /// Where a row or column at `pos` lands; nil when it's deleted.
    public func position(after pos: Int) -> Int? {
        if count < 0 {
            if pos < index { return pos }
            return pos > deletedEnd ? pos + count : nil
        }
        return pos >= index ? pos + count : pos
    }

    /// Where a row or column now at `pos` was before the change; nil for
    /// one the change inserted.
    public func position(before pos: Int) -> Int? {
        if count > 0 {
            if pos < index { return pos }
            return pos >= index + count ? pos - count : nil
        }
        return pos >= index ? pos - count : pos
    }

    /// True when the change deletes the row or column at `pos`.
    public func deletes(_ pos: Int) -> Bool {
        count < 0 && pos >= index && pos <= deletedEnd
    }

    /// Where a cell on the edited sheet lands; nil when it's deleted.
    public func address(after address: CellAddress) -> CellAddress? {
        moving(address, by: position(after:))
    }

    /// Where a cell now at `address` on the edited sheet was before the
    /// change; nil for a cell in inserted rows or columns.
    public func address(before address: CellAddress) -> CellAddress? {
        moving(address, by: position(before:))
    }

    public func deletes(_ address: CellAddress) -> Bool {
        deletes(axisIsRow ? address.row : address.column)
    }

    private func moving(_ address: CellAddress, by map: (Int) -> Int?) -> CellAddress? {
        if axisIsRow {
            return map(address.row).map { CellAddress(row: $0, column: address.column) }
        }
        return map(address.column).map { CellAddress(row: address.row, column: $0) }
    }

    /// A reference to the edited sheet after the change, with formula
    /// semantics: absolute parts move too, ranges spanning the edit grow
    /// or shrink, and nil means every cell it named was deleted (#REF!).
    public func adjusting(_ ref: ReferenceExpr) -> ReferenceExpr? {
        ref.adjustedForStructuralChange(axisIsRow: axisIsRow, index: index, count: count)
    }

    /// What the change does to the cells a reference to the edited sheet
    /// reads.
    public enum ReferenceEffect: Equatable, Sendable {
        /// Wholly before the change: same text, same cells.
        case untouched
        /// Wholly after it: the reference moves with its cells, so it reads
        /// the same contents.
        case shifted
        /// Spans the change, names deleted cells, or runs the whole length
        /// of the axis: what it reads may be different.
        case reshaped
    }

    public func effect(on ref: ReferenceExpr) -> ReferenceEffect {
        let first = axisIsRow ? ref.start.row : ref.start.column
        let end = ref.end ?? ref.start
        let last = axisIsRow ? end.row : end.column
        // A whole column under a row change (or a whole row under a column
        // change) always spans it.
        guard let first, let last else { return .reshaped }
        let low = min(first, last), high = max(first, last)
        if high < index { return .untouched }
        if count > 0 {
            let limit = axisIsRow ? CellAddress.maxRows : CellAddress.maxColumns
            // Pushed off the sheet's edge: not the same cells any more.
            return low >= index && high + count < limit ? .shifted : .reshaped
        }
        return low > deletedEnd ? .shifted : .reshaped
    }
}
