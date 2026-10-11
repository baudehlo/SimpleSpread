import CoreGraphics
import SpreadsheetCore

/// Cell text indent (XLSX `<alignment indent="n">`). Excel indents by a few
/// characters' width per level; 10pt per level at the 12pt default font
/// matches what Excel shows for a pivot's nested row labels, and the step
/// grows with the cell's font so larger text keeps the same proportion.
enum CellTextIndent {
    static let pointsPerLevel: CGFloat = 10

    static func width(level: Int, fontSize: CGFloat) -> CGFloat {
        guard level > 0 else { return 0 }
        return CGFloat(level) * pointsPerLevel * fontSize / CGFloat(CellStyle.defaultFontSize)
    }

    /// `rect` with the indent taken off the side the text is aligned to:
    /// left-aligned text moves right, right-aligned text moves left.
    /// Centered text ignores the indent, as in Excel.
    static func apply(_ width: CGFloat, to rect: CGRect, rightAligned: Bool, centered: Bool) -> CGRect {
        guard width > 0, !centered else { return rect }
        var r = rect
        let w = min(width, r.width)
        if !rightAligned { r.origin.x += w }
        r.size.width -= w
        return r
    }
}

/// The banding a pivot table gets at render time, in the spirit of Excel's
/// default PivotStyleLight16: shaded header rows with a rule under them,
/// and shaded grand-total rows with a rule above. Derived from cell roles
/// (never stored in the cells), so files are unchanged.
struct PivotBands: Equatable {
    /// The table body (`location`); bands span its columns.
    var location: CellRange
    /// Rows of the header band (caption and column-label rows); nil when
    /// the table has no header rows.
    var headerRows: ClosedRange<Int>?

    /// Header rows run from the top of the body down to the first row that
    /// holds row labels or values.
    init(location: CellRange, role: (CellAddress) -> PivotCellRole?) {
        self.location = location
        let columns = location.start.column...location.end.column
        var firstBodyRow = location.end.row + 1
        rows: for row in location.start.row...location.end.row {
            for column in columns {
                switch role(CellAddress(row: row, column: column)) {
                case .rowLabel, .value, .subtotalValue, .grandTotalValue:
                    firstBodyRow = row
                    break rows
                default:
                    continue
                }
            }
        }
        headerRows = firstBodyRow > location.start.row ? location.start.row...(firstBodyRow - 1) : nil
    }

    var columns: ClosedRange<Int> { location.start.column...location.end.column }

    /// A grand-total row: its first column carries the grand-total caption.
    /// (Several with the values on rows: "Total Sum of X", "Total Count of Y".)
    func isGrandTotalRow(_ row: Int, role: (CellAddress) -> PivotCellRole?) -> Bool {
        guard row >= location.start.row, row <= location.end.row else { return false }
        return role(CellAddress(row: row, column: location.start.column)) == .grandTotalLabel
    }

    /// Whether `address` sits in a shaded band.
    func isShaded(_ address: CellAddress, role: (CellAddress) -> PivotCellRole?) -> Bool {
        guard columns.contains(address.column) else { return false }
        if let headerRows, headerRows.contains(address.row) { return true }
        return isGrandTotalRow(address.row, role: role)
    }

    /// Roles drawn bold: headers, totals and filter field names.
    static func isBold(_ role: PivotCellRole) -> Bool {
        switch role {
        case .header, .columnLabel, .subtotalLabel, .grandTotalLabel,
             .subtotalValue, .grandTotalValue, .filterLabel:
            return true
        case .rowLabel, .value, .filterValue:
            return false
        }
    }
}
