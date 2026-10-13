import Foundation

/// A running summary of the values one pivot cell (or total) covers: every
/// "Summarize Values By" function can be read from it, so the engine adds
/// each record once instead of re-filtering the records for every cell.
///
/// Values are added in record order, so sums and products come out exactly
/// as summing the cell's records in order would.
struct PivotAccumulator {
    /// Records added (blank ones included).
    private(set) var records = 0
    /// Non-blank values (numbers, text, booleans, errors).
    private(set) var nonBlank = 0
    private(set) var numbers = 0
    private(set) var sum = 0.0
    private(set) var product = 1.0
    private(set) var minimum = Double.infinity
    private(set) var maximum = -Double.infinity
    private(set) var firstError: CellError?
    /// The numbers themselves, kept only when a variance is wanted (it is
    /// computed in two passes, as Excel's results need).
    private(set) var values: [Double]?

    init(keepValues: Bool = false) {
        values = keepValues ? [] : nil
    }

    mutating func add(_ value: PivotValue) {
        records += 1
        switch value {
        case .missing:
            return
        case .number(let x), .date(let x):
            nonBlank += 1
            numbers += 1
            sum += x
            product *= x
            minimum = Swift.min(minimum, x)
            maximum = Swift.max(maximum, x)
            values?.append(x)
        case .error(let e):
            nonBlank += 1
            if firstError == nil { firstError = e }
        case .string, .bool:
            nonBlank += 1
        }
    }

    /// The summary `fn` of what was added; nil shows as a blank cell.
    func result(_ fn: PivotSubtotal) -> CellValue? {
        guard records > 0 else { return nil }
        switch fn {
        case .count: return nonBlank > 0 ? .number(Double(nonBlank)) : nil
        case .countNums: return nonBlank > 0 ? .number(Double(numbers)) : nil
        default: break
        }
        if let firstError { return .error(firstError) }
        if nonBlank == 0 { return nil }
        switch fn {
        case .sum: return .number(sum)
        case .average: return numbers == 0 ? .error(.div0) : .number(sum / Double(numbers))
        case .max: return .number(numbers == 0 ? 0 : maximum)
        case .min: return .number(numbers == 0 ? 0 : minimum)
        case .product: return .number(numbers == 0 ? 0 : product)
        case .stdDev, .var, .stdDevp, .varp:
            let population = fn == .stdDevp || fn == .varp
            let n = numbers
            if n == 0 || (n < 2 && !population) { return .error(.div0) }
            let variance: Double
            if let values {
                let mean = values.reduce(0, +) / Double(n)
                let ss = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                variance = ss / Double(population ? n : n - 1)
            } else {
                // Not reached: the engine keeps values whenever a variance
                // can be asked for. A finite fallback all the same.
                return .error(.na)
            }
            return .number(fn == .stdDev || fn == .stdDevp ? variance.squareRoot() : variance)
        case .count, .countNums: return nil
        }
    }

    static func summarizing(_ values: [PivotValue]) -> PivotAccumulator {
        var a = PivotAccumulator(keepValues: true)
        for v in values { a.add(v) }
        return a
    }
}

extension PivotSubtotal {
    /// Summaries that need every number, not just running totals.
    var needsValues: Bool { self == .stdDev || self == .stdDevp || self == .var || self == .varp }
}
