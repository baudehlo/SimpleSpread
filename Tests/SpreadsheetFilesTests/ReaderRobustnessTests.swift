import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// Untrusted input must never trap: every reader path either reads a file
/// or throws. And where both worksheet readers accept a file, they agree.
@Suite("Reader robustness")
struct ReaderRobustnessTests {
    static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

    struct Parsed {
        let sheet: Sheet?
        let error: (any Error)?
    }

    static func parse(_ data: Data, fast: Bool, progress: ((Double) -> Bool)? = nil) -> Parsed {
        let sheet = Sheet(id: 1, name: "S")
        do {
            try XLSXReader.parseWorksheet(data, into: sheet, sharedStrings: ["zero", "one", "two"],
                                          styleIndexMap: [0: 0, 1: 5, 2: 7], progress: progress,
                                          fastSheetData: fast)
            return Parsed(sheet: sheet, error: nil)
        } catch {
            return Parsed(sheet: nil, error: error)
        }
    }

    /// Both readers; returns the sheets when both succeed (and checks they agree).
    @discardableResult
    static func bothAgree(_ data: Data, _ label: @autoclosure () -> String,
                          sourceLocation: SourceLocation = #_sourceLocation) -> Sheet? {
        let fast = parse(data, fast: true)
        let slow = parse(data, fast: false)
        guard let a = fast.sheet, let b = slow.sheet else { return nil }
        let same = a.cells == b.cells && a.rowHeights == b.rowHeights && a.hiddenRows == b.hiddenRows
            && a.columnWidths == b.columnWidths && a.mergedRanges == b.mergedRanges
            && a.autoFilter == b.autoFilter && a.frozenRows == b.frozenRows
            && a.frozenColumns == b.frozenColumns && a.defaultRowHeight == b.defaultRowHeight
        #expect(same, "readers disagree: \(label())", sourceLocation: sourceLocation)
        return a
    }

    static func worksheet(_ body: String, declaration: String = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>") -> Data {
        Data((declaration + "<worksheet xmlns=\"\(main)\">" + body + "</worksheet>").utf8)
    }

    // MARK: Crashes found by review (#4)

    @Test func oneByteSheetDataDoesNotCrash() {
        for body in ["<sheetData> </sheetData>", "<sheetData>x</sheetData>", "<sheetData>  </sheetData>",
                     "<sheetData>\n</sheetData>", "<sheetData><</sheetData>"] {
            _ = Self.parse(Self.worksheet(body), fast: true)
            _ = Self.parse(Self.worksheet(body), fast: false)
        }
        let sheet = Self.bothAgree(Self.worksheet("<sheetData> </sheetData>"), "space")
        #expect(sheet?.cells.isEmpty == true)
    }

    @Test func emptyDateCellsDoNotCrash() {
        let body = """
        <sheetData><row r="1"><c r="A1" t="d"/><c r="B1" t="d"><v></v></c><c r="C1" t="d"><v>T</v></c>\
        <c r="D1" t="d"><v>99999999999999999-1-1</v></c><c r="E1" t="d"><v>2024-1-1</v></c>\
        <c r="F1" t="d"><v>2024-01-02T99999999999999999999:00</v></c></row></sheetData>
        """
        let sheet = Self.bothAgree(Self.worksheet(body), "date cells")
        #expect(sheet?.cell(at: CellAddress(row: 0, column: 0)).value == .empty)
        #expect(sheet?.cell(at: CellAddress(row: 0, column: 4)).value == .number(ExcelDate.serial(year: 2024, month: 1, day: 1)))
        #expect(XLSXReader.isoDateToSerial("") == nil)
        #expect(XLSXReader.isoDateToSerial("T") == nil)
        #expect(XLSXReader.isoDateToSerial("2024-02-30") != nil) // rolls over, as DATE() does
    }

    @Test func badColumnRangesDoNotCrash() {
        let body = """
        <cols><col min="5" max="3" width="10"/><col min="9223372036854775807" max="9223372036854775807" width="5"/>\
        <col min="0" max="2" width="8"/><col min="-4" max="-1" width="8"/><col min="1" max="9223372036854775807" width="nan"/>\
        <col min="20" max="20" width="inf"/></cols><sheetData/>
        """
        let sheet = Self.bothAgree(Self.worksheet(body), "cols")
        #expect(sheet != nil)
        #expect(sheet?.columnWidths.keys.allSatisfy { $0 >= 0 && $0 < CellAddress.maxColumns } == true)
        #expect(sheet?.columnWidths.values.allSatisfy { $0.isFinite } == true)
    }

