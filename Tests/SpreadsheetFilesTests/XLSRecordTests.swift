import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

@Suite("BIFF record primitives")
struct XLSRecordTests {
    @Test func recordReaderRejectsTruncatedPayloads() throws {
        var reader = BIFFRecordReader(Data([0x03, 0x02, 0x04, 0x00, 0x01]))
        #expect(throws: XLSBinaryError.self) { _ = try reader.next() }
    }

    @Test func sharedStringsContinueCompressedUnicodeAndWideText() throws {
        var first = Data([0, 0, 0, 0, 2, 0, 0, 0])
        first.append(contentsOf: [5, 0, 0, 65, 66])
        let continuation = Data([0, 67, 68, 69, 2, 0, 1, 0x3D, 0xD8, 0x00, 0xDE])
        var cursor = BIFFSSTCursor([first, continuation])
        try cursor.skip(8)
        #expect(try cursor.readString() == "ABCDE")
        #expect(try cursor.readString() == "😀")
    }

    @Test func compressedUnicodeUsesLowByteCodepoints() {
        #expect(BIFFString.decodeCompressed([0x80, 0x9F]) == "\u{0080}\u{009F}")
    }

    @Test func sharedStringMetadataCanCrossContinueWithoutCompressionFlag() throws {
        var first = Data([0, 0, 0, 0, 2, 0, 0, 0])
        first.append(contentsOf: [1, 0, 0x08, 1, 0, 65, 0, 0])
        let continuation = Data([0, 0, 1, 0, 0, 66])
        var cursor = BIFFSSTCursor([first, continuation])
        try cursor.skip(8)
        #expect(try cursor.readString() == "A")
        #expect(try cursor.readString() == "B")
        #expect(cursor.hasRichText)
    }

    @Test func realWorkbookStylesDecodeFontPaletteAndFill() throws {
        let url = try #require(Bundle.module.url(
            forResource: "business-export", withExtension: "xls", subdirectory: "Fixtures/LegacyXLS"))
        let workbook = try XLSReader.read(data: Data(contentsOf: url))
        let sheet = try #require(workbook.sheet(named: "业务报表"))
        let header = workbook.style(at: sheet.cell(at: CellAddress(a1: "A1")!).styleIndex)
        #expect(header.fontName == "Arial")
        #expect(header.fontSize == 14)
        #expect(header.bold)
        #expect(header.textColor == .white)
        #expect(header.fillColor == RGBAColor(red: 36, green: 88, blue: 132))
        #expect(header.wrapText)
    }
}
