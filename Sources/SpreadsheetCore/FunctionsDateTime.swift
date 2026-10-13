import Foundation

enum DateTimeFunctions {
    // Split into sub-arrays: one huge literal exceeds older compilers'
    // type-checking budget (CI runners lag the local toolchain).
    static let all: [BuiltinFunction] = construction + components + dateArithmetic + workdays

    private static let construction: [BuiltinFunction] = [
        .eager("DATE", min: 3, max: 3) { args, _ in
            var year = try intArg(args[0])
            let month = try intArg(args[1])
            let day = try intArg(args[2])
            guard year >= 0, year <= 9999 else { throw CellError.num }
            if year < 1900 { year += 1900 }
            let serial = ExcelDate.serial(year: year, month: month, day: day)
            guard serial >= 0, serial <= ExcelDate.maxSerial else { throw CellError.num }
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
    ]

    private static let components: [BuiltinFunction] = [
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
            .number(try timeOfDay(args[0]).hour)
        },
        .eager("MINUTE", min: 1, max: 1) { args, _ in
            .number(try timeOfDay(args[0]).minute)
        },
        .eager("SECOND", min: 1, max: 1) { args, _ in
            .number(try timeOfDay(args[0]).second)
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
            return .number(try weekNumber(serial: serial, type: type))
        },
        .eager("ISOWEEKNUM", min: 1, max: 1) { args, _ in
            let serial = try serialArg(args[0])
            return .number(try weekNumber(serial: serial, type: 21))
        },
    ]