    @Test func extremeRowNumbersDoNotCrash() {
        let body = """
        <sheetFormatPr defaultRowHeight="inf"/><sheetViews><sheetView><pane xSplit="-3" ySplit="99999999999999" state="frozen"/></sheetView></sheetViews>\
        <sheetData><row r="9223372036854775807" ht="nan"><c><v>1</v></c></row><row ht="1e308"><c><v>2</v></c></row>\
        <row><c><v>3</v></c></row><row r="2" ht="-5"><c r="XFD2"><v>4</v></c><c><v>5</v></c><c><v>6</v></c></row></sheetData>
        """
        let sheet = Self.bothAgree(Self.worksheet(body), "rows")
        #expect(sheet != nil)
        #expect(sheet?.rowHeights.values.allSatisfy { $0.isFinite && $0 >= 0 } == true)
        #expect(sheet.map { $0.defaultRowHeight.isFinite } == true)
        #expect(sheet.map { $0.frozenRows >= 0 && $0.frozenRows <= CellAddress.maxRows } == true)
        #expect(sheet.map { $0.frozenColumns >= 0 && $0.frozenColumns <= CellAddress.maxColumns } == true)
    }

    @Test func hostileWorkbookAndStyleValuesAreBounded() throws {
        let workbook = """
        <workbook xmlns="\(Self.main)" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\
        <sheet name="A" sheetId="9223372036854775807" r:id="rId1"/><sheet name="B" sheetId="-4" r:id="rId2"/></sheets></workbook>
        """
        let info = try XLSXReader.parseWorkbook(Data(workbook.utf8))
        #expect(info.sheets.map(\.sheetID) == [1, 2])
        // A workbook built from them can still add sheets (nextSheetID + 1 would overflow).
        let wb = Workbook()
        for meta in info.sheets { wb.insertSheet(Sheet(id: meta.sheetID, name: meta.name), at: wb.sheets.count) }
        #expect(wb.addSheet().id == 3)

        let styles = """
        <styleSheet xmlns="\(Self.main)"><fonts count="1"><font><sz val="1e308"/></font></fonts><fills count="0"/><borders count="0"/>\
        <cellXfs count="1"><xf numFmtId="99999999999" fontId="0" fillId="0" borderId="0"><alignment indent="9223372036854775807"/></xf></cellXfs></styleSheet>
        """
        let (xfs, _) = try XLSXReader.parseStyles(Data(styles.utf8))
        let style = xfs[0].toCellStyle(customFormats: [:])
        #expect(style.fontSize == 409)
        #expect(style.indent == 250)
    }

    // MARK: XML rules the scanner must follow (#27)

    @Test func lineEndsAreNormalisedInText() {
        let body = "<sheetData><row r=\"1\"><c r=\"A1\" t=\"str\"><v>a\r\nb\rc</v></c>"
            + "<c r=\"B1\" t=\"inlineStr\"><is><t>x&#13;y\r\nz</t></is></c>"
            + "<c r=\"C1\"><f>1+\r\n2</f><v>3</v></c></row></sheetData>"
        let sheet = Self.bothAgree(Self.worksheet(body), "line ends")
        #expect(sheet?.cell(at: CellAddress(row: 0, column: 0)).value == .string("a\nb\nc"))
        #expect(sheet?.cell(at: CellAddress(row: 0, column: 1)).value == .string("x\ry\nz"))
        #expect(sheet?.cell(at: CellAddress(row: 0, column: 2)).formula == "1+\n2")
    }

    @Test func nonUTF8PartsReadLikeXMLParser() {
        var data = Data("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><worksheet xmlns=\"\(Self.main)\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>caf".utf8)
        data.append(0xE9)
        data.append(Data("</t></is></c></row></sheetData></worksheet>".utf8))
        let sheet = Self.bothAgree(data, "latin-1")
        #expect(sheet?.cell(at: CellAddress(row: 0, column: 0)).value == .string("café"))
    }

    // MARK: Progress and cancel on the XMLParser path (#27)

    static func bigSheet(rows: Int) -> Data {
        var body = "<sheetData>"
        for r in 1...rows { body += "<row r=\"\(r)\"><c r=\"A\(r)\"><v>\(r)</v></c><c r=\"B\(r)\" t=\"s\"><v>1</v></c></row>" }
        body += "</sheetData>"
        return worksheet(body)
    }

