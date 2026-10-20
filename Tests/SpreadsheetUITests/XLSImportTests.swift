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
            unsupportedContent: ["formula text", "macros"])

        let document = SpreadsheetDocument.make(from: loaded, url: source)

        #expect(document.isLegacyImport)
        #expect(document.fileURL == nil)
        #expect(document.suggestedFileName == "Quarterly.xlsx")
        #expect(document.unsupportedContent == ["formula text", "macros"])
        #expect(document.notice?.message == "This Excel 97–2003 workbook was opened as an XLSX copy.")
        #expect(document.notice?.detail.contains("cached values") == true)
        #expect(document.notice?.detail.contains("Only cell values and basic formatting are imported") == true)
        #expect(document.notice?.detail.contains("charts, images, macros") == true)
        #expect(document.notice?.detail.contains("macros") == true)
        #expect(document.notice?.detail.contains("original file is unchanged") == true)
        guard case .choose(let lossNote) = DocumentSaving.plan(for: document) else {
            Issue.record("XLS imports must offer an XLSX save location.")
            return
        }
        #expect(lossNote?.contains("Quarterly.xlsx") == true)
        #expect(lossNote?.contains("formula text") == true)
        #expect(lossNote?.contains("original file is not changed") == true)
    }

    @Test func loadingTreatsXLSAsAnImportRatherThanAnEditableSource() {
        #expect(SpreadsheetDocument.legacyImportExtensions.contains("xls"))
        #expect(!SpreadsheetDocument.textImportExtensions.contains("xls"))
    }
}
