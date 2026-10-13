import Testing
@testable import SpreadsheetCore

@Suite("Number formatting")
struct NumberFormatTests {
    @Test func generalRendering() {
        #expect(NumberFormatEngine.generalString(for: 0) == "0")
        #expect(NumberFormatEngine.generalString(for: 42) == "42")
        #expect(NumberFormatEngine.generalString(for: -42) == "-42")
        #expect(NumberFormatEngine.generalString(for: 1.5) == "1.5")
        #expect(NumberFormatEngine.generalString(for: 0.1 + 0.2) == "0.3")
        #expect(NumberFormatEngine.generalString(for: 1234567890) == "1234567890")
        #expect(NumberFormatEngine.generalString(for: 0.5) == "0.5")
        #expect(NumberFormatEngine.generalString(for: -0.25) == "-0.25")
        // Large magnitudes go scientific.
        #expect(NumberFormatEngine.generalString(for: 1e21) == "1E+21")
        #expect(NumberFormatEngine.generalString(for: 1.5e15).contains("E+"))
        // Tiny magnitudes go scientific.
        #expect(NumberFormatEngine.generalString(for: 1e-10).contains("E-"))
    }

    @Test func basicNumericFormats() {
        #expect(NumberFormatEngine.formatNumber(3.14159, code: "0") == "3")
        #expect(NumberFormatEngine.formatNumber(3.14159, code: "0.00") == "3.14")
        #expect(NumberFormatEngine.formatNumber(3.156, code: "0.00") == "3.16")
        #expect(NumberFormatEngine.formatNumber(0.5, code: "0.00") == "0.50")
        #expect(NumberFormatEngine.formatNumber(0.5, code: "#.##") == ".5")
        #expect(NumberFormatEngine.formatNumber(1234567.891, code: "#,##0") == "1,234,568")
        #expect(NumberFormatEngine.formatNumber(1234567.891, code: "#,##0.00") == "1,234,567.89")
        #expect(NumberFormatEngine.formatNumber(-5, code: "0") == "-5")
        #expect(NumberFormatEngine.formatNumber(-1234.5, code: "#,##0.00") == "-1,234.50")
        #expect(NumberFormatEngine.formatNumber(7, code: "000") == "007")
    }

    @Test func percentFormats() {
        #expect(NumberFormatEngine.formatNumber(0.42, code: "0%") == "42%")
        #expect(NumberFormatEngine.formatNumber(0.4567, code: "0.00%") == "45.67%")
        #expect(NumberFormatEngine.formatNumber(-0.05, code: "0%") == "-5%")
        #expect(NumberFormatEngine.formatNumber(1.5, code: "0%") == "150%")
    }

    @Test func currencyFormats() {
        #expect(NumberFormatEngine.formatNumber(1234.5, code: "$#,##0.00") == "$1,234.50")
        #expect(NumberFormatEngine.formatNumber(0.99, code: "$#,##0.00") == "$0.99")
        // One-section formats put the minus in front of the whole result,
        // currency symbol included (Excel and Sheets both show -$14.62).
        #expect(NumberFormatEngine.formatNumber(-14.62, code: "$#,##0.00") == "-$14.62")
        #expect(NumberFormatEngine.formatNumber(-1234.5, code: "$#,##0.00") == "-$1,234.50")
        #expect(NumberFormatEngine.formatNumber(-14.62, code: "\"USD \"0.00") == "-USD 14.62")
        #expect(NumberFormatEngine.displayString(for: .number(-14.62), format: .currency) == "-$14.62")
    }

    @Test func multiSectionFormats() {
        let code = "0.00;(0.00);\"zero\""
        #expect(NumberFormatEngine.formatNumber(5, code: code) == "5.00")
        #expect(NumberFormatEngine.formatNumber(-5, code: code) == "(5.00)")
        #expect(NumberFormatEngine.formatNumber(0, code: code) == "zero")
        // Two sections: negatives use second with abs value.
        #expect(NumberFormatEngine.formatNumber(-3, code: "0.0;[Red](0.0)") == "(3.0)")
    }

