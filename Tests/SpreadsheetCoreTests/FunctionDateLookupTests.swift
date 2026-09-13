import Testing
@testable import SpreadsheetCore

@Suite("Date/time functions")
struct DateFunctionTests {
    @Test func dateConstruction() {
        #expect(evalNumber("DATE(2026,9,13)") == 46278)
        #expect(evalNumber("DATE(2020,13,1)") == evalNumber("DATE(2021,1,1)"))
        #expect(evalNumber("DATE(2020,2,30)") == evalNumber("DATE(2020,3,1)"))
        #expect(evalNumber("DATE(119,1,1)") == evalNumber("DATE(2019,1,1)")) // <1900 adds 1900
    }

    @Test func timeConstruction() {
        #expect(approx(evalNumber("TIME(12,0,0)"), 0.5))
        #expect(approx(evalNumber("TIME(25,0,0)"), 1.0 / 24)) // wraps
        #expect(approx(evalNumber("TIME(6,30,0)"), 6.5 / 24))
    }

    @Test func todayNowWithFixedClock() {
        #expect(evalNumber("TODAY()") == 46278)
        #expect(approx(evalNumber("NOW()"), 46278 + 10.5 / 24))
    }

    @Test func componentExtraction() {
        #expect(evalNumber("YEAR(DATE(2026,9,13))") == 2026)
        #expect(evalNumber("MONTH(DATE(2026,9,13))") == 9)
        #expect(evalNumber("DAY(DATE(2026,9,13))") == 13)
        #expect(evalNumber("HOUR(TIME(14,30,45))") == 14)
        #expect(evalNumber("MINUTE(TIME(14,30,45))") == 30)
        #expect(evalNumber("SECOND(TIME(14,30,45))") == 45)
        #expect(evalNumber("YEAR(\"2026-09-13\")") == 2026) // date strings accepted
    }

    @Test func weekday() {
        // 2026-09-13 is a Sunday.
        #expect(evalNumber("WEEKDAY(DATE(2026,9,13))") == 1)
        #expect(evalNumber("WEEKDAY(DATE(2026,9,13),2)") == 7)
        #expect(evalNumber("WEEKDAY(DATE(2026,9,13),3)") == 6)
        // 2024-01-01 is a Monday.
        #expect(evalNumber("WEEKDAY(DATE(2024,1,1),2)") == 1)
    }

    @Test func weeknum() {
        #expect(evalNumber("WEEKNUM(DATE(2024,1,1))") == 1)
        #expect(evalNumber("WEEKNUM(DATE(2024,1,7))") == 2) // Sunday starts week 2
        #expect(evalNumber("WEEKNUM(DATE(2024,1,7),2)") == 1) // Monday-start: still week 1
        #expect(evalNumber("ISOWEEKNUM(DATE(2024,1,1))") == 1)
        #expect(evalNumber("ISOWEEKNUM(DATE(2023,1,1))") == 52) // ISO: belongs to 2022-W52
    }

    @Test func edateEomonth() {
        #expect(evalNumber("EDATE(DATE(2026,1,31),1)") == evalNumber("DATE(2026,2,28)")) // clamps
        #expect(evalNumber("EDATE(DATE(2026,3,15),-1)") == evalNumber("DATE(2026,2,15)"))
        #expect(evalNumber("EOMONTH(DATE(2026,2,10),0)") == evalNumber("DATE(2026,2,28)"))
        #expect(evalNumber("EOMONTH(DATE(2024,1,15),1)") == evalNumber("DATE(2024,2,29)"))
        #expect(evalNumber("EOMONTH(DATE(2026,1,15),-2)") == evalNumber("DATE(2025,11,30)"))
    }

    @Test func datedif() {
        #expect(evalNumber("DATEDIF(DATE(2020,1,1),DATE(2023,6,15),\"Y\")") == 3)
        #expect(evalNumber("DATEDIF(DATE(2020,1,1),DATE(2023,6,15),\"M\")") == 41)
        #expect(evalNumber("DATEDIF(DATE(2020,1,1),DATE(2020,1,31),\"D\")") == 30)
        #expect(evalNumber("DATEDIF(DATE(2020,1,15),DATE(2023,6,10),\"YM\")") == 4)
        // Day-of-month not yet reached: 9/30/15 -> 2/28/16 = 4 whole months.
        #expect(evalNumber("DATEDIF(DATE(2015,9,30),DATE(2016,2,28),\"M\")") == 4)
        #expect(evalError("DATEDIF(DATE(2023,1,1),DATE(2020,1,1),\"D\")") == .num)
        #expect(evalError("DATEDIF(DATE(2020,1,1),DATE(2023,1,1),\"Q\")") == .num)
    }

