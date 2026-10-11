import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// GETPIVOTDATA against pivots Excel laid out. Every expected value is the
/// cell Excel rendered (or #REF! where Excel shows no such total).
@Suite("GETPIVOTDATA on real pivots")
struct GetPivotDataFixtureTests {
    /// Evaluate `formula` in an empty cell (Z100) of `sheet` in a fixture.
    static func eval(_ file: String, _ sheet: String, _ formula: String) throws -> CellValue {
        let (workbook, _) = try PivotFixtures.read(file)
        let engine = CalculationEngine(workbook: workbook)
        let host = try #require(workbook.sheet(named: sheet))
        let address = AbsoluteAddress(sheetID: host.id, address: CellAddress(a1: "Z100")!)
        engine.setCellFormula(formula, at: address)
        return host.value(at: address.address)
    }

    static func number(_ file: String, _ sheet: String, _ formula: String) throws -> Double? {
        try eval(file, sheet, formula).numberValue
    }

    static func close(_ got: Double?, _ expected: Double) -> Bool {
        guard let got else { return false }
        return abs(got - expected) <= 1e-6 * max(1, abs(expected))
    }

    // MARK: Excel's own formula

    @Test func excelsFormulaInPOI54436() throws {
        // Sheet1!A14 = GETPIVOTDATA("Sum of Score",A8,"Category","Category 1"), cached 3.
        let (workbook, _) = try PivotFixtures.read("poi-54436.xlsx")
        _ = CalculationEngine(workbook: workbook)
        let sheet = try #require(workbook.sheet(named: "Sheet1"))
        #expect(sheet.value(at: CellAddress(a1: "A14")!) == .number(3))
    }

    // MARK: One row field

    @Test func rowItemsAndGrandTotal() throws {
        let file = "poi-54436.xlsx"
        #expect(try Self.number(file, "Sheet1", #"GETPIVOTDATA("Sum of Score",B10,"Category","Category 2")"#) == 12)
        #expect(try Self.number(file, "Sheet1", #"GETPIVOTDATA("Sum of Score",A8)"#) == 15)
        #expect(try Self.number(file, "Sheet1", #"GETPIVOTDATA("score",A8,"category","CATEGORY 1")"#) == 3)
        #expect(try Self.eval(file, "Sheet1", #"GETPIVOTDATA("Sum of Score",A8,"Category","Category 3")"#) == .error(.ref))
        #expect(try Self.eval(file, "Sheet1", #"GETPIVOTDATA("Sum of Score",A7)"#) == .error(.ref))
        #expect(try Self.eval(file, "Sheet1", #"GETPIVOTDATA("Count of Score",A8)"#) == .error(.ref))
    }

    @Test func twoPivotsOnOneSheet() throws {
        // PivotTable5 at A1:B4 (yellow 40), PivotTable6 at A6:B9 (yellow 50).
        let file = "calamine-pivots.xlsx"
        #expect(try Self.number(file, "PivotSheet4", #"GETPIVOTDATA("Sum of Value",A2,"Category","yellow")"#) == 40)
        #expect(try Self.number(file, "PivotSheet4", #"GETPIVOTDATA("Sum of Value",B8,"Category","yellow")"#) == 50)
        #expect(try Self.number(file, "PivotSheet4", #"GETPIVOTDATA("Sum of Value",A6)"#) == 125)
        #expect(try Self.eval(file, "PivotSheet4", #"GETPIVOTDATA("Sum of Value",A5)"#) == .error(.ref))
    }

    // MARK: Several data fields

    @Test func valuesOnColumnsPicksTheDataFieldsColumn() throws {
        let file = "openxmlsdk-pivot5.xlsx", sheet = "By Product"
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Sum of Qtr 3",A6,"Product","Boston Crab Meat")"#) == 4412.32)
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Qtr 2",A6,"Product","alice mutton")"#) == 4013.1)
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Sum of Qtr 4",A6)"#) == 44803.26)
        // A product with nothing in Qtr 1 shows 0.
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Sum of Qtr 1",A6,"Product","Chef Anton's Gumbo Mix")"#) == 0)
    }

