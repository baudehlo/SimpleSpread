import Testing
@testable import SpreadsheetCore

/// Code review finding #24 (rounding), the SECOND() half of #22, and the
/// YEARFRAC note in the review appendix.
@Suite("Rounding: Excel parity")
struct RoundingExcelTests {
    @Test func roundOnFifteenSignificantDigits() {
        #expect(evalNumber("ROUND(1.005,2)") == 1.01)
        #expect(evalNumber("ROUND(-1.005,2)") == -1.01)
        #expect(evalNumber("ROUND(2.675,2)") == 2.68)
        #expect(evalNumber("ROUND(1.0049999,2)") == 1)
        #expect(evalNumber("ROUND(0.285,2)") == 0.29)
        #expect(evalNumber("ROUND(2.5,0)") == 3)
        #expect(evalNumber("ROUND(-2.5,0)") == -3)
        #expect(evalNumber("ROUND(1234.5678,-2)") == 1200)
        #expect(evalNumber("ROUND(1250,-2)") == 1300)
        #expect(evalNumber("ROUND(0.1+0.2,15)") == 0.3)
        #expect(evalNumber("ROUND(1E300,-299)") == 1e300)
        #expect(evalNumber("ROUND(123,400)") == 123)
        #expect(evalNumber("ROUND(123,-400)") == 0)
        #expect(evalNumber("ROUND(0,2)") == 0)
    }

    @Test func roundUpAndDownUseARelativeTolerance() {
        #expect(evalNumber("ROUNDUP(1.0000000001,0)") == 2)
        #expect(evalNumber("ROUNDUP(-1.0000000001,0)") == -2)
        #expect(evalNumber("ROUNDDOWN(1.9999999999,0)") == 1)
        // Float fuzz below 15 digits is still forgiven.
        #expect(evalNumber("ROUNDUP(0.1+0.2,1)") == 0.3)
        #expect(evalNumber("ROUNDDOWN(0.3-0.1,1)") == 0.2)
        #expect(evalNumber("ROUNDUP(3.14159,3)") == 3.142)
        #expect(evalNumber("ROUNDDOWN(-3.14159,2)") == -3.14)
        #expect(evalNumber("TRUNC(8.9)") == 8)
        #expect(evalNumber("TRUNC(-8.9)") == -8)
        #expect(evalNumber("TRUNC(0.3-0.1,1)") == 0.2)
        #expect(evalNumber("ROUNDUP(31415.92654,-2)") == 31500)
        // CEILING/FLOOR/EVEN/ODD share the fuzz rule.
        #expect(evalNumber("CEILING(1.0000000001,1)") == 2)
        #expect(evalNumber("CEILING(0.3/0.1,1)") == 3)
        #expect(evalNumber("FLOOR(0.7/0.1,1)") == 7)
        #expect(evalNumber("EVEN(2.0000000001)") == 4)
        #expect(evalNumber("MROUND(0.15,0.1)") == 0.2)
    }
}

@Suite("Date and time: Excel parity")
struct DateTimeExcelTests {
    @Test func timePartsRoundToTheNearestSecond() {
        // 12:00:59.6 is 12:01:00 to Excel's HOUR/MINUTE/SECOND.
        let cells = ["A1": "=TIME(12,0,59)+0.6/86400", "A2": "=TIME(23,59,59)+0.7/86400"]
        #expect(evalNumber("SECOND(A1)", cells: cells) == 0)
        #expect(evalNumber("MINUTE(A1)", cells: cells) == 1)
        #expect(evalNumber("HOUR(A1)", cells: cells) == 12)
        #expect(evalNumber("SECOND(A2)", cells: cells) == 0)
        #expect(evalNumber("MINUTE(A2)", cells: cells) == 0)
        #expect(evalNumber("HOUR(A2)", cells: cells) == 0)
        // Never 60, for any fraction of a second.
        for tenth in 0..<10 {
            let v = evalNumber("SECOND(TIME(1,2,3)+\(tenth)/864000)")
            #expect(v != nil && v! < 60)
        }
    }

    @Test func yearfracBasis0FollowsNASD() {
        // Last day of February counts as the 30th, and then 31 -> 30.
        #expect(approx(evalNumber("YEARFRAC(DATE(2023,2,28),DATE(2023,3,31),0)"), 30.0 / 360))
        #expect(approx(evalNumber("YEARFRAC(DATE(2024,2,29),DATE(2024,3,31),0)"), 30.0 / 360))
        // Both on the last day of February.
        #expect(approx(evalNumber("YEARFRAC(DATE(2023,2,28),DATE(2024,2,29),0)"), 1))
        // Start before the 30th: a 31st end stays 31.
        #expect(approx(evalNumber("YEARFRAC(DATE(2023,1,15),DATE(2023,3,31),0)"), 76.0 / 360))
        #expect(approx(evalNumber("YEARFRAC(DATE(2023,1,31),DATE(2023,3,31),0)"), 60.0 / 360))
        #expect(approx(evalNumber("YEARFRAC(DATE(2023,3,31),DATE(2023,1,31),0)"), 60.0 / 360))
        // Feb 28 in a leap year is not the end of February.
        #expect(approx(evalNumber("YEARFRAC(DATE(2024,2,28),DATE(2024,3,31),0)"), 33.0 / 360))
    }

    @Test func yearfracBasis1() {
        // Within one year that contains Feb 29: 366-day year.
        #expect(approx(evalNumber("YEARFRAC(DATE(2023,7,1),DATE(2024,3,1),1)"), 244.0 / 366))
        // Within one year, no Feb 29.
        #expect(approx(evalNumber("YEARFRAC(DATE(2023,1,1),DATE(2023,7,1),1)"), 181.0 / 365))
        #expect(approx(evalNumber("YEARFRAC(DATE(2024,1,1),DATE(2024,7,1),1)"), 182.0 / 366))
        // Longer: average year length over the years touched.
        #expect(approx(evalNumber("YEARFRAC(DATE(2023,1,1),DATE(2025,1,2),1)"), 732.0 / (1096.0 / 3)))
    }
}