    private static let dateArithmetic: [BuiltinFunction] = [
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
            let start = try Double(dayArg(args[0]))
            let end = try Double(dayArg(args[1]))
            let unit = try strArg(args[2]).uppercased()
            return .number(try datedifValue(start: start, end: end, unit: unit))
        },
        .eager("DAYS", min: 2, max: 2) { args, _ in
            let end = try dayArg(args[0])
            let start = try dayArg(args[1])
            return .number(Double(end - start))
        },
    ]

    private static let workdays: [BuiltinFunction] = [
        .eager("NETWORKDAYS", min: 2, max: 3) { args, _ in
            let start = try dayArg(args[0])
            let end = try dayArg(args[1])
            let holidays = try holidayList(args, 2)
            let (lo, hi) = (min(start, end), max(start, end))
            let count = weekdays(from: lo, through: hi) - holidays.count(in: lo...hi)
            return .number(Double(start <= end ? count : -count))
        },
        .eager("WORKDAY", min: 2, max: 3) { args, _ in
            let start = try dayArg(args[0])
            let days = try intArg(args[1])
            let holidays = try holidayList(args, 2)
            let result = workday(from: start, adding: days, holidays: holidays)
            guard let result, ExcelDate.isValidSerial(Double(result)) else { throw CellError.num }
            return .number(Double(result))
        },
        .eager("YEARFRAC", min: 2, max: 3) { args, _ in
            let start = try Double(dayArg(args[0]))
            let end = try Double(dayArg(args[1]))
            let basis = try optionalInt(args, 2, default: 0)
            return .number(try yearfracValue(start: start, end: end, basis: basis))
        },
    ]

    // MARK: Helpers

    /// DATEDIF body (kept out of the closure: large inline bodies blow older
    /// compilers' expression type-checking budget).
    static func datedifValue(start: Double, end: Double, unit: String) throws -> Double {
        guard start <= end else { throw CellError.num }
        guard let s = ExcelDate.components(fromSerial: start),
              let e = ExcelDate.components(fromSerial: end) else { throw CellError.num }
        switch unit {
        case "D":
            return end - start
        case "M":
            return Double(wholeMonthsBetween(s, e))
        case "Y":
            return Double(wholeMonthsBetween(s, e) / 12)
        case "YM":
            return Double(wholeMonthsBetween(s, e) % 12)
        case "MD":
            // days ignoring months and years
            if e.day >= s.day {
                return Double(e.day - s.day)
            }
            // borrow from previous month of the end date
            let prevMonth = e.month == 1 ? 12 : e.month - 1
            let prevYear = e.month == 1 ? e.year - 1 : e.year
            let dim = ExcelDate.daysInMonth(year: prevYear, month: prevMonth)
            return Double(e.day + max(0, dim - s.day))
        case "YD":
            // days ignoring years: move start's month/day into end's year frame
            var anchor = ExcelDate.serial(year: s.year, month: e.month, day: e.day)
            let startSerial = ExcelDate.serial(year: s.year, month: s.month, day: s.day)
            if anchor < startSerial {
                anchor = ExcelDate.serial(year: s.year + 1, month: e.month, day: e.day)
            }
            return anchor - startSerial
        default:
            throw CellError.num
        }
    }

    /// YEARFRAC body (see datedifValue note).
    static func yearfracValue(start: Double, end: Double, basis: Int) throws -> Double {
        let lo = min(start, end)
        let hi = max(start, end)
        guard let s = ExcelDate.components(fromSerial: lo),
              let e = ExcelDate.components(fromSerial: hi) else { throw CellError.num }
        switch basis {
        case 0: // US (NASD) 30/360, as Excel applies it
            var d1 = s.day
            var d2 = e.day
            let startIsEndOfFeb = s.month == 2 && s.day == ExcelDate.daysInMonth(year: s.year, month: 2)
            let endIsEndOfFeb = e.month == 2 && e.day == ExcelDate.daysInMonth(year: e.year, month: 2)
            if startIsEndOfFeb && endIsEndOfFeb { d2 = 30 }
            if d1 == 31 || startIsEndOfFeb { d1 = 30 }
            // Only a start that was really the 30th or 31st pulls a 31st end
            // to the 30th: Feb 28 → Mar 31 is 31/360 in Excel (checked in
            // Excel for the web), not 30/360.
            if s.day >= 30 && d2 == 31 { d2 = 30 }
            let days = Double((e.year - s.year) * 360 + (e.month - s.month) * 30 + (d2 - d1))
            return days / 360
        case 1: // actual/actual
            let days = hi - lo
            if days == 0 { return 0 }
            // Excel: a span of at most a year divides by that year's length
            // (366 when it takes in a February 29); a longer span divides by
            // the average length of the calendar years it touches.
            let withinAYear = s.year == e.year
                || (e.year == s.year + 1 && (s.month > e.month || (s.month == e.month && s.day >= e.day)))
            if withinAYear {
                func feb29(_ year: Int) -> Double? {
                    ExcelDate.isLeapYear(year) ? ExcelDate.serial(year: year, month: 2, day: 29) : nil
                }
                let includesFeb29 = [s.year, e.year].contains { year in
                    feb29(year).map { $0 >= lo && $0 <= hi } ?? false
                }
                let leapYearSpan = s.year == e.year && ExcelDate.isLeapYear(s.year)
                return days / (includesFeb29 || leapYearSpan ? 366 : 365)
            }
            let first = ExcelDate.serial(year: s.year, month: 1, day: 1)
            let afterLast = ExcelDate.serial(year: e.year + 1, month: 1, day: 1)
            let average = (afterLast - first) / Double(e.year - s.year + 1)
            return days / average
        case 2:
            return (hi - lo) / 360
        case 3:
            return (hi - lo) / 365
        case 4: // European 30E/360
            let d1 = min(s.day, 30)
            let d2 = min(e.day, 30)
            let days = Double((e.year - s.year) * 360 + (e.month - s.month) * 30 + (d2 - d1))
            return days / 360
        default:
            throw CellError.num
        }
    }

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
        guard let comps = ExcelDate.components(fromSerial: serial) else {
            throw CellError.num
        }
        return comps
    }

    /// A whole day number from a date argument; #NUM! outside the valid
    /// date range (0 ... 2958465).
    static func dayArg(_ v: EvalValue) throws -> Int {
        let serial = try serialArg(v)
        guard ExcelDate.isValidSerial(serial), let day = checkedInt(serial) else { throw CellError.num }
        return day
    }

    /// HOUR/MINUTE/SECOND: Excel rounds the time to the nearest second before
    /// splitting it, so 12:00:59.6 is 12:01:00 (never second 60).
    static func timeOfDay(_ v: EvalValue) throws -> (hour: Double, minute: Double, second: Double) {
        let serial = try serialArg(v)
        guard ExcelDate.isValidSerial(serial) else { throw CellError.num }
        let total = (serial * 86400).rounded()
        let secondOfDay = total - (total / 86400).rounded(.down) * 86400
        let hour = (secondOfDay / 3600).rounded(.down)
        let minute = ((secondOfDay - hour * 3600) / 60).rounded(.down)
        return (hour, minute, secondOfDay - hour * 3600 - minute * 60)
    }

    /// Monday = 0 ... Sunday = 6. Serial 2 (1900-01-01) is a Monday.
    static func mondayIndex(_ day: Int) -> Int {
        ((day + 5) % 7 + 7) % 7
    }

    static func isWeekday(serial: Int) -> Bool {
        mondayIndex(serial) < 5
    }

    /// Monday-to-Friday days in lo...hi, in constant time.
    static func weekdays(from lo: Int, through hi: Int) -> Int {
        guard hi >= lo else { return 0 }
        let span = hi - lo + 1
        var count = (span / 7) * 5
        let first = mondayIndex(lo)
        for i in 0..<(span % 7) where (first + i) % 7 < 5 {
            count += 1
        }
        return count
    }

    /// `days` workdays on from `start` (back when negative), ignoring
    /// holidays; nil on integer overflow.
    static func addWeekdays(to start: Int, _ days: Int) -> Int? {
        if days == 0 { return start }
        let index = mondayIndex(start)
        let (weeks, rest) = (abs(days) / 5, abs(days) % 5)
        let (weekSpan, overflow) = weeks.multipliedReportingOverflow(by: 7)
        guard !overflow else { return nil }
        if days > 0 {
            // A weekend start counts from its Friday.
            let friday = index > 4 ? start - (index - 4) : start
            let base = min(index, 4)
            var result = friday + weekSpan + rest
            if base + rest > 4 { result += 2 }
            return result
        } else {
            // A weekend start counts back from its Monday.
            let monday = index > 4 ? start + (7 - index) : start
            let base = index > 4 ? 0 : index
            var result = monday - weekSpan - rest
            if base - rest < 0 { result -= 2 }
            return result
        }
    }

    /// WORKDAY: jump over the weekends in closed form, then keep stepping by
    /// the number of holidays the jump passed over (at most one round per
    /// holiday). Excel returns the start date unchanged for 0 days.
    static func workday(from start: Int, adding days: Int, holidays: HolidayList) -> Int? {
        guard days != 0 else { return start }
        let forward = days > 0
        var current = start
        var remaining = abs(days)
        while remaining > 0 {
            guard let target = addWeekdays(to: current, forward ? remaining : -remaining) else { return nil }
            remaining = forward ? holidays.count(in: (current + 1)...target)
                                : holidays.count(in: target...(current - 1))
            current = target
        }
        return current
    }

    /// Distinct weekday holidays, sorted, for range counting.
    struct HolidayList {
        let days: [Int]

        func count(in range: ClosedRange<Int>) -> Int {
            lowerBound(range.upperBound + 1) - lowerBound(range.lowerBound)
        }

        /// Index of the first holiday >= value.
        private func lowerBound(_ value: Int) -> Int {
            var lo = 0, hi = days.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if days[mid] < value { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
    }

    static func holidayList(_ args: [EvalValue], _ index: Int) throws -> HolidayList {
        guard index < args.count else { return HolidayList(days: []) }
        var holidays = Set<Int>()
        func add(_ serial: Double) throws {
            guard ExcelDate.isValidSerial(serial), let day = checkedInt(serial) else { throw CellError.num }
            if isWeekday(serial: day) { holidays.insert(day) }
        }
        try GridArg(args[index]).forEach { v in
            switch v {
            case .number(let n): try add(n)
            case .string(let s):
                if let serial = ValueParser.parseDateText(s) { try add(serial) }
            case .error(let e): throw e
            default: break
            }
        }
        return HolidayList(days: holidays.sorted())
    }

    static func wholeMonthsBetween(_ s: ExcelDate.Components, _ e: ExcelDate.Components) -> Int {
        var months = (e.year - s.year) * 12 + (e.month - s.month)
        if e.day < s.day { months -= 1 }
        return max(0, months)
    }

    static func shiftMonthsClamped(serial: Double, months: Int, toMonthEnd: Bool) throws -> Double {
        guard let comps = ExcelDate.components(fromSerial: serial.rounded(.down)) else {
            throw CellError.num
        }
        var year = comps.year
        var month = comps.month + months
        year += (month - 1).quotientFlooring(12)
        month = (month - 1).remainderFlooring(12) + 1
        let dim = ExcelDate.daysInMonth(year: year, month: month)
        let day = toMonthEnd ? dim : min(comps.day, dim)
        let result = ExcelDate.serial(year: year, month: month, day: day)
        guard ExcelDate.isValidSerial(result) else { throw CellError.num }
        return result
    }

    static func weekNumber(serial: Double, type: Int) throws -> Double {
        guard let comps = ExcelDate.components(fromSerial: serial.rounded(.down)) else {
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
            // Weekday of Jan 1 (1 = Sunday; serial 1 was a Sunday). Plain
            // arithmetic: Jan 1, 1900 sits before serial 0's date range.
            guard let jan1Day = checkedInt(jan1) else { throw CellError.num }
            let jan1Weekday = ((jan1Day + 6) % 7 + 7) % 7 + 1
            // Days from the week start preceding (or equal to) Jan 1.
            let offset = (jan1Weekday - weekStart + 7) % 7
            return ((day - jan1 + Double(offset)) / 7).rounded(.down) + 1
        case 21:
            // ISO 8601: week containing the first Thursday; weeks start Monday.
            let isoWeekday = comps.weekday == 1 ? 7 : comps.weekday - 1 // 1=Mon...7=Sun
            let thursday = day + Double(4 - isoWeekday)
            guard let thuComps = ExcelDate.components(fromSerial: thursday) else { throw CellError.num }
            let jan1 = ExcelDate.serial(year: thuComps.year, month: 1, day: 1)
            return ((thursday - jan1) / 7).rounded(.down) + 1
        default:
            throw CellError.num
        }
    }
}
