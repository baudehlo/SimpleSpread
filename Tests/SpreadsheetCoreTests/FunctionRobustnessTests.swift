import Foundation
import Testing
@testable import SpreadsheetCore

/// Inputs that used to trap (Double -> Int conversions) or loop for ever
/// (code review 2026-10-13, findings #4 and #18). Every one of these must now
/// return a value or an error, quickly.
@Suite("Function robustness: extreme inputs")
struct FunctionRobustnessTests {
    @Test func formerlyCrashingFunctionInputs() {
        // ISEVEN/ISODD: every double this large is an even integer.
        #expect(evalBool("ISEVEN(1E20)") == true)
        #expect(evalBool("ISODD(1E20)") == false)
        #expect(evalBool("ISODD(-3.7)") == true)
        // GCD/LCM: Excel rejects arguments >= 2^53 and results that overflow.
        #expect(evalError("GCD(1E300)") == .num)
        #expect(evalError("GCD(12,1E20)") == .num)
        #expect(evalError("LCM(1E15,999999999999999)") == .num)
        #expect(evalError("LCM(9007199254740990,9007199254740989)") == .num)
        #expect(evalNumber("GCD(12,18)") == 6)
        #expect(evalNumber("LCM(4,6,10)") == 60)
        // Date functions: serials outside 0...2958465 are #NUM!.
        #expect(evalError("NETWORKDAYS(1,1E20)") == .num)
        #expect(evalError("NETWORKDAYS(1E20,1)") == .num)
        #expect(evalError("NETWORKDAYS(1,10,1E20)") == .num)
        #expect(evalError("YEAR(1E20)") == .num)
        #expect(evalError("MONTH(-1)") == .num)
        #expect(evalError("YEAR(2958466)") == .num)
        #expect(evalNumber("YEAR(2958465)") == 9999)
        #expect(evalError("WEEKDAY(1E20)") == .num)
        #expect(evalError("WEEKNUM(1E20)") == .num)
        #expect(evalError("EDATE(45000,1E15)") == .num)
        #expect(evalError("EOMONTH(1E20,1)") == .num)
        #expect(evalError("DATEDIF(1,1E20,\"D\")") == .num)
        #expect(evalError("YEARFRAC(1,1E20)") == .num)
        #expect(evalError("DAYS(1E20,1)") == .num)
        #expect(evalError("DATE(2020,1E15,1)") == .num)
        // TEXT with 20+ decimals used Int64(scaled).
        #expect(evalString("TEXT(1.5,\"0.00000000000000000000\")") == "1.50000000000000000000")
        #expect(evalString("TEXT(1E20,\"0\")") == "100000000000000000000")
        // REPT: s.count * n used to overflow.
        #expect(evalError("REPT(REPT(\"x\",30000),8E15)") == .value)
    }

