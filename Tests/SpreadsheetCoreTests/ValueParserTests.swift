import Foundation
import Testing
@testable import SpreadsheetCore

@Suite("Input value parsing")
struct ValueParserTests {
    let refDate = DateComponents(calendar: .current, year: 2026, month: 9, day: 13).date!

    func parse(_ s: String, allowFormulas: Bool = true, textFormat: Bool = false) -> ParsedInput {
        ValueParser.parse(s, allowFormulas: allowFormulas, textFormat: textFormat, referenceDate: refDate)
    }

    @Test func numbers() {
        #expect(parse("42").value == .number(42))
        #expect(parse("-3.5").value == .number(-3.5))
        #expect(parse("+7").value == .number(7))
        #expect(parse("1,234.5").value == .number(1234.5))
        #expect(parse("1e3").value == .number(1000))
        #expect(parse("2.5E-2").value == .number(0.025))
        #expect(parse(" 42 ").value == .number(42))
    }

    @Test func invalidGroupingStaysText() {
        #expect(parse("1,23").value == .string("1,23"))
        #expect(parse("12,34,56").value == .string("12,34,56"))
        #expect(parse(",5").value == .string(",5"))
    }

    @Test func leadingZeroPreservation() {
        #expect(parse("00501").value == .string("00501"))
        #expect(parse("0123").value == .string("0123"))
        #expect(parse("0").value == .number(0))
        #expect(parse("0.5").value == .number(0.5))
    }

    @Test func longDigitStringsStayText() {
        #expect(parse("4111111111111111111").value == .string("4111111111111111111"))
        #expect(parse("123456789012345").value == .number(123456789012345))
    }

    @Test func percent() {
        let p = parse("5%")
        #expect(p.value == .number(0.05))
        #expect(p.suggestedFormat == .percentInteger)
        let p2 = parse("12.5%")
        #expect(p2.value == .number(0.125))
        #expect(p2.suggestedFormat == .percent)
        #expect(parse("abc%").value == .string("abc%"))
    }

    @Test func currency() {
        let c = parse("$1,234.50")
        #expect(c.value == .number(1234.5))
        #expect(c.suggestedFormat == .currency)
        #expect(parse("-$5").value == .number(-5))
        #expect(parse("$abc").value == .string("$abc"))
    }

    @Test func booleans() {
        #expect(parse("TRUE").value == .bool(true))
        #expect(parse("false").value == .bool(false))
        #expect(parse("truthy").value == .string("truthy"))
    }

    @Test func formulas() {
        let f = parse("=SUM(A1:A3)")
        #expect(f.formulaText == "SUM(A1:A3)")
        #expect(parse("=").value == .string("=")) // bare '=' is text
        // Formula suppressed on import.
        let imported = parse("=SUM(A1)", allowFormulas: false)
        #expect(imported.formulaText == nil)
        #expect(imported.value == .string("=SUM(A1)"))
    }

    @Test func apostropheForcesText() {
        let p = parse("'00501")
        #expect(p.value == .string("00501"))
        #expect(parse("'=1+1").value == .string("=1+1"))
        #expect(parse("'text").value == .string("text"))
    }

    @Test func textFormatSuppressesEverything() {
        #expect(parse("42", textFormat: true).value == .string("42"))
        #expect(parse("=1+1", textFormat: true).value == .string("=1+1"))
        #expect(parse("00501", textFormat: true).value == .string("00501"))
    }

    @Test func dates() {
        let expected = ExcelDate.serial(year: 2026, month: 1, day: 2)
        for input in ["1/2/2026", "01/02/2026", "2026-01-02", "Jan 2, 2026", "2 Jan 2026", "January 2 2026"] {
            let p = parse(input)
            #expect(p.value == .number(expected), "failed for \(input)")
            #expect(p.suggestedFormat?.isDateTime == true, "no date format for \(input)")
        }
        // Two-digit years.
        #expect(parse("1/2/26").value == .number(expected))
        #expect(parse("1/2/99").value == .number(ExcelDate.serial(year: 1999, month: 1, day: 2)))
        // Year-less M/D uses the reference year.
        #expect(parse("1/2").value == .number(expected))
    }

    @Test func invalidDatesStayText() {
        #expect(parse("13/45/2026").value == .string("13/45/2026"))
        #expect(parse("2/30/2026").value == .string("2/30/2026"))
        #expect(parse("1-2").value == .string("1-2")) // ambiguous: not inferred
        #expect(parse("MAR1").value == .string("MAR1"))
    }