    @Test func xmlParserPathReportsProgressAndCancels() {
        let data = Self.bigSheet(rows: 30_000)
        let fractions = Locked<[Double]>([])
        let done = Self.parse(data, fast: false) { f in fractions.withValue { $0.append(f) }; return true }
        #expect(done.sheet?.cells.count == 60_000)
        let seen = fractions.value
        #expect(seen.contains { $0 > 0.2 && $0 < 0.9 }, "progress inside the parse: \(seen.prefix(20))")
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 <= $1 })

        let calls = Locked(0)
        let cancelled = Self.parse(data, fast: false) { _ in
            calls.withValue { $0 += 1 }
            return calls.value < 3
        }
        #expect(cancelled.sheet == nil)
        #expect((cancelled.error as? XLSXError) == .cancelled)
    }

    @Test func scannerFallbackAlsoCancels() {
        // A bad entity makes the scanner give up; the XMLParser fallback must still honour Cancel.
        var data = Self.bigSheet(rows: 30_000)
        data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<v>29999</v>", with: "<v>&bogus;</v>").utf8)
        let calls = Locked(0)
        let result = Self.parse(data, fast: true) { _ in
            calls.withValue { $0 += 1 }
            return calls.value < 4
        }
        #expect(result.sheet == nil)
        #expect(result.error != nil)
    }

    // MARK: Fuzz (truncations and mutations through both readers)

    static let fuzzBase = """
    <dimension ref="A1:F9"/><sheetViews><sheetView workbookViewId="0"><pane xSplit="1" ySplit="2" topLeftCell="B3" state="frozen"/></sheetView></sheetViews>\
    <sheetFormatPr defaultRowHeight="15"/><cols><col min="1" max="3" width="12.5" customWidth="1"/><col min="5" max="5" width="3" hidden="1" style="1"/></cols>\
    <sheetData><row r="1" ht="20" customHeight="1"><c r="A1" t="s"><v>1</v></c><c r="B1" s="1"><v>3.25</v></c><c r="C1" t="b"><v>1</v></c>\
    <c r="D1" t="e"><v>#N/A</v></c><c r="E1" t="d"><v>2026-03-04T12:30:00</v></c></row>\
    <row r="3" hidden="1"><c r="A3" t="str"><f>"a"&amp;"b"</f><v>ab</v></c><c r="B3" t="inlineStr"><is><r><t>rich </t></r><r><t xml:space="preserve">x &lt;&#x41;&gt;</t></r></is></c></row>\
    <row><c><v>10</v></c><c><v>-1.5E-3</v></c><c r="F4" s="2"/></row>\
    <row r="5"><c r="A5"><f t="shared" ref="A5:A7" si="0">B5*2</f><v>8</v></c><c r="B5"><v>4</v></c></row>\
    <row r="6"><c r="A6"><f t="shared" si="0"/><v>0</v></c></row><row r="7"><c r="A7"><f t="shared" si="0"></f></c></row>\
    <row r="8"><c r="A8" t="str"><v>line_x000D_break</v></c><c r="B8"><v>00012</v></c></row></sheetData>\
    <autoFilter ref="A1:C8"><filterColumn colId="0"><filters blank="1"><filter val="ab"/></filters></filterColumn></autoFilter>\
    <mergeCells count="1"><mergeCell ref="B8:C8"/></mergeCells><pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>
    """

    static func fixtureWorksheets(limit: Int) throws -> [Data] {
        let root = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "xlsx" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var sheets: [Data] = []
        for url in files {
            guard let zip = try? ZipArchiveReader(data: Data(contentsOf: url)) else { continue }
            for entry in zip.entries where entry.name.hasPrefix("xl/worksheets/") && entry.name.hasSuffix(".xml")
                && entry.uncompressedSize < 6_000 {
                if let data = try? zip.contents(of: entry) { sheets.append(data) }
                if sheets.count >= limit { return sheets }
            }
        }
        return sheets
    }

    @Test func fuzzedWorksheetsNeverCrashAndReadersAgree() throws {
        var bases = [Self.worksheet(Self.fuzzBase)]
        bases += try Self.fixtureWorksheets(limit: 4)
        #expect(Self.bothAgree(bases[0], "base") != nil)
        var rng = SplitMix64(seed: 0x5EED)
        var compared = 0
        let interesting: [UInt8] = Array("<>/\"'=&; \r\n\t09-.AZtdsnreE#x:".utf8) + [0xFF, 0xC3, 0x00]
        for base in bases {
            let bytes = [UInt8](base)
            // Truncations.
            let step = max(1, bytes.count / 300)
            for cut in stride(from: 0, to: bytes.count, by: step) {
                Self.bothAgree(Data(bytes[0..<cut]), "truncated at \(cut)")
            }
            // Point mutations, deletions and duplications.
            for _ in 0..<600 {
                var mutated = bytes
                let p = Int(rng.next() % UInt64(mutated.count))
                switch rng.next() % 4 {
                case 0, 1:
                    mutated[p] = interesting[Int(rng.next() % UInt64(interesting.count))]
                case 2:
                    let end = min(mutated.count, p + 1 + Int(rng.next() % 12))
                    mutated.removeSubrange(p..<end)
                default:
                    let end = min(mutated.count, p + 1 + Int(rng.next() % 24))
                    mutated.insert(contentsOf: mutated[p..<end], at: p)
                }
                if Self.bothAgree(Data(mutated), "mutation of \(base.count)-byte sheet: \(String(decoding: mutated, as: UTF8.self))") != nil {
                    compared += 1
                }
            }
        }
        // Many mutants are still well-formed, and those are compared.
        #expect(compared > 500, "\(compared) mutants read by both")
    }
}

/// Deterministic PRNG for the fuzz test.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A value the progress closures (which may be @Sendable) can update.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func withValue<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&stored) } }
}
