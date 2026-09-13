import Foundation

enum DateTimeFunctions {
    static let all: [BuiltinFunction] = [
        .eager("DATE", min: 3, max: 3) { args, _ in
            var year = try intArg(args[0])
            let month = try intArg(args[1])
            let day = try intArg(args[2])
            guard year >= 0, year <= 9999 else { throw CellError.num }
            if year < 1900 { year += 1900 }
            let serial = ExcelDate.serial(year: year, month: month, day: day)
            guard serial >= 0 else { throw CellError.num }
            return .number(serial)
        },
        .eager("TIME", min: 3, max: 3) { args, _ in
            let h = try intArg(args[0])
            let m = try intArg(args[1])
            let s = try intArg(args[2])
            let frac = ExcelDate.timeFraction(hour: h, minute: m, second: Double(s))
            guard frac >= 0 else { throw CellError.num }
            return .number(frac.truncatingRemainder(dividingBy: 1))
        },
        .eager("DATEVALUE", min: 1, max: 1) { args, _ in
            let s = try strArg(args[0])
            guard let serial = ValueParser.parseDateText(s) else { throw CellError.value }
            return .number(serial.rounded(.down))
        },
        .eager("TIMEVALUE", min: 1, max: 1) { args, _ in
            let s = try strArg(args[0])
            guard let frac = ValueParser.parseTimeText(s) else { throw CellError.value }
            return .number(frac.truncatingRemainder(dividingBy: 1))
        },
        .eager("TODAY", min: 0, max: 0) { _, ctx in
            .number(ctx.eval.clock.todaySerial())
        },
        .eager("NOW", min: 0, max: 0) { _, ctx in
            .number(ctx.eval.clock.nowSerial())
        },
        .eager("YEAR", min: 1, max: 1) { args, _ in
            .number(Double(try dateComponents(args[0]).year))
        },
        .eager("MONTH", min: 1, max: 1) { args, _ in
            .number(Double(try dateComponents(args[0]).month))
        },
        .eager("DAY", min: 1, max: 1) { args, _ in
            .number(Double(try dateComponents(args[0]).day))
        },
        .eager("HOUR", min: 1, max: 1) { args, _ in
            .number(Double(try dateComponents(args[0]).hour))
        },
        .eager("MINUTE", min: 1, max: 1) { args, _ in
            .number(Double(try dateComponents(args[0]).minute))
        },
        .eager("SECOND", min: 1, max: 1) { args, _ in
            .number(Double(Int(try dateComponents(args[0]).second.rounded())))
        },
        .eager("WEEKDAY", min: 1, max: 2) { args, _ in
            let comps = try dateComponents(args[0])
            let type = try optionalInt(args, 1, default: 1)
            let sundayBased = comps.weekday // 1=Sun ... 7=Sat
            switch type {
            case 1: return .number(Double(sundayBased))
            case 2: return .number(Double(sundayBased == 1 ? 7 : sundayBased - 1))
            case 3: return .number(Double(sundayBased == 1 ? 6 : sundayBased - 2))
            default: throw CellError.num
            }
        },
        .eager("WEEKNUM", min: 1, max: 2) { args, _ in
            let serial = try serialArg(args[0])
            let type = try optionalInt(args, 1, default: 1)
            return .number(Double(try weekNumber(serial: serial, type: type)))
        },
        .eager("ISOWEEKNUM", min: 1, max: 1) { args, _ in
            let serial = try serialArg(args[0])
            return .number(Double(try weekNumber(serial: serial, type: 21)))
        },
        .eager("EDATE", min: 2, max: 2) { args, _ in
            let serial = try serialArg(args[0])
            let months = try intArg(args[1])
            return .number(try shiftMonthsClamped(serial: serial, months: months, toMonthEnd: false))
        },
        .eager("EOMONTH", min: 2, max: 2) { args, _ in
            let serial = try serialArg(args[0])
            let months = try intArg(args[1])
            return .number(try shiftMonthsClamped(serial: serial, months: months, toMonthEnd: true))
        },
        .eager("DATEDIF", min: 3, max: 3) { args, _ in
            let start = try serialArg(args[0]).rounded(.down)
            let end = try serialArg(args[1]).rounded(.down)
            let unit = try strArg(args[2]).uppercased()
            guard start <= end else { throw CellError.num }
            guard let s = ExcelDate.components(fromSerial: start),
                  let e = ExcelDate.components(fromSerial: end) else { throw CellError.num }
            switch unit {
            case "D":
                return .number(end - start)
            case "M":
                return .number(Double(wholeMonthsBetween(s, e)))
            case "Y":
                return .number(Double(wholeMonthsBetween(s, e) / 12))
            case "YM":
                return .number(Double(wholeMonthsBetween(s, e) % 12))
            case "MD":
                // days ignoring months and years
                if e.day >= s.day {
                    return .number(Double(e.day - s.day))
                }
                // borrow from previous month of the end date
                let prevMonth = e.month == 1 ? 12 : e.month - 1
                let prevYear = e.month == 1 ? e.year - 1 : e.year
                let dim = ExcelDate.daysInMonth(year: prevYear, month: prevMonth)
                return .number(Double(e.day + max(0, dim - s.day)))
            case "YD":
                // days ignoring years: move start's month/day into end's year frame
                var anchor = ExcelDate.serial(year: s.year, month: e.month, day: e.day)
                let startSerial = ExcelDate.serial(year: s.year, month: s.month, day: s.day)
                if anchor < startSerial {
                    anchor = ExcelDate.serial(year: s.year + 1, month: e.month, day: e.day)
                }
                return .number(anchor - startSerial)
            default:
                throw CellError.num
            }
        },
        .eager("DAYS", min: 2, max: 2) { args, _ in
            let end = try serialArg(args[0])
            let start = try serialArg(args[1])
            return .number(end.rounded(.down) - start.rounded(.down))
        },
        .eager("NETWORKDAYS", min: 2, max: 3) { args, _ in
            let start = Int(try serialArg(args[0]).rounded(.down))
            let end = Int(try serialArg(args[1]).rounded(.down))
            let holidays = try holidaySet(args, 2)
            let (lo, hi) = (min(start, end), max(start, end))
            var count = 0
            for day in lo...hi where isWeekday(serial: day) && !holidays.contains(day) {
                count += 1
            }
            return .number(Double(start <= end ? count : -count))
        },
        .eager("WORKDAY", min: 2, max: 3) { args, _ in
            var current = Int(try serialArg(args[0]).rounded(.down))
            var remaining = try intArg(args[1])
            let holidays = try holidaySet(args, 2)
            let step = remaining >= 0 ? 1 : -1
            remaining = abs(remaining)
            while remaining > 0 {
                current += step
                if isWeekday(serial: current) && !holidays.contains(current) {
                    remaining -= 1
                }
            }
            return .number(Double(current))
        },
        .eager("YEARFRAC", min: 2, max: 3) { args, _ in
            let start = try serialArg(args[0]).rounded(.down)
            let end = try serialArg(args[1]).rounded(.down)
            let basis = try optionalInt(args, 2, default: 0)
            let (lo, hi) = start <= end ? (start, end) : (end, start)
            guard let s = ExcelDate.components(fromSerial: lo),
                  let e = ExcelDate.components(fromSerial: hi) else { throw CellError.num }
            switch basis {
            case 0: // US (NASD) 30/360
                var d1 = s.day, d2 = e.day
                if d1 == 31 { d1 = 30 }
                if d2 == 31 && d1 == 30 { d2 = 30 }
                let days = Double((e.year - s.year) * 360 + (e.month - s.month) * 30 + (d2 - d1))
                return .number(days / 360)
            case 1: // actual/actual
                let days = hi - lo
                let yearLength = averageYearLength(from: s.year, to: e.year)
                return .number(days / yearLength)
            case 2:
                return .number((hi - lo) / 360)
            case 3:
                return .number((hi - lo) / 365)
            case 4: // European 30E/360
                let d1 = min(s.day, 30), d2 = min(e.day, 30)
                let days = Double((e.year - s.year) * 360 + (e.month - s.month) * 30 + (d2 - d1))
                return .number(days / 360)
            default:
                throw CellError.num
            }
        },
    ]