    @Test func times() {
        let p = parse("14:30")
        #expect(p.value == .number(ExcelDate.timeFraction(hour: 14, minute: 30, second: 0)))
        #expect(p.suggestedFormat == .time)
        #expect(parse("2:30 PM").value == .number(ExcelDate.timeFraction(hour: 14, minute: 30, second: 0)))
        #expect(parse("12:15 AM").value == .number(ExcelDate.timeFraction(hour: 0, minute: 15, second: 0)))
        #expect(parse("9:05:30").value == .number(ExcelDate.timeFraction(hour: 9, minute: 5, second: 30)))
        #expect(parse("25:00").value == .string("25:00"))
        #expect(parse("9:75").value == .string("9:75"))
    }

    @Test func dateTimes() {
        let p = parse("1/2/2026 14:30")
        let expected = ExcelDate.serial(year: 2026, month: 1, day: 2, hour: 14, minute: 30, second: 0)
        #expect(p.value == .number(expected))
        #expect(p.suggestedFormat == .dateTime)
        let p2 = parse("Jan 2, 2026 2:30 PM")
        #expect(p2.value == .number(expected))
    }

    @Test func errorLiterals() {
        #expect(parse("#N/A").value == .error(.na))
        #expect(parse("#DIV/0!").value == .error(.div0))
        #expect(parse("#nope").value == .string("#nope"))
    }

    @Test func empties() {
        #expect(parse("").value == .empty)
        #expect(parse("   ").value == .string("   ")) // whitespace preserved as text
    }

    @Test func plainText() {
        #expect(parse("hello world").value == .string("hello world"))
        #expect(parse("3 apples").value == .string("3 apples"))
    }
}

@Suite("Coercion & criteria")
struct CoercionTests {
    @Test func numericTextParsing() {
        #expect(Coerce.parseNumericText("42") == 42)
        #expect(Coerce.parseNumericText(" -1,234.5 ") == -1234.5)
        #expect(Coerce.parseNumericText("50%") == 0.5)
        #expect(Coerce.parseNumericText("$12") == 12)
        #expect(Coerce.parseNumericText("1e3") == 1000)
        #expect(Coerce.parseNumericText("abc") == nil)
        #expect(Coerce.parseNumericText("inf") == nil)
        #expect(Coerce.parseNumericText("nan") == nil)
        #expect(Coerce.parseNumericText("0x10") == nil)
        #expect(Coerce.parseNumericText("") == nil)
        #expect(Coerce.parseNumericText("1 2") == nil)
    }

    @Test func wildcardMatching() {
        #expect(Criterion.wildcardMatch(pattern: "a*", text: "apple"))
        #expect(Criterion.wildcardMatch(pattern: "*le", text: "apple"))
        #expect(Criterion.wildcardMatch(pattern: "a??le", text: "apple"))
        #expect(Criterion.wildcardMatch(pattern: "*", text: ""))
        #expect(Criterion.wildcardMatch(pattern: "APPLE", text: "apple"))
        #expect(!Criterion.wildcardMatch(pattern: "a?", text: "apple"))
        #expect(Criterion.wildcardMatch(pattern: "10~%", text: "10%"))
        #expect(!Criterion.wildcardMatch(pattern: "10~%", text: "10X"))
        #expect(Criterion.wildcardMatch(pattern: "~*star", text: "*star"))
        #expect(!Criterion.wildcardMatch(pattern: "~*star", text: "Xstar"))
        #expect(Criterion.wildcardMatch(pattern: "a*b*c", text: "aXXbYYc"))
    }

    @Test func criterionParsing() {
        let gt = Criterion.parse(.string(">5"))
        #expect(gt.matches(.number(6)))
        #expect(!gt.matches(.number(5)))
        #expect(!gt.matches(.string("6"))) // numeric bound ignores text
        let ne = Criterion.parse(.string("<>x"))
        #expect(ne.matches(.string("y")))
        #expect(!ne.matches(.string("x")))
        #expect(ne.matches(.number(5))) // non-text matches "<>text"
        let blank = Criterion.parse(.string(""))
        #expect(blank.matches(.empty))
        #expect(!blank.matches(.number(0)))
        let nonBlank = Criterion.parse(.string("<>"))
        #expect(nonBlank.matches(.number(0)))
        #expect(!nonBlank.matches(.empty))
        let direct = Criterion.parse(.number(5))
        #expect(direct.matches(.number(5)))
        let boolCrit = Criterion.parse(.bool(true))
        #expect(boolCrit.matches(.bool(true)))
        #expect(!boolCrit.matches(.number(1)))
        let textGe = Criterion.parse(.string(">=m"))
        #expect(textGe.matches(.string("zebra")))
        #expect(!textGe.matches(.string("apple")))
        #expect(!textGe.matches(.number(999)))
    }
}
