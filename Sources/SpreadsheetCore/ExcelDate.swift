import Foundation

/// Conversions between spreadsheet date serial numbers and civil dates.
///
/// Serial numbers use the 1900 date system with the Google Sheets interpretation:
/// serial 0 == December 30, 1899, one serial unit per day, fraction == time of day.
/// This matches Excel exactly for every date from March 1, 1900 onward and avoids
/// Excel's fictitious February 29, 1900 (Lotus bug). Dates in Jan/Feb 1900 render
/// one day later than Excel would show them; Google Sheets makes the same choice.
public enum ExcelDate {
    /// Days between 1899-12-30 and 1970-01-01 (the civil-day epoch used internally).
    private static let serialEpochDays = -25569 // daysFromCivil(1899, 12, 30)

    /// Offset between the 1904 date system (legacy Mac Excel) and the 1900 system.
    public static let date1904Offset = 1462.0

    public struct Components: Equatable, Sendable {
        public var year: Int
        public var month: Int   // 1...12
        public var day: Int     // 1...31
        public var hour: Int    // 0...23
        public var minute: Int  // 0...59
        public var second: Double
        /// 1 = Sunday ... 7 = Saturday (Excel WEEKDAY type 1 convention).
        public var weekday: Int

        public init(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Double = 0, weekday: Int = 1) {
            self.year = year; self.month = month; self.day = day
            self.hour = hour; self.minute = minute; self.second = second
            self.weekday = weekday
        }
    }

    // Howard Hinnant's civil-date algorithms (proleptic Gregorian calendar).
    /// Days since 1970-01-01 for a civil date.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        var y = year
        if month <= 2 { y -= 1 }
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    /// Civil date for days since 1970-01-01.
    static func civilFromDays(_ z: Int) -> (year: Int, month: Int, day: Int) {
        let z = z + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    public static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeapYear(year) ? 29 : 28
        default: return 0
        }
    }

    /// Serial number for a (possibly out-of-range) date; month/day overflow is
    /// normalized the way DATE() does it: DATE(2020, 13, 1) == DATE(2021, 1, 1),
    /// DATE(2020, 1, 32) == DATE(2020, 2, 1), zero and negative roll backward.
    public static func serial(year: Int, month: Int, day: Int) -> Double {
        var y = year
        var m = month
        // Normalize month into 1...12, carrying into the year.
        y += (m - 1).quotientFlooring(12)
        m = (m - 1).remainderFlooring(12) + 1
        // Day overflow is handled implicitly by day arithmetic on the first of the month.
        let days = daysFromCivil(year: y, month: m, day: 1) + (day - 1)
        return Double(days - serialEpochDays)
    }

    public static func serial(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Double) -> Double {
        serial(year: year, month: month, day: day) + timeFraction(hour: hour, minute: minute, second: second)
    }

    /// Fraction of a day for a time; components may overflow (TIME(25,0,0) == 1 + 1h).
    public static func timeFraction(hour: Int, minute: Int, second: Double) -> Double {
        (Double(hour) * 3600 + Double(minute) * 60 + second) / 86400
    }

    /// Break a serial number into calendar components. Returns nil for non-finite input.
    public static func components(fromSerial serial: Double) -> Components? {
        guard serial.isFinite else { return nil }
        let wholeDays = Int(serial.rounded(.down))
        var frac = serial - Double(wholeDays)
        // Guard against floating point putting us a hair below the day boundary.
        var totalSeconds = (frac * 86400).rounded(toPlaces: 6)
        var dayAdjust = 0
        if totalSeconds >= 86400 { totalSeconds -= 86400; dayAdjust = 1 }
        let days = wholeDays + serialEpochDays + dayAdjust
        let (y, m, d) = civilFromDays(days)
        let hour = Int(totalSeconds) / 3600
        let minute = (Int(totalSeconds) % 3600) / 60
        let second = totalSeconds - Double(hour * 3600 + minute * 60)
        // 1899-12-31 (serial 1) was a Sunday; weekday cycles with period 7.
        // days since 1970-01-01: 1970-01-01 was a Thursday -> weekday index 4 (0=Sun).
        let weekdayIndex = (days % 7 + 7 + 4) % 7  // 0 = Sunday
        frac = 0 // silence unused warning path
        _ = frac
        return Components(year: y, month: m, day: d, hour: hour, minute: minute, second: second, weekday: weekdayIndex + 1)
    }

    /// Serial for the current date in the local time zone (midnight).
    public static func todaySerial(calendar: Calendar = .current, date: Date = Date()) -> Double {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return serial(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// Serial for the current date+time in the local time zone.
    public static func nowSerial(calendar: Calendar = .current, date: Date = Date()) -> Double {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let seconds = Double(c.second ?? 0) + Double(c.nanosecond ?? 0) / 1e9
        return serial(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1,
                      hour: c.hour ?? 0, minute: c.minute ?? 0, second: seconds)
    }
}

extension Int {
    /// Floored division quotient (rounds toward negative infinity).
    func quotientFlooring(_ divisor: Int) -> Int {
        let q = self / divisor
        return (self % divisor != 0 && (self < 0) != (divisor < 0)) ? q - 1 : q
    }

    /// Floored remainder (always in 0..<divisor for positive divisor).
    func remainderFlooring(_ divisor: Int) -> Int {
        let r = self % divisor
        return (r != 0 && (r < 0) != (divisor < 0)) ? r + divisor : r
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