    @Test func valuesOnColumnsInsideAnotherColumnField() throws {
        // Sheet5: Year then Values on columns, Category on rows, no grand totals.
        let file = "poi-WithChartSheet.xlsx"
        #expect(try Self.number(file, "Sheet5", #"GETPIVOTDATA("Sum of Revenue",A3,"Category","Books","Year",2006)"#) == 1320585.375)
        #expect(try Self.number(file, "Sheet5", #"GETPIVOTDATA("Sum of Cost",A3,"Year",2007,"Category","MMusic")"#) == 875455)
        // Tabular form (Sheet6), root field name.
        #expect(try Self.number(file, "Sheet6", #"GETPIVOTDATA("Revenue",A3,"Category","mmovies","Year",2005)"#) == 823227.875)
        // Grand totals are off: no row or column total to read.
        #expect(try Self.eval(file, "Sheet5", #"GETPIVOTDATA("Sum of Revenue",A3,"Category","Books")"#) == .error(.ref))
        #expect(try Self.eval(file, "Sheet5", #"GETPIVOTDATA("Sum of Revenue",A3,"Year",2006)"#) == .error(.ref))
        #expect(try Self.eval(file, "Sheet5", #"GETPIVOTDATA("Sum of Revenue",A3)"#) == .error(.ref))
    }

    @Test func valuesOnRows() throws {
        let file = "poi-WithChartSheet.xlsx"
        // Sheet3: Year then Values on rows, Category on columns.
        #expect(try Self.number(file, "Sheet3", #"GETPIVOTDATA("Sum of Revenue",A3,"Year",2006,"Category","Electronics")"#) == 19299870)
        #expect(try Self.number(file, "Sheet3", #"GETPIVOTDATA("Sum of Cost",A3,"Year",2005)"#) == 15355463)
        // Per-data-field grand rows ("Total Sum of Revenue").
        #expect(try Self.number(file, "Sheet3", #"GETPIVOTDATA("Sum of Revenue",A3,"Category","Books")"#) == 4024235)
        #expect(Self.close(try Self.number(file, "Sheet3", #"GETPIVOTDATA("Sum of Revenue",A3)"#), 68366467.44))
        #expect(try Self.number(file, "Sheet3", #"GETPIVOTDATA("Sum of Cost",A3)"#) == 56808729)
        // Sheet2: no column fields.
        #expect(Self.close(try Self.number(file, "Sheet2", #"GETPIVOTDATA("Sum of Revenue",A3,"Year",2007)"#), 27490579.69))
        #expect(try Self.number(file, "Sheet2", #"GETPIVOTDATA("Sum of Cost",A3)"#) == 56808729)
    }

    // MARK: Subtotals

    @Test func subtotalsAtTheTopOfOutlineRows() throws {
        // Sheet4: Category then Year on rows, subtotals shown on the parent row.
        let file = "poi-WithChartSheet.xlsx"
        #expect(try Self.number(file, "Sheet4", #"GETPIVOTDATA("Sum of Revenue",A3,"Category","Electronics")"#) == 58837793)
        #expect(try Self.number(file, "Sheet4", #"GETPIVOTDATA("Sum of Revenue",A3,"Category","Electronics","Year",2006)"#) == 19299870)
        #expect(try Self.number(file, "Sheet4", #"GETPIVOTDATA("Sum of Cost",A3,"Year",2006,"Category","Books")"#) == 1025796)
        // Year alone isn't a leading row field: Excel shows no such total.
        #expect(try Self.eval(file, "Sheet4", #"GETPIVOTDATA("Sum of Cost",A3,"Year",2006)"#) == .error(.ref))
    }