    @Test func formerlyCrashingRenderings() {
        // A date-formatted cell holding 1E20 trapped while DRAWING.
        #expect(NumberFormatEngine.formatNumber(1e20, code: "m/d/yyyy") == "#####")
        #expect(NumberFormatEngine.formatNumber(-1, code: "m/d/yyyy") == "#####")
        #expect(NumberFormatEngine.formatNumber(1e20, code: "[h]:mm") == "#####")
        #expect(NumberFormatEngine.formatNumber(1e300, code: "hh:mm:ss") == "#####")
        #expect(NumberFormatEngine.displayString(for: .number(1e20), format: .date) == "#####")
        // Excel's TEXT returns #VALUE! for a date it cannot show.
        #expect(evalError("TEXT(1E20,\"m/d/yyyy\")") == .value)
        // Huge values in numeric formats print exact (15-significant) digits.
        #expect(NumberFormatEngine.formatNumber(1e20, code: "0.00") == "100000000000000000000.00")
        #expect(NumberFormatEngine.formatNumber(1e300, code: "0").count == 301)
        #expect(NumberFormatEngine.formatNumber(1.5, code: String(repeating: "0", count: 40) + ".0")
                == String(repeating: "0", count: 39) + "1.5")
        #expect(NumberFormatEngine.formatNumber(1e-300, code: "0.00E+00") == "1.00E-300")
        #expect(NumberFormatEngine.formatNumber(1.7976931348623157e308, code: "0.0E+0") == "1.8E+308")
    }

    @Test func excelDateRangeIsChecked() {
        #expect(ExcelDate.components(fromSerial: 1e20) == nil)
        #expect(ExcelDate.components(fromSerial: -1) == nil)
        #expect(ExcelDate.components(fromSerial: 2958466) == nil)
        #expect(ExcelDate.components(fromSerial: 2958465.5)?.year == 9999)
        #expect(ExcelDate.components(fromSerial: 0) != nil)
    }

    /// Source guard: no bare Double -> Int conversions in the function
    /// library, the renderer or the date code. Use `checkedInt` (it returns
    /// nil instead of trapping) or `Coerce.int`.
    @Test func noBareDoubleToIntConversions() throws {
        let sourceDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SpreadsheetCore")
        let files = try FileManager.default.contentsOfDirectory(atPath: sourceDir.path)
            .filter { $0.hasPrefix("Functions") || $0 == "FunctionRegistry.swift"
                || $0 == "NumberFormat.swift" || $0 == "ExcelDate.swift" }
        #expect(files.count >= 10)
        // Int(...) / Int64(...) of a parenthesised expression, or on a line
        // with a typical Double expression after it. Heuristic (Swift has no
        // types at grep level), but it flags every conversion that crashed.
        let pattern = try NSRegularExpression(
            pattern: #"\bU?Int(64|32)?\((?!exactly:)(\(|.*(rounded|floor|ceil|log10|truncatingRemainder|\bn\b|\$0|serial|scaled|totalSeconds|\bday\b|Double))"#)
        // generalString (NumberFormat.swift) is guarded by |n| < 1e15 and is
        // maintained separately (display/round-trip split).
        let allowed = ["return String(Int64(n))", "let digitsBefore = max(1, Int(floor(log10(absN))) + 1)"]
        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: sourceDir.appendingPathComponent(file), encoding: .utf8)
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if !line.trimmingCharacters(in: .whitespaces).hasPrefix("//"),
                   pattern.firstMatch(in: line, range: range) != nil,
                   !allowed.contains(where: { line.contains($0) }) {
                    offenders.append("\(file):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(offenders.isEmpty, "bare Double->Int conversions:\n\(offenders.joined(separator: "\n"))")
    }

    @Test func checkedIntHelper() {
        #expect(checkedInt(3.7) == 3)
        #expect(checkedInt(-3.2) == -4)
        #expect(checkedInt(-3.7, rounding: .towardZero) == -3)
        #expect(checkedInt(1e20) == nil)
        #expect(checkedInt(.nan) == nil)
        #expect(checkedInt(.infinity) == nil)
        #expect(checkedInt(8.9e15) == 8_900_000_000_000_000)
    }
}

/// Finding #18: loops that ran once per day / per period / per k.
@Suite("Function robustness: no unbounded loops")
struct FunctionLoopTests {
    @Test func hugeArgumentsReturnQuickly() {
        let start = Date()
        #expect(evalError("NETWORKDAYS(1,45000000000)") == .num)
        #expect(evalError("WORKDAY(TODAY(),1E12)") == .num)
        #expect(evalError("WORKDAY(TODAY(),-1E12)") == .num)
        #expect(evalNumber("NETWORKDAYS(1,2958465)") != nil)
        #expect(evalError("COMBIN(9E15,4.5E15)") == .num)
        #expect(evalError("COMBIN(2000,1000)") == .num)
        // IPMT/PPMT used to roll the balance forward once per period.
        #expect(evalNumber("IPMT(0.0000001,1E9,2E9,1000)") != nil)
        #expect(evalNumber("PPMT(0.0000001,1E9,2E9,1000)") != nil)
        #expect(evalFormula("IPMT(0.01,1E15,2E15,1000)") != .empty)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func combinValues() {
        #expect(evalNumber("COMBIN(5,2)") == 10)
        #expect(evalNumber("COMBIN(1000,2)") == 499500)
        #expect(evalNumber("COMBIN(50,25)") == 126410606437752)
        #expect(evalNumber("COMBIN(10,0)") == 1)
        #expect(evalNumber("COMBIN(10,10)") == 1)
        #expect(evalError("COMBIN(3,4)") == .num)
    }

    @Test func ipmtPpmtClosedFormMatchesAmortisation() {
        // Roll a 360-period loan forward and compare every period.
        for type in [0, 1] {
            let rate = 0.005, nper = 360.0, pv = 200_000.0
            let pmt = FinancialFunctions.pmt(rate: rate, nper: nper, pv: pv, fv: 0, type: Double(type))
            var balance = pv
            for period in 1...360 {
                let interest = (type == 1 && period == 1) ? 0 : -balance * rate
                let principal = pmt - interest
                balance += principal
                guard [1, 2, 3, 59, 180, 359, 360].contains(period) else { continue }
                let ipmt = evalNumber("IPMT(0.005,\(period),360,200000,0,\(type))")
                let ppmt = evalNumber("PPMT(0.005,\(period),360,200000,0,\(type))")
                #expect(approx(ipmt, interest, tolerance: 1e-9), "IPMT type \(type) period \(period)")
                #expect(approx(ppmt, principal, tolerance: 1e-9), "PPMT type \(type) period \(period)")
            }
        }
        // Zero rate: no interest at all.
        #expect(evalNumber("IPMT(0,3,10,1000)") == 0)
        #expect(approx(evalNumber("PPMT(0,3,10,1000)"), -100))
    }

    @Test func workdaysAgreeWithDayByDayCount() {
        // Reference implementations that step one day at a time.
        func isWeekday(_ s: Int) -> Bool { let m = (s + 5) % 7; return m < 5 }
        func networkdays(_ a: Int, _ b: Int, _ hol: Set<Int>) -> Int {
            let (lo, hi) = (min(a, b), max(a, b))
            let n = (lo...hi).filter { isWeekday($0) && !hol.contains($0) }.count
            return a <= b ? n : -n
        }
        func workday(_ s: Int, _ days: Int, _ hol: Set<Int>) -> Int {
            var cur = s, left = abs(days)
            let step = days >= 0 ? 1 : -1
            while left > 0 {
                cur += step
                if isWeekday(cur) && !hol.contains(cur) { left -= 1 }
            }
            return cur
        }
        let base = 45290 // late Dec 2023
        let holidays: [Int] = [45292, 45293, 45294, 45300, 45301, 45306, 45307, 45308, 45309, 45310, 45313]
        let h = Harness()
        for (i, d) in holidays.enumerated() { h.set("H\(i + 1)", String(d)) }
        let holidaySet = Set(holidays)
        for startOffset in 0..<9 {
            let s = base + startOffset
            for days in -16...16 {
                let expected = workday(s, days, holidaySet)
                #expect(h.eval("WORKDAY(\(s),\(days),H1:H11)") == .number(Double(expected)),
                        "WORKDAY(\(s),\(days))")
                #expect(h.eval("WORKDAY(\(s),\(days))") == .number(Double(workday(s, days, []))),
                        "WORKDAY(\(s),\(days)) no holidays")
            }
            for endOffset in -12...30 {
                let e = s + endOffset
                #expect(h.eval("NETWORKDAYS(\(s),\(e),H1:H11)") == .number(Double(networkdays(s, e, holidaySet))),
                        "NETWORKDAYS(\(s),\(e))")
            }
        }
        // Whole-year sanity: 2024 has 262 weekdays.
        #expect(evalNumber("NETWORKDAYS(DATE(2024,1,1),DATE(2024,12,31))") == 262)
    }
}