    @Test func daysAndArithmetic() {
        #expect(evalNumber("DAYS(DATE(2026,1,10),DATE(2026,1,1))") == 9)
        #expect(evalNumber("DATE(2026,1,10)-DATE(2026,1,1)") == 9)
        #expect(evalNumber("DATE(2026,1,1)+30") == evalNumber("DATE(2026,1,31)"))
    }

    @Test func networkdaysAndWorkday() {
        // 2026-09-07 (Mon) .. 2026-09-11 (Fri) = 5 workdays.
        #expect(evalNumber("NETWORKDAYS(DATE(2026,9,7),DATE(2026,9,11))") == 5)
        // Spanning a weekend: Fri 9/11 .. Mon 9/14 = 2.
        #expect(evalNumber("NETWORKDAYS(DATE(2026,9,11),DATE(2026,9,14))") == 2)
        // Holiday excluded.
        #expect(evalNumber("NETWORKDAYS(DATE(2026,9,7),DATE(2026,9,11),A1)",
                           cells: ["A1": "=DATE(2026,9,9)"]) == 4)
        // WORKDAY skips weekends: Fri + 1 workday = Monday.
        #expect(evalNumber("WORKDAY(DATE(2026,9,11),1)") == evalNumber("DATE(2026,9,14)"))
        #expect(evalNumber("WORKDAY(DATE(2026,9,14),-1)") == evalNumber("DATE(2026,9,11)"))
    }

    @Test func yearfrac() {
        #expect(approx(evalNumber("YEARFRAC(DATE(2026,1,1),DATE(2026,7,1),3)"), 181.0 / 365))
        #expect(approx(evalNumber("YEARFRAC(DATE(2026,1,1),DATE(2027,1,1),0)"), 1))
        #expect(approx(evalNumber("YEARFRAC(DATE(2026,1,1),DATE(2026,2,1),2)"), 31.0 / 360))
    }

    @Test func datevalueTimevalue() {
        #expect(evalNumber("DATEVALUE(\"9/13/2026\")") == 46278)
        #expect(evalNumber("DATEVALUE(\"2026-09-13\")") == 46278)
        #expect(evalError("DATEVALUE(\"not a date\")") == .value)
        #expect(approx(evalNumber("TIMEVALUE(\"12:00\")"), 0.5))
        #expect(approx(evalNumber("TIMEVALUE(\"6:30 PM\")"), 18.5 / 24))
    }
}

@Suite("Lookup functions")
struct LookupFunctionTests {
    // A small product table.
    let table = [
        "A1": "apple", "B1": "1.50", "C1": "fruit",
        "A2": "banana", "B2": "0.75", "C2": "fruit",
        "A3": "carrot", "B3": "0.30", "C3": "veg",
    ]

    @Test func vlookupExact() {
        #expect(evalNumber("VLOOKUP(\"banana\",A1:C3,2,FALSE)", cells: table) == 0.75)
        #expect(evalString("VLOOKUP(\"carrot\",A1:C3,3,FALSE)", cells: table) == "veg")
        #expect(evalError("VLOOKUP(\"durian\",A1:C3,2,FALSE)", cells: table) == .na)
        #expect(evalError("VLOOKUP(\"apple\",A1:C3,4,FALSE)", cells: table) == .value)
        #expect(evalError("VLOOKUP(\"apple\",A1:C3,0,FALSE)", cells: table) == .value)
        // Case-insensitive + wildcards.
        #expect(evalNumber("VLOOKUP(\"BANANA\",A1:C3,2,FALSE)", cells: table) == 0.75)
        #expect(evalNumber("VLOOKUP(\"ban*\",A1:C3,2,FALSE)", cells: table) == 0.75)
    }

    @Test func vlookupSorted() {
        let nums = ["A1": "10", "A2": "20", "A3": "30",
                    "B1": "x", "B2": "y", "B3": "z"]
        #expect(evalString("VLOOKUP(25,A1:B3,2)", cells: nums) == "y") // largest <= 25
        #expect(evalString("VLOOKUP(30,A1:B3,2)", cells: nums) == "z")
        #expect(evalError("VLOOKUP(5,A1:B3,2)", cells: nums) == .na) // below first
    }

    @Test func hlookup() {
        let cells = ["A1": "10", "B1": "20", "A2": "x", "B2": "y"]
        #expect(evalString("HLOOKUP(20,A1:B2,2,FALSE)", cells: cells) == "y")
        #expect(evalString("HLOOKUP(15,A1:B2,2)", cells: cells) == "x")
    }

