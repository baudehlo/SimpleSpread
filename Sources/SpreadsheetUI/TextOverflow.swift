import CoreGraphics

/// Excel-style horizontal text overflow. A text value that does not wrap and
/// is wider than its column spills into the EMPTY cells next to it: to the
/// right for left-aligned text, to the left for right-aligned text, and to
/// both sides for centered text. The first non-empty neighbour stops it,
/// and the text is clipped there.
public enum TextOverflow {
    public enum Direction: Sendable {
        case right   // left-aligned text
        case left    // right-aligned text
        case both    // centered text
    }

    /// The columns the text in `column` may draw across.
    /// - Parameters:
    ///   - neededWidth: the text width plus the cell's horizontal insets.
    ///   - columnWidth: width of a column.
    ///   - isEmpty: whether the cell in a column of the same row is empty.
    ///   - columnCount: columns the grid presents (the span never leaves them).
    public static func span(column: Int,
                            neededWidth: CGFloat,
                            direction: Direction,
                            columnCount: Int,
                            columnWidth: (Int) -> CGFloat,
                            isEmpty: (Int) -> Bool) -> ClosedRange<Int> {
        let own = columnWidth(column)
        guard neededWidth > own else { return column...column }
        var first = column
        var last = column
        switch direction {
        case .right:
            var width = own
            while width < neededWidth, last + 1 < columnCount, isEmpty(last + 1) {
                last += 1
                width += columnWidth(last)
            }
        case .left:
            var width = own
            while width < neededWidth, first - 1 >= 0, isEmpty(first - 1) {
                first -= 1
                width += columnWidth(first)
            }
        case .both:
            // Centered on its own cell: each side has to hold half the excess.
            let half = (neededWidth - own) / 2
            var right: CGFloat = 0
            while right < half, last + 1 < columnCount, isEmpty(last + 1) {
                last += 1
                right += columnWidth(last)
            }
            var left: CGFloat = 0
            while left < half, first - 1 >= 0, isEmpty(first - 1) {
                first -= 1
                left += columnWidth(first)
            }
        }
        return first...last
    }
}
