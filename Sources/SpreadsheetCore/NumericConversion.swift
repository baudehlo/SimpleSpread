import Foundation

// Shared numeric helpers for the function library, the number-format renderer
// and the date code. Swift traps on `Int(someDouble)` when the value is out of
// range or not finite, and a cell can hold 1E300; nothing in those files may
// convert a Double to an integer except through `checkedInt`.

/// The one checked Double -> Int conversion: rounds with `rule`, then returns
/// nil (instead of trapping) for NaN, infinities and magnitudes >= `limit`.
/// The default limit matches `Coerce.int` (just under 2^53, where every
/// integer is still exact).
func checkedInt(_ x: Double, rounding rule: FloatingPointRoundingRule = .down,
                limit: Double = 9e15) -> Int? {
    guard x.isFinite else { return nil }
    let r = x.rounded(rule)
    guard abs(r) < limit else { return nil }
    return Int(exactly: r)
}

/// A non-negative decimal number held as its digits:
/// value = 0.d1 d2 d3 ... × 10^exponent.
///
/// Excel works to 15 significant digits: ROUND(1.005,2) is 1.01 and 0.145 in
/// a `0%` format shows 15%, although the binary doubles are a hair below the
/// halfway point. Building the digits from the 15-significant-digit form and
/// rounding on those decimal digits reproduces that, and never needs an
/// integer type, so 1E300 renders as its 301 digits.
struct DecimalDigits: Equatable {
    /// Significant digits without leading or trailing zeros; empty means 0.
    private(set) var digits: [UInt8]
    /// Decimal-point position relative to the first digit.
    private(set) var exponent: Int

    enum Rounding {
        case halfAwayFromZero
        case awayFromZero
        case towardZero
    }

    /// |x| at `significantDigits` (1...17) significant digits.
    init(_ x: Double, significantDigits: Int = 15) {
        digits = []
        exponent = 0
        guard x.isFinite, x != 0 else { return }
        // C's correctly rounded "%.Ne" (String(format:) is several times
        // slower, and this runs for every formatted cell drawn).
        let precision = Int32(max(1, min(17, significantDigits)) - 1)
        var parsedDigits: [UInt8] = []
        var power = 0
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: 40) { buffer in
            let written = withVaList([precision, abs(x)]) {
                vsnprintf(buffer.baseAddress, 40, "%.*e", $0)
            }
            guard written > 0, written < 40 else { return }
            var sawExponent = false
            var exponentNegative = false
            for i in 0..<Int(written) {
                let c = UInt8(bitPattern: buffer[i])
                switch c {
                case UInt8(ascii: "e"), UInt8(ascii: "E"): sawExponent = true
                case UInt8(ascii: "-") where sawExponent: exponentNegative = true
                case UInt8(ascii: "0")...UInt8(ascii: "9"):
                    if sawExponent {
                        power = power * 10 + Int(c - UInt8(ascii: "0"))
                    } else {
                        parsedDigits.append(c - UInt8(ascii: "0"))
                    }
                default: break
                }
            }
            if exponentNegative { power = -power }
        }
        digits = parsedDigits
        exponent = power + 1
        normalize()
    }

    private init(digits: [UInt8], exponent: Int) {
        self.digits = digits
        self.exponent = exponent
        normalize()
    }

    var isZero: Bool { digits.isEmpty }

    private mutating func normalize() {
        while let last = digits.last, last == 0 { digits.removeLast() }
        while let first = digits.first, first == 0 {
            digits.removeFirst()
            exponent -= 1
        }
        if digits.isEmpty { exponent = 0 }
    }

    /// Multiply by 10^places.
    mutating func shift(by places: Int) {
        if !digits.isEmpty { exponent += places }
    }

    /// Round to `fractionDigits` places after the point (negative: to the
    /// left of it).
    func rounded(fractionDigits: Int, _ rule: Rounding = .halfAwayFromZero) -> DecimalDigits {
        guard !digits.isEmpty else { return self }
        let keep = exponent + fractionDigits // digits that survive
        if keep >= digits.count { return self }
        let roundUp: Bool
        switch rule {
        case .towardZero: roundUp = false
        case .awayFromZero: roundUp = true // dropped digits are never all zero
        case .halfAwayFromZero: roundUp = keep >= 0 && digits[keep] >= 5
        }
        if keep < 0 || (keep == 0 && !roundUp) {
            // Everything is dropped.
            if !roundUp { return DecimalDigits(digits: [], exponent: 0) }
            return DecimalDigits(digits: [1], exponent: 1 - fractionDigits)
        }
        var kept = Array(digits[0..<keep])
        var newExponent = exponent
        if roundUp {
            if kept.isEmpty {
                kept = [1]
                newExponent += 1
            } else {
                var i = kept.count - 1
                while true {
                    if kept[i] < 9 { kept[i] += 1; break }
                    kept[i] = 0
                    if i == 0 { kept.insert(1, at: 0); newExponent += 1; break }
                    i -= 1
                }
            }
        }
        return DecimalDigits(digits: kept, exponent: newExponent)
    }

    /// Digits before the point ("0" when below 1).
    var integerString: String {
        guard exponent > 0 else { return "0" }
        return asciiDigits(from: 0, count: exponent)
    }

    /// Exactly `count` digits after the point (zero padded, truncated).
    func fractionString(count: Int) -> String {
        asciiDigits(from: exponent, count: count)
    }

    /// `count` digits starting at digit index `start` (out of range = 0).
    private func asciiDigits(from start: Int, count: Int) -> String {
        guard count > 0 else { return "" }
        var bytes = [UInt8](repeating: UInt8(ascii: "0"), count: count)
        for i in 0..<count {
            let index = start + i
            if index >= 0 && index < digits.count { bytes[i] += digits[index] }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Number of digits before the point (0 when below 1).
    var integerDigitCount: Int { max(0, exponent) }

    var doubleValue: Double {
        guard !digits.isEmpty else { return 0 }
        return Double("0." + digits.map(String.init).joined() + "e\(exponent)") ?? .infinity
    }
}

/// `x` rounded to Excel's 15 significant digits (removes binary fuzz such as
/// 0.1 + 0.2 = 0.30000000000000004).
func roundedToFifteenDigits(_ x: Double) -> Double {
    guard x.isFinite, x != 0 else { return x }
    let magnitude = DecimalDigits(x).doubleValue
    return x < 0 ? -magnitude : magnitude
}

/// Excel's ROUND/ROUNDUP/ROUNDDOWN/TRUNC: decimal rounding of the
/// 15-significant-digit value. Returns nil when the result overflows.
func excelRound(_ x: Double, places: Int, _ rule: DecimalDigits.Rounding) -> Double? {
    guard x.isFinite else { return nil }
    if x == 0 { return 0 }
    let magnitude = DecimalDigits(x).rounded(fractionDigits: places, rule).doubleValue
    guard magnitude.isFinite else { return nil }
    return x < 0 ? -magnitude : magnitude
}
