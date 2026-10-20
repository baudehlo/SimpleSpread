import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles
@testable import SpreadsheetUI

@MainActor
@Suite("Legacy Excel import")
struct XLSImportTests {
    @Test func legacyImportBecomesAnUnsavedXLSXAndWarnsAboutDroppedContent() {
        let source = URL(fileURLWithPath: "/imports/Quarterly.xls")
        let workbook = Workbook.newDocument()
        let loaded = LoadedFile(
            workbook: workbook,
            engine: CalculationEngine(workbook: workbook),
            isTextImport: false,
            isLegacyImport: true,
            truncatedRows: false,
            unsupportedContent: ["formulas", "2 charts", "comments"])

        let document = SpreadsheetDocument.make(from: loaded, url: source)

        #expect(document.isLegacyImport)
        #expect(document.fileURL == nil)
        #expect(document.suggestedFileName == "Quarterly.xlsx")
        #expect(document.unsupportedContent == ["formulas", "2 charts", "comments"])
        #expect(document.notice?.message == "This Excel 97–2003 workbook was opened as an XLSX copy.")
        #expect(document.notice?.detail == "Formulas show their last calculated values and won’t recalculate. "
            + "Its 2 charts and comments couldn’t be brought over. "
            + "Save your edits as an XLSX file; the original file is not changed.")
        guard case .choose(let lossNote) = DocumentSaving.plan(for: document) else {
            Issue.record("XLS imports must offer an XLSX save location.")
            return
        }
        #expect(lossNote?.contains("Quarterly.xlsx") == true)
        #expect(lossNote?.contains("formulas") == true)
        #expect(lossNote?.contains("original file is not changed") == true)
    }

    @Test func loadingTreatsXLSAsAnImportRatherThanAnEditableSource() {
        #expect(SpreadsheetDocument.legacyImportExtensions.contains("xls"))
        #expect(!SpreadsheetDocument.textImportExtensions.contains("xls"))
    }
}