    @Test func scientificFormat() {
        #expect(NumberFormatEngine.formatNumber(12345, code: "0.00E+00") == "1.23E+04")
        #expect(NumberFormatEngine.formatNumber(0.00123, code: "0.00E+00") == "1.23E-03")
    }

    @Test func literalsAndEscapes() {
        #expect(NumberFormatEngine.formatNumber(42, code: "0\" units\"") == "42 units")
        #expect(NumberFormatEngine.formatNumber(5, code: "0.0 \"kg\"") == "5.0 kg")
        #expect(NumberFormatEngine.formatNumber(-5, code: "0.0 \"kg\"") == "-5.0 kg")
    }

    @Test func dateFormats() {
        let serial = ExcelDate.serial(year: 2026, month: 9, day: 13) // Sunday
        #expect(NumberFormatEngine.formatNumber(serial, code: "m/d/yyyy") == "9/13/2026")
        #expect(NumberFormatEngine.formatNumber(serial, code: "mm/dd/yy") == "09/13/26")
        #expect(NumberFormatEngine.formatNumber(serial, code: "yyyy-mm-dd") == "2026-09-13")
        #expect(NumberFormatEngine.formatNumber(serial, code: "d-mmm-yy") == "13-Sep-26")
        #expect(NumberFormatEngine.formatNumber(serial, code: "mmmm d, yyyy") == "September 13, 2026")
        #expect(NumberFormatEngine.formatNumber(serial, code: "dddd") == "Sunday")
        #expect(NumberFormatEngine.formatNumber(serial, code: "ddd") == "Sun")
    }

    @Test func timeFormats() {
        let t = ExcelDate.serial(year: 2026, month: 9, day: 13, hour: 14, minute: 5, second: 9)
        #expect(NumberFormatEngine.formatNumber(t, code: "h:mm") == "14:05")
        #expect(NumberFormatEngine.formatNumber(t, code: "hh:mm:ss") == "14:05:09")
        #expect(NumberFormatEngine.formatNumber(t, code: "h:mm AM/PM") == "2:05 PM")
        let morning = ExcelDate.serial(year: 2026, month: 9, day: 13, hour: 0, minute: 30, second: 0)
        #expect(NumberFormatEngine.formatNumber(morning, code: "h:mm AM/PM") == "12:30 AM")
    }

    @Test func monthVsMinuteDisambiguation() {
        let t = ExcelDate.serial(year: 2026, month: 3, day: 5, hour: 7, minute: 8, second: 9)
        // m after h means minutes; m next to d means month.
        #expect(NumberFormatEngine.formatNumber(t, code: "h:mm:ss") == "7:08:09")
        #expect(NumberFormatEngine.formatNumber(t, code: "m/d") == "3/5")
        #expect(NumberFormatEngine.formatNumber(t, code: "mm:ss") == "08:09")
    }

    @Test func elapsedTimeFormats() {
        // 1.5 days = 36 hours.
        #expect(NumberFormatEngine.formatNumber(1.5, code: "[h]:mm") == "36:00")
        #expect(NumberFormatEngine.formatNumber(2.0 / 24, code: "[m]") == "120")
    }

    @Test func textFormatSection() {
        let f = NumberFormat(code: "0.00;-0.00;0;\"note: \"@")
        #expect(NumberFormatEngine.displayString(for: .string("hi"), format: f) == "note: hi")
        #expect(NumberFormatEngine.displayString(for: .string("hi"), format: .general) == "hi")
    }

    @Test func displayStringByType() {
        #expect(NumberFormatEngine.displayString(for: .empty, format: .general) == "")
        #expect(NumberFormatEngine.displayString(for: .bool(true), format: .decimal2) == "TRUE")
        #expect(NumberFormatEngine.displayString(for: .error(.div0), format: .general) == "#DIV/0!")
        #expect(NumberFormatEngine.displayString(for: .number(1.5), format: .general) == "1.5")
    }

