import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// Defined names and `_xlfn.` prefixes through XLSX (review #8, #9).
@Suite("XLSX defined names and function prefixes")
struct DefinedNamesXLSXTests {
    func roundTrip(_ workbook: Workbook) throws -> Workbook {
        try XLSXReader.read(data: XLSXWriter.data(for: workbook))
    }

    @Test func definedNamesRoundTrip() throws {
        let wb = Workbook.newDocument()
        let data = wb.addSheet(named: "My Data")
        data.autoFilter = AutoFilter(range: CellRange(a1: "A1:B5")!)
        wb.definedNames = [
            DefinedName(name: "Sales", formula: "'My Data'!$B$2:$B$5"),
            DefinedName(name: "Rate", scopeSheetID: data.id, formula: "0.25"),
            DefinedName(name: "_xlnm.Print_Area", scopeSheetID: data.id, formula: "'My Data'!$A$1:$D$20"),
            DefinedName(name: "Secret", formula: "IFNA(1,2)", hidden: true),
        ]
        let xml = XLSXWriter.workbookXML(workbook: wb)
        #expect(xml.contains("<definedName name=\"Secret\" hidden=\"1\">_xlfn.IFNA(1,2)</definedName>"))
        #expect(xml.contains("<definedName name=\"_xlnm.Print_Area\" localSheetId=\"1\">"))
        #expect(xml.contains("_xlnm._FilterDatabase")) // still written for the AutoFilter

        let read = try roundTrip(wb)
        let readData = try #require(read.sheet(named: "My Data"))
        #expect(read.definedNames == [
            DefinedName(name: "Sales", formula: "'My Data'!$B$2:$B$5"),
            DefinedName(name: "Rate", scopeSheetID: readData.id, formula: "0.25"),
            DefinedName(name: "_xlnm.Print_Area", scopeSheetID: readData.id, formula: "'My Data'!$A$1:$D$20"),
            DefinedName(name: "Secret", formula: "IFNA(1,2)", hidden: true),
        ])
    }

    @Test func namesEvaluateAfterOpen() throws {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        for r in 0..<3 { sheet.setCell(Cell(value: .number(Double(r + 1))), at: CellAddress(row: r, column: 0)) }
        // Cached values as Excel would have written them.
        sheet.setCell(Cell(value: .number(6), formula: "SUM(Values)"), at: CellAddress(a1: "B1")!)
        sheet.setCell(Cell(value: .number(42), formula: "MADEUPFUNCTION(A1)"), at: CellAddress(a1: "B2")!)
        sheet.setCell(Cell(value: .number(2), formula: "IFNA(NA(),2)"), at: CellAddress(a1: "B3")!)
        wb.definedNames = [DefinedName(name: "Values", formula: "Sheet1!$A$1:$A$3")]
        let read = try roundTrip(wb)
        _ = CalculationEngine(workbook: read)
        let s = read.sheets[0]
        #expect(s.value(at: CellAddress(a1: "B1")!) == .number(6))
        #expect(s.value(at: CellAddress(a1: "B2")!) == .number(42)) // kept, not #NAME?
        #expect(s.value(at: CellAddress(a1: "B3")!) == .number(2))
        #expect(s.cell(at: CellAddress(a1: "B3")!).formula == "IFNA(NA(),2)")
    }

    @Test func prefixesWrittenByBothWriters() {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        sheet.setCell(Cell(value: .number(1), formula: "IFNA(A2,0)+XLOOKUP(1,A3:A4,B3:B4)"), at: CellAddress(a1: "A1")!)
        sheet.setCell(Cell(value: .string("x"), formula: "CONCAT(\"IFNA(\",A2)"), at: CellAddress(a1: "B1")!)
        let styles = StyleParts(workbook: wb)
        var s1 = SharedStringBuilder(), s2 = SharedStringBuilder()
        let fast = XLSXWriter.worksheetXML(sheet: sheet, workbook: wb, styles: styles, strings: &s1)
        let slow = XLSXWriter.worksheetXML(sheet: sheet, workbook: wb, styles: styles, strings: &s2,
                                           fastSheetData: false)
        #expect(fast == slow)
        let xml = String(decoding: fast, as: UTF8.self)
        #expect(xml.contains("<f>_xlfn.IFNA(A2,0)+_xlfn.XLOOKUP(1,A3:A4,B3:B4)</f>"))
        #expect(xml.contains("<f>_xlfn.CONCAT(&quot;IFNA(&quot;,A2)</f>") || xml.contains("<f>_xlfn.CONCAT(\"IFNA(\",A2)</f>"))
    }

    @Test func prefixesStrippedByBothReaders() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        <row r="1"><c r="A1"><f>_xlfn.IFNA(B1,0)+_xlfn._xlws.SORT(C1:C2)</f><v>0</v></c>\
        <c r="B1"><f t="shared" ref="B1:B2" si="0">_xlfn.STDEV.S(C1:C3)</f><v>1</v></c></row>
        <row r="2"><c r="B2"><f t="shared" si="0"/><v>1</v></c></row>
        </sheetData></worksheet>
        """
        let data = Data(xml.utf8)
        for fastSheetData in [true, false] {
            let sheet = Sheet(id: 1, name: "S")
            try XLSXReader.parseWorksheet(data, into: sheet, sharedStrings: [], styleIndexMap: [:],
                                          fastSheetData: fastSheetData)
            #expect(sheet.cell(at: CellAddress(a1: "A1")!).formula == "IFNA(B1,0)+SORT(C1:C2)")
            #expect(sheet.cell(at: CellAddress(a1: "B1")!).formula == "STDEV.S(C1:C3)")
            #expect(sheet.cell(at: CellAddress(a1: "B2")!).formula == "STDEV.S(C2:C4)")
        }
    }
}