    @Test func subtotalLinesBelowTabularRowsAndColumns() throws {
        // Rows D, A and columns C, B, tabular, subtotals at the bottom, no grand totals.
        let file = "libreoffice-PivotTableFormatsSubTotals.xlsx", sheet = "Sheet2"
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Sum of B",B3,"D",1,"A",3,"C",1,"B",6)"#) == 6)
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Sum of B",B3,"D",2,"A",2,"C",1,"B",1)"#) == 1)
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Sum of B",B3,"D",2,"C",1)"#) == 9)       // G12
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Sum of B",B3,"D",2,"C",3)"#) == 5)       // J12
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Sum of B",B3,"D",2,"A",6,"C",4)"#) == 3) // L10
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Sum of B",B3,"D",3,"C",3,"B",3)"#) == 3) // H14
        // A blank cell inside the pivot reads as 0.
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Sum of B",B3,"D",2,"A",1,"C",1,"B",6)"#) == 0)
        #expect(try Self.eval(file, sheet, #"GETPIVOTDATA("Sum of B",B3,"D",2)"#) == .error(.ref))
        #expect(try Self.eval(file, sheet, #"GETPIVOTDATA("Sum of B",B3,"A",3,"C",1)"#) == .error(.ref))
    }

    @Test func subtotalsOnColumnsAndParentRows() throws {
        // Region > Category on rows, Year > Quarter on columns.
        let file = "powertools-QuarterlySales.xlsx", sheet = "Pivot"
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Sum of Amount",A3,"Region","North","Year",2010,"Quarter","Q1")"#) == 3448)
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Sum of Amount",A3,"Region","North","Category","Bicycles","Year",2010)"#) == 3448)
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Sum of Amount",A3,"Quarter","Q1","Year",2010)"#) == 3448)
        #expect(try Self.eval(file, sheet, #"GETPIVOTDATA("Sum of Amount",A3,"Quarter","Q1")"#) == .error(.ref))
        #expect(try Self.eval(file, sheet, #"GETPIVOTDATA("Sum of Amount",A3,"Region","South")"#) == .error(.ref))
    }

    @Test func parentRowsWithoutSubtotalsHaveNothingToRead() throws {
        // Product > Customer with Product subtotals off: Alice Mutton's row is blank.
        let file = "openxmlsdk-pivot5.xlsx", sheet = "By Product-Customer"
        #expect(try Self.eval(file, sheet, #"GETPIVOTDATA("Sum of Qtr 1",A6,"Product","Alice Mutton")"#) == .error(.ref))
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Sum of Qtr 2",A6,"Product","Alice Mutton","Customer","ANTON")"#) == 702)
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Sum of Qtr 1",A6,"Product","Alice Mutton","Customer","bergs")"#) == 312)
        // ALFKI bought no Alice Mutton: no such row.
        #expect(try Self.eval(file, sheet, #"GETPIVOTDATA("Sum of Qtr 1",A6,"Product","Alice Mutton","Customer","ALFKI")"#) == .error(.ref))
    }

    @Test func collapsedItemsShowTheirTotal() throws {
        // Product > Customer with every product collapsed.
        let file = "openxmlsdk-pivot5.xlsx", sheet = "By Product-Customer Filtered"
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Sum of Qtr 1",A6,"Product","Alice Mutton")"#) == 2667.6)
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Sum of Qtr 3",A6,"Product","Boston Crab Meat")"#) == 4412.32)
        #expect(try Self.eval(file, sheet, #"GETPIVOTDATA("Sum of Qtr 1",A6,"Product","Alice Mutton","Customer","ANTON")"#) == .error(.ref))
    }

    // MARK: Grouping

    @Test func groupedFieldsMatchTheirLabels() throws {
        // Value2 groups Value: "5" and "Group1" (10, 15, 20). Subtotals at the top.
        let file = "calamine-pivots.xlsx", sheet = "PivotSheet2"
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Sum of Size",A3,"Value2","Group1","Category","blue")"#) == 11.067)
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Sum of Size",A3,"Value2","group1","Value",15,"Category","yellow")"#) == 5.0731)
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Sum of Size",A3,"Value2",5,"Value",5,"Category","yellow")"#) == 2.22452)
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Sum of Size",A3,"Value2","Group1","Value",10,"Category","yellow")"#) == 0)
        #expect(Self.close(try Self.number(file, sheet, #"GETPIVOTDATA("Sum of Size",A3,"Value2","Group1")"#), 16.1401))
        #expect(Self.close(try Self.number(file, sheet, #"GETPIVOTDATA("Sum of Size",A3,"Category","yellow")"#), 7.29762))
        // 20 isn't in the "5" group.
        #expect(try Self.eval(file, sheet, #"GETPIVOTDATA("Sum of Size",A3,"Value2",5,"Value",20)"#) == .error(.ref))
    }

