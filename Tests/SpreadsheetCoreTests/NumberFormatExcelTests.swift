import Testing
@testable import SpreadsheetCore

/// Renderer cases from code review finding #22 and the display half of #24,
/// with the results Excel shows.
@Suite("Number formats: Excel parity")
struct NumberFormatExcelTests {
    private func fmt(_ n: Double, _ code: String) -> String {
        NumberFormatEngine.formatNumber(n, code: code)
    }

    @Test func elapsedHoursUseTheRoundedTime() {
        // 7:12 - 0:12 is 6:59:59.99999... in binary.
        let diff = ExcelDate.timeFraction(hour: 7, minute: 12, second: 0)
            - ExcelDate.timeFraction(hour: 0, minute: 12, second: 0)
        #expect(fmt(diff, "[h]:mm") == "7:00")
        #expect(fmt(diff, "[h]:mm:ss") == "7:00:00")
        #expect(fmt(diff, "[mm]:ss") == "420:00")
        #expect(fmt(diff, "[s]") == "25200")
        #expect(fmt(diff, "h:mm") == "7:00")
        #expect(fmt(1.5, "[h]:mm") == "36:00")
    }

    @Test func secondsRoundBeforeSplitting() {
        let t = ExcelDate.timeFraction(hour: 12, minute: 0, second: 59.6)
        #expect(fmt(t, "h:mm:ss") == "12:01:00")
        #expect(fmt(t, "hh:mm") == "12:01")
        #expect(fmt(t, "mm:ss.0") == "00:59.6")
        let late = 45000 + ExcelDate.timeFraction(hour: 23, minute: 59, second: 59.7)
        // Serial 45000 is 3/15/2023; 23:59:59.7 rounds into the next day.
        #expect(fmt(late, "m/d/yyyy h:mm:ss") == "3/16/2023 0:00:00")
        #expect(fmt(45000.99999999, "h:mm:ss") == "0:00:00")
        #expect(fmt(45000.99999999, "[h]:mm:ss") == "1080024:00:00")
        // Fractional seconds round to the shown precision.
        #expect(fmt(ExcelDate.timeFraction(hour: 0, minute: 0, second: 1.26), "mm:ss.0") == "00:01.3")
        #expect(fmt(ExcelDate.timeFraction(hour: 0, minute: 0, second: 1.26), "mm:ss.00") == "00:01.26")
    }

    @Test func scalingCommasBeforeLiterals() {
        #expect(fmt(12345, "#,##0,\"K\"") == "12K")
        #expect(fmt(2_500_000, "0.0,,\"M\"") == "2.5M")
        #expect(fmt(2_500_000, "#,##0.0,,\" M\"") == "2.5 M")
        #expect(fmt(1_234_567, "#,##0,") == "1,235")
        #expect(fmt(1_234_567, "0,") == "1235")
        #expect(fmt(1_234_567, "#,##0") == "1,234,567")
    }

    @Test func conditionalSections() {
        let code = "[>=1000000]0.0,,\"M\";[>=1000]0.0,\"K\";0"
        #expect(fmt(500, code) == "500")
        #expect(fmt(2500, code) == "2.5K")
        #expect(fmt(2_500_000, code) == "2.5M")
        #expect(fmt(999, code) == "999")
        // Negatives fall to the third section and keep their sign.
        #expect(fmt(-5000, code) == "-5000")
        // One condition: the other numbers use section 2.
        #expect(fmt(150, "[>100]\"big\";\"small\"") == "big")
        #expect(fmt(50, "[>100]\"big\";\"small\"") == "small")
        // [Red] and conditions together.
        #expect(fmt(-3, "[Red][<0]0.0;[Blue][>0]0.0;0") == "3.0")
        #expect(fmt(3, "[Red][<0]0.0;[Blue][>0]0.0;0") == "3.0")
        #expect(fmt(0, "[Red][<0]0.0;[Blue][>0]0.0;\"zero\"") == "zero")
        #expect(fmt(5, "[=5]\"five\";0") == "five")
        #expect(fmt(6, "[=5]\"five\";0") == "6")
        #expect(fmt(6, "[<>5]\"other\";0") == "other")
    }