    // MARK: Helpers

    /// A date serial from a numeric or date-string argument.
    static func serialArg(_ v: EvalValue) throws -> Double {
        let scalar = try v.toScalar()
        switch scalar {
        case .number(let n): return n
        case .string(let s):
            if let serial = ValueParser.parseDateText(s) { return serial }
            if let n = Coerce.parseNumericText(s) { return n }
            throw CellError.value
        case .bool(let b): return b ? 1 : 0
        case .empty: return 0
        case .error(let e): throw e
        }
    }

    static func dateComponents(_ v: EvalValue) throws -> ExcelDate.Components {
        let serial = try serialArg(v)
        guard serial >= 0, let comps = ExcelDate.components(fromSerial: serial) else {
            throw CellError.num
        }
        return comps
    }

    static func isWeekday(serial: Int) -> Bool {
        guard let comps = ExcelDate.components(fromSerial: Double(serial)) else { return false }
        return comps.weekday >= 2 && comps.weekday <= 6
    }

    static func holidaySet(_ args: [EvalValue], _ index: Int) throws -> Set<Int> {
        guard index < args.count else { return [] }
        var holidays = Set<Int>()
        try GridArg(args[index]).forEach { v in
            switch v {
            case .number(let n): holidays.insert(Int(n.rounded(.down)))
            case .string(let s):
                if let serial = ValueParser.parseDateText(s) {
                    holidays.insert(Int(serial.rounded(.down)))
                }
            case .error(let e): throw e
            default: break
            }
        }
        return holidays
    }