    @Test func builtinTable() {
        #expect(NumberFormat.builtin(0)?.isGeneral == true)
        #expect(NumberFormat.builtin(2)?.code == "0.00")
        #expect(NumberFormat.builtin(9)?.code == "0%")
        #expect(NumberFormat.builtin(14)?.code == "m/d/yyyy")
        #expect(NumberFormat.builtin(49)?.code == "@")
        #expect(NumberFormat.builtinID(for: "0.00") == 2)
        #expect(NumberFormat.builtinID(for: "") == 0)
        #expect(NumberFormat.builtinID(for: "yyyy-qq") == nil)
    }

    @Test func formatClassification() {
        #expect(NumberFormat(code: "m/d/yyyy").isDateTime)
        #expect(NumberFormat(code: "[h]:mm").isDateTime)
        #expect(!NumberFormat(code: "0.00").isDateTime)
        #expect(!NumberFormat(code: "\"years\"0").isDateTime)
        #expect(NumberFormat(code: "@").isTextFormat)
        #expect(NumberFormat.general.isGeneral)
        #expect(NumberFormat(code: "General").isGeneral)
    }

    @Test func unsupportedFallsBackToGeneral() {
        // Fraction formats fall back to General rendering.
        #expect(NumberFormatEngine.formatNumber(1.5, code: "# ?/?") == "1.5")
    }

    @Test func roundingCarry() {
        #expect(NumberFormatEngine.formatNumber(0.999, code: "0.00") == "1.00")
        #expect(NumberFormatEngine.formatNumber(9.99, code: "0.0") == "10.0")
        #expect(NumberFormatEngine.formatNumber(0.996, code: "0.00") == "1.00")
    }
}

@Suite("Decimal place adjustment")
struct DecimalAdjustmentTests {
    private func adjust(_ code: String, _ delta: Int) -> String? {
        NumberFormat(code: code).adjustingDecimals(by: delta)?.code
    }

    @Test func increase() {
        #expect(adjust("0", 1) == "0.0")
        #expect(adjust("0.00", 1) == "0.000")
        #expect(adjust("#,##0", 1) == "#,##0.0")
        #expect(adjust("$#,##0.00", 1) == "$#,##0.000")
        #expect(adjust("0%", 1) == "0.0%")
        #expect(adjust("0.00E+00", 1) == "0.000E+00")
        #expect(adjust("#,##0,", 1) == "#,##0.0,")
        #expect(adjust("#,##0.00;[Red](#,##0.00)", 1) == "#,##0.000;[Red](#,##0.000)")
        #expect(adjust("\"Qty: \"0", 1) == "\"Qty: \"0.0")
        #expect(adjust("[$€-407]#,##0", 1) == "[$€-407]#,##0.0")
        #expect(adjust("_(0_)", 1) == "_(0.0_)")
    }

    @Test func decrease() {
        #expect(adjust("0.00", -1) == "0.0")
        #expect(adjust("0.0", -1) == "0")
        #expect(adjust("$#,##0.00", -1) == "$#,##0.0")
        #expect(adjust("0.0%", -1) == "0%")
        #expect(adjust("0.00E+00", -1) == "0.0E+00")
        #expect(adjust("0", -1) == nil)
    }

    @Test func leavesNonNumericFormatsAlone() {
        #expect(adjust("", 1) == nil)
        #expect(adjust("@", 1) == nil)
        #expect(adjust("m/d/yyyy", 1) == nil)
        #expect(adjust("h:mm:ss AM/PM", -1) == nil)
        // A literal dot in quotes is not the decimal point.
        #expect(adjust("\"v.\"0", 1) == "\"v.\"0.0")
    }

    @Test func formattedOutput() {
        let code = adjust("$#,##0.00", 1)!
        #expect(NumberFormatEngine.formatNumber(1234.5, code: code) == "$1,234.500")
    }
}