    @Test func dateGroups() throws {
        // Years > Quarters > Months (grouped dates), no subtotals; Values on columns.
        let file = "libreoffice-shared-nested-dategroup.xlsx", sheet = "Munka3"
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Összeg / c",A3,"Évek",1989,"Negyedévek","N.év2","a","May")"#) == 89517)
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Összeg / e",G3,"évek","2007","negyedévek","n.év1","A","feb")"#) == 85966)
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Összeg / e",A3)"#) == 2042856)
        // Year rows show no subtotal.
        #expect(try Self.eval(file, sheet, #"GETPIVOTDATA("Összeg / c",A3,"Évek",1965)"#) == .error(.ref))
        // Months without their year and quarter aren't a line of the pivot.
        #expect(try Self.eval(file, sheet, #"GETPIVOTDATA("Összeg / c",A3,"a","Jan")"#) == .error(.ref))
    }

    // MARK: Hidden items and report filters

    @Test func hiddenItemsAreRefErrors() throws {
        // Field1 "b" and Field3 2022-01-02 are hidden.
        let file = "poi-ExcelPivotTableSample.xlsx", sheet = "Tabelle2"
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Summe von Field2",A3,"Field1","a","Field3",DATE(2022,1,1))"#) == 1)
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Summe von Field2",A3,"Field1","c","Field3",44564)"#) == 3)
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Summe von Field2",A3,"Field3",44564)"#) == 3)
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Summe von Field2",A3)"#) == 4)
        #expect(try Self.eval(file, sheet, #"GETPIVOTDATA("Summe von Field2",A3,"Field1","b")"#) == .error(.ref))
        #expect(try Self.eval(file, sheet, #"GETPIVOTDATA("Summe von Field2",A3,"Field3",DATE(2022,1,2))"#) == .error(.ref))
        // A blank crossing reads as 0.
        #expect(try Self.number(file, sheet, #"GETPIVOTDATA("Summe von Field2",A3,"Field1","c","Field3",44562)"#) == 0)
    }

    @Test func reportFilters() throws {
        let file = "calamine-pivots.xlsx"
        // PivotSheet1: Date filter showing (Multiple Items); four data fields on columns.
        #expect(Self.close(try Self.number(file, "PivotSheet1", #"GETPIVOTDATA("Average of Value",A3,"Category","yellow")"#), 8.333333333))
        // The filter cells identify the pivot too.
        #expect(Self.close(try Self.number(file, "PivotSheet1", #"GETPIVOTDATA("Sum of Value x 2",A1)"#), 25.54830581))
        #expect(try Self.number(file, "PivotSheet1", #"GETPIVOTDATA("Count of Size",B2)"#) == 3)
        // A filter set to several items, or to (All), shows no single item's data.
        #expect(try Self.eval(file, "PivotSheet1", #"GETPIVOTDATA("Sum of Size",A3,"Date",DATE(2024,1,1))"#) == .error(.ref))
        #expect(try Self.eval(file, "PivotSheet2", #"GETPIVOTDATA("Sum of Size",A3,"Name","a")"#) == .error(.ref))
        // Filtered out by the report filter: not in the pivot.
        #expect(try Self.eval(file, "PivotSheet1", #"GETPIVOTDATA("Sum of Size",A3,"Category","blue")"#) == .error(.ref))
        // A field that's in the cache but not in this pivot.
        #expect(try Self.eval(file, "PivotSheet3", #"GETPIVOTDATA("Count of Value2",A3,"Category","blue")"#) == .error(.ref))
        #expect(try Self.number(file, "PivotSheet3", #"GETPIVOTDATA("Count of Value2",A3,"Name","H")"#) == 1)
    }

    @Test func outsideAnyPivot() throws {
        #expect(try Self.eval("calamine-pivots.xlsx", "DataSheet", #"GETPIVOTDATA("Sum of Size",A1)"#) == .error(.ref))
        #expect(try Self.eval("calamine-pivots.xlsx", "DataSheet", #"GETPIVOTDATA("Sum of Size",PivotSheet2!A3)"#) != .error(.ref))
    }
}