    @Test func scientificCarry() {
        #expect(fmt(9.999, "0.00E+00") == "1.00E+01")
        #expect(fmt(99999, "0.0E+0") == "1.0E+5")
        #expect(fmt(12345, "0.00E+00") == "1.23E+04")
        #expect(fmt(0.00123, "0.00E+00") == "1.23E-03")
        #expect(fmt(-9.999, "0.00E+00") == "-1.00E+01")
        #expect(fmt(0, "0.00E+00") == "0.00E+00")
    }

    @Test func hugeValuesInNumberFormats() {
        #expect(fmt(1e20, "#,##0") == "100,000,000,000,000,000,000")
        #expect(fmt(-1e20, "#,##0") == "-100,000,000,000,000,000,000")
        // Beyond 15 significant digits Excel shows zeros.
        #expect(fmt(123456789012345678, "0") == "123456789012346000")
    }

    @Test func displayRoundingUsesFifteenDigits() {
        #expect(fmt(0.145, "0%") == "15%")
        #expect(fmt(1.005, "0.00") == "1.01")
        #expect(fmt(-1.005, "0.00") == "-1.01")
        #expect(fmt(2.675, "0.00") == "2.68")
        #expect(fmt(1.0049999, "0.00") == "1.00")
        #expect(fmt(0.5, "0") == "1")
        #expect(fmt(2.5, "0") == "3")
        #expect(fmt(0.1 + 0.2, "0.0000000000000000") == "0.3000000000000000")
    }

    @Test func existingBehaviourKept() {
        #expect(fmt(0.5, "#.##") == ".5")
        #expect(fmt(7, "000") == "007")
        #expect(fmt(0.999, "0.00") == "1.00")
        #expect(fmt(9.99, "0.0") == "10.0")
        #expect(fmt(1234.5, "$#,##0.00") == "$1,234.50")
        #expect(fmt(-3, "0.0;[Red](0.0)") == "(3.0)")
        #expect(fmt(5, "0.00;(0.00);\"zero\"") == "5.00")
        #expect(fmt(0, "0.00;(0.00);\"zero\"") == "zero")
        #expect(fmt(1.5, "# ?/?") == "1.5")
    }
}

/// Results read from Excel for the web (13 October 2026) for the cases the
/// first pass of these fixes got wrong.
@Suite("Checked in Excel for the web")
struct ExcelWebCheckedTests {
    @Test func conditionalSectionsDropTheSignOnlyForNegativeOnlySections() {
        func text(_ n: Double, _ code: String) -> String {
            NumberFormatEngine.formatNumber(n, code: code)
        }
        #expect(text(-500, "[>=1000]0.0,\"K\";0") == "-500")
        #expect(text(-5, "[<0]0.0;0") == "5.0")
        #expect(text(-5, "[>=0]0.0;0.00") == "5.00")
        #expect(text(-1500, "[<=-1000]0,\"K\";0") == "2K")
        #expect(text(1_500_000, "[>=1000000]0.0,,\"M\";[>=1000]0.0,\"K\";0") == "1.5M")
        #expect(text(-2500, "[>=1000]0,\"K\";[<=-1000]-0,\"K\";0") == "-3K")
    }

    @Test func yearfracBasisZeroAtTheEndOfFebruary() throws {
        func yf(_ a: (Int, Int, Int), _ b: (Int, Int, Int), _ basis: Int) throws -> Double {
            try DateTimeFunctions.yearfracValue(start: ExcelDate.serial(year: a.0, month: a.1, day: a.2),
                                                end: ExcelDate.serial(year: b.0, month: b.1, day: b.2), basis: basis)
        }
        #expect(abs(try yf((2023, 2, 28), (2023, 3, 31), 0) - 31.0 / 360) < 1e-12)
        #expect(abs(try yf((2024, 2, 29), (2024, 3, 31), 0) - 31.0 / 360) < 1e-12)
        #expect(try yf((2023, 2, 28), (2024, 2, 29), 0) == 1)
        #expect(abs(try yf((2023, 1, 31), (2023, 2, 28), 0) - 28.0 / 360) < 1e-12)
        #expect(try yf((2023, 1, 1), (2024, 1, 1), 1) == 1)
        #expect(abs(try yf((2023, 6, 1), (2024, 3, 1), 1) - 274.0 / 366) < 1e-12)
    }
}