    static func wholeMonthsBetween(_ s: ExcelDate.Components, _ e: ExcelDate.Components) -> Int {
        var months = (e.year - s.year) * 12 + (e.month - s.month)
        if e.day < s.day { months -= 1 }
        return max(0, months)
    }

    static func shiftMonthsClamped(serial: Double, months: Int, toMonthEnd: Bool) throws -> Double {
        guard serial >= 0, let comps = ExcelDate.components(fromSerial: serial.rounded(.down)) else {
            throw CellError.num
        }
        var year = comps.year
        var month = comps.month + months
        year += (month - 1).quotientFlooring(12)
        month = (month - 1).remainderFlooring(12) + 1
        let dim = ExcelDate.daysInMonth(year: year, month: month)
        let day = toMonthEnd ? dim : min(comps.day, dim)
        let result = ExcelDate.serial(year: year, month: month, day: day)
        guard result >= 0 else { throw CellError.num }
        return result
    }

    static func weekNumber(serial: Double, type: Int) throws -> Int {
        guard serial >= 0, let comps = ExcelDate.components(fromSerial: serial.rounded(.down)) else {
            throw CellError.num
        }
        let day = serial.rounded(.down)
        switch type {
        case 1, 2, 11, 12, 13, 14, 15, 16, 17:
            // Week 1 contains Jan 1; weeks start on a fixed day.
            // type 1 -> Sunday, 2/11 -> Monday, 12..17 -> Tue..Sun.
            let weekStart: Int // 1=Sun ... 7=Sat convention
            switch type {
            case 1, 17: weekStart = 1
            case 2, 11: weekStart = 2
            case 12: weekStart = 3
            case 13: weekStart = 4
            case 14: weekStart = 5
            case 15: weekStart = 6
            case 16: weekStart = 7
            default: weekStart = 1
            }
            let jan1 = ExcelDate.serial(year: comps.year, month: 1, day: 1)
            guard let jan1Comps = ExcelDate.components(fromSerial: jan1) else { throw CellError.num }
            // Days from the week start preceding (or equal to) Jan 1.
            let offset = (jan1Comps.weekday - weekStart + 7) % 7
            return Int((day - jan1 + Double(offset)) / 7) + 1
        case 21:
            // ISO 8601: week containing the first Thursday; weeks start Monday.
            let weekday = ((Int(day) % 7) + 7 + 5) % 7 // 0 = Monday for our epoch? compute via comps
            _ = weekday
            let isoWeekday = comps.weekday == 1 ? 7 : comps.weekday - 1 // 1=Mon...7=Sun
            let thursday = day + Double(4 - isoWeekday)
            guard let thuComps = ExcelDate.components(fromSerial: thursday) else { throw CellError.num }
            let jan1 = ExcelDate.serial(year: thuComps.year, month: 1, day: 1)
            return Int((thursday - jan1) / 7) + 1
        default:
            throw CellError.num
        }
    }

    static func averageYearLength(from startYear: Int, to endYear: Int) -> Double {
        var total = 0.0
        var count = 0
        for y in startYear...max(startYear, endYear) {
            total += ExcelDate.isLeapYear(y) ? 366 : 365
            count += 1
        }
        return total / Double(count)
    }
}
