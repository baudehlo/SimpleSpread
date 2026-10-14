import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// `XLSXWriter.data(for:progress:)`: progress for the save panel, and Cancel.
@Suite("Writer progress and cancel")
struct WriterProgressTests {
    /// Two sheets, big enough for several progress steps in each phase
    /// (sheet data in 64K-cell steps, compression in 1 MB chunks).
    func workbook(rows: Int = 150_000) -> Workbook {
        let wb = Workbook.newDocument()
        let first = wb.sheets[0]
        for r in 0..<rows {
            first.setCell(Cell(value: .number(Double(r) * 1.5)), at: CellAddress(row: r, column: 0))
            first.setCell(Cell(value: .string("row \(r % 977)")), at: CellAddress(row: r, column: 1))
        }
        let second = wb.addSheet(named: "Two")
        for r in 0..<(rows / 3) {
            second.setCell(Cell(value: .number(Double(r)), formula: "Sheet1!A\(r + 1)*2"),
                           at: CellAddress(row: r, column: 0))
        }
        return wb
    }

    @Test func progressIsMonotonicAndReachesOne() throws {
        let wb = workbook()
        var reports: [Double] = []
        let data = try XLSXWriter.data(for: wb) { fraction in
            reports.append(fraction)
            return true
        }
        #expect(reports.count > 10)
        #expect(reports.first! >= 0)
        #expect(reports.last == 1)
        #expect(zip(reports, reports.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(reports.allSatisfy { $0 >= 0 && $0 <= 1 })
        // Progress doesn't change what is written.
        #expect(data == (try XLSXWriter.data(for: wb)))
    }

    @Test func compressionReportsAsItGoes() throws {
        // Several 1 MB chunks: compression should report between them, not
        // only once the sheet's whole part is done.
        let wb = workbook()
        var reports: [Double] = []
        _ = try XLSXWriter.data(for: wb) { fraction in
            reports.append(fraction)
            return true
        }
        let compressing = reports.filter { $0 > XLSXWriter.sheetDataShare && $0 < 1 }
        #expect(compressing.count >= 3)
    }

    @Test func cancelStopsTheWrite() {
        let wb = workbook()
        var calls = 0
        #expect(throws: XLSXError.cancelled) {
            _ = try XLSXWriter.data(for: wb) { _ in
                calls += 1
                return calls < 3
            }
        }
        #expect(calls == 3)
    }

    @Test func cancelDuringCompression() {
        let wb = workbook()
        #expect(throws: XLSXError.cancelled) {
            _ = try XLSXWriter.data(for: wb) { $0 <= XLSXWriter.sheetDataShare }
        }
    }

    @Test func anEmptyWorkbookStillReachesOne() throws {
        var reports: [Double] = []
        _ = try XLSXWriter.data(for: Workbook.newDocument()) { reports.append($0); return true }
        #expect(reports.last == 1)
    }

    @Test func batchedCompressionRoundTrips() throws {
        // Compressing in batches (for progress) still makes one deflate stream.
        var bytes = [UInt8]()
        for i in 0..<(5 << 20) { bytes.append(UInt8((i * 7 + i / 1000) & 0x7F)) }
        let data = Data(bytes)
        var steps = 0
        let withProgress = Deflate.compress(data, batchSize: 2) { _ in steps += 1 }
        #expect(withProgress == Deflate.compress(data))
        #expect(steps == 3)
        let inflated = try Deflate.decompress(withProgress!, uncompressedSize: data.count)
        #expect(inflated == data)
    }
}
