import Testing
@testable import SpreadsheetCore

@Suite("Excel date serials")
struct ExcelDateTests {
    @Test func knownSerials() {
        // Epoch: serial 0 == 1899-12-30 (Sheets convention).
        #expect(ExcelDate.serial(year: 1899, month: 12, day: 30) == 0)
        // From March 1900 onward we match Excel exactly.
        #expect(ExcelDate.serial(year: 1900, month: 3, day: 1) == 61)
        #expect(ExcelDate.serial(year: 2000, month: 1, day: 1) == 36526)
        #expect(ExcelDate.serial(year: 2026, month: 9, day: 13) == 46278)
        #expect(ExcelDate.serial(year: 9999, month: 12, day: 31) == 2958465)
    }

    @Test func componentsRoundTrip() {
        for (y, m, d) in [(1900, 3, 1), (1999, 12, 31), (2000, 2, 29), (2024, 2, 29),
                          (2026, 9, 13), (2100, 3, 1), (9999, 12, 31)] {
            let serial = ExcelDate.serial(year: y, month: m, day: d)
            let comps = ExcelDate.components(fromSerial: serial)
            #expect(comps?.year == y)
            #expect(comps?.month == m)
            #expect(comps?.day == d)
        }
    }

    @Test func timeFractions() {
        let noon = ExcelDate.serial(year: 2026, month: 1, day: 1, hour: 12, minute: 0, second: 0)
        let comps = ExcelDate.components(fromSerial: noon)
        #expect(comps?.hour == 12)
        #expect(comps?.minute == 0)

        let t = ExcelDate.serial(year: 2026, month: 1, day: 1, hour: 23, minute: 59, second: 59)
        let c2 = ExcelDate.components(fromSerial: t)
        #expect(c2?.hour == 23)
        #expect(c2?.minute == 59)
        #expect(c2?.second == 59)
        #expect(c2?.day == 1)
    }

    @Test func monthOverflowNormalization() {
        #expect(ExcelDate.serial(year: 2020, month: 13, day: 1) ==
                ExcelDate.serial(year: 2021, month: 1, day: 1))
        #expect(ExcelDate.serial(year: 2020, month: 0, day: 1) ==
                ExcelDate.serial(year: 2019, month: 12, day: 1))
        #expect(ExcelDate.serial(year: 2020, month: 1, day: 0) ==
                ExcelDate.serial(year: 2019, month: 12, day: 31))
        #expect(ExcelDate.serial(year: 2020, month: 2, day: 30) ==
                ExcelDate.serial(year: 2020, month: 3, day: 1))
        #expect(ExcelDate.serial(year: 2020, month: -1, day: 15) ==
                ExcelDate.serial(year: 2019, month: 11, day: 15))
    }

    @Test func leapYears() {
        #expect(ExcelDate.isLeapYear(2000))
        #expect(ExcelDate.isLeapYear(2024))
        #expect(!ExcelDate.isLeapYear(1900))
        #expect(!ExcelDate.isLeapYear(2100))
        #expect(ExcelDate.daysInMonth(year: 2024, month: 2) == 29)
        #expect(ExcelDate.daysInMonth(year: 2023, month: 2) == 28)
    }

    @Test func weekdays() {
        // 2026-09-13 is a Sunday.
        let sunday = ExcelDate.components(fromSerial: ExcelDate.serial(year: 2026, month: 9, day: 13))
        #expect(sunday?.weekday == 1)
        // 2024-01-01 is a Monday.
        let monday = ExcelDate.components(fromSerial: ExcelDate.serial(year: 2024, month: 1, day: 1))
        #expect(monday?.weekday == 2)
        // 1970-01-01 is a Thursday.
        let thursday = ExcelDate.components(fromSerial: ExcelDate.serial(year: 1970, month: 1, day: 1))
        #expect(thursday?.weekday == 5)
    }

    @Test func fractionalDayBoundary() {
        // A fraction a hair below a whole day must not roll the date backwards.
        let serial = 45000.9999999
        let comps = ExcelDate.components(fromSerial: serial)
        #expect(comps != nil)
        let base = ExcelDate.components(fromSerial: 45000)!
        // Either stays on the same date near midnight or rolls cleanly to next.
        #expect(comps!.day == base.day || comps!.day == base.day + 1)
    }
}