    @Test func xlookup() {
        let cells = ["A1": "a", "A2": "b", "A3": "c", "B1": "1", "B2": "2", "B3": "3"]
        #expect(evalNumber("XLOOKUP(\"b\",A1:A3,B1:B3)", cells: cells) == 2)
        #expect(evalString("XLOOKUP(\"z\",A1:A3,B1:B3,\"none\")", cells: cells) == "none")
        #expect(evalError("XLOOKUP(\"z\",A1:A3,B1:B3)", cells: cells) == .na)
        // match_mode 1: next greater; -1: next smaller.
        let nums = ["A1": "10", "A2": "20", "A3": "30", "B1": "x", "B2": "y", "B3": "z"]
        #expect(evalString("XLOOKUP(25,A1:A3,B1:B3,\"-\",1)", cells: nums) == "z")
        #expect(evalString("XLOOKUP(25,A1:A3,B1:B3,\"-\",-1)", cells: nums) == "y")
        // search_mode -1: last match wins.
        let dup = ["A1": "a", "A2": "a", "B1": "first", "B2": "last"]
        #expect(evalString("XLOOKUP(\"a\",A1:A2,B1:B2,\"-\",0,-1)", cells: dup) == "last")
    }

    @Test func match() {
        let cells = ["A1": "10", "A2": "20", "A3": "30"]
        #expect(evalNumber("MATCH(20,A1:A3,0)", cells: cells) == 2)
        #expect(evalNumber("MATCH(25,A1:A3,1)", cells: cells) == 2)
        #expect(evalNumber("MATCH(25,A1:A3)", cells: cells) == 2) // default 1
        #expect(evalError("MATCH(5,A1:A3,1)", cells: cells) == .na)
        #expect(evalError("MATCH(15,A1:A3,0)", cells: cells) == .na)
        let desc = ["A1": "30", "A2": "20", "A3": "10"]
        #expect(evalNumber("MATCH(25,A1:A3,-1)", cells: desc) == 1)
        // Text match with wildcards in exact mode.
        let words = ["A1": "alpha", "A2": "beta"]
        #expect(evalNumber("MATCH(\"b*\",A1:A2,0)", cells: words) == 2)
    }

    @Test func index() {
        let cells = ["A1": "1", "B1": "2", "A2": "3", "B2": "4"]
        #expect(evalNumber("INDEX(A1:B2,2,1)", cells: cells) == 3)
        #expect(evalNumber("INDEX(A1:B2,1,2)", cells: cells) == 2)
        #expect(evalError("INDEX(A1:B2,3,1)", cells: cells) == .ref)
        // 1-D column range: single arg is the row.
        #expect(evalNumber("INDEX(A1:A2,2)", cells: cells) == 3)
        // 1-D row range: single arg is the column.
        #expect(evalNumber("INDEX(A1:B1,2)", cells: cells) == 2)
    }

    @Test func chooseFunction() {
        #expect(evalString("CHOOSE(2,\"a\",\"b\",\"c\")") == "b")
        #expect(evalError("CHOOSE(4,\"a\",\"b\")") == .num)
        #expect(evalError("CHOOSE(0,\"a\")") == .num)
        #expect(evalNumber("CHOOSE(1,5,1/0)") == 5) // lazy
    }

    @Test func addressFunction() {
        #expect(evalString("ADDRESS(2,3)") == "$C$2")
        #expect(evalString("ADDRESS(2,3,2)") == "C$2")
        #expect(evalString("ADDRESS(2,3,3)") == "$C2")
        #expect(evalString("ADDRESS(2,3,4)") == "C2")
        #expect(evalString("ADDRESS(1,1,1,TRUE,\"My Sheet\")") == "'My Sheet'!$A$1")
    }

    @Test func rowColumnFunctions() {
        // AZ99 is the formula host cell: row 99, column 52.
        #expect(evalNumber("ROW()") == 99)
        #expect(evalNumber("COLUMN()") == 52)
        #expect(evalNumber("ROW(B7)") == 7)
        #expect(evalNumber("COLUMN(B7)") == 2)
        #expect(evalNumber("ROW(C3:D9)") == 3)
        #expect(evalNumber("ROWS(A1:B5)") == 5)
        #expect(evalNumber("COLUMNS(A1:B5)") == 2)
        #expect(evalNumber("ROWS(3:7)") == 5)
    }

    @Test func lookupFunction() {
        let cells = ["A1": "10", "A2": "20", "A3": "30", "B1": "x", "B2": "y", "B3": "z"]
        #expect(evalString("LOOKUP(25,A1:A3,B1:B3)", cells: cells) == "y")
        #expect(evalNumber("LOOKUP(25,A1:A3)", cells: cells) == 20)
    }
}
