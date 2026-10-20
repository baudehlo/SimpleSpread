import Foundation
import SpreadsheetCore

public enum XLSError: Error, LocalizedError, Equatable {
    case invalidFile(String)
    case unsupportedVersion
    case encrypted
    case malformed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidFile(let message), .malformed(let message): return message
        case .unsupportedVersion: return "This XLS file uses an unsupported BIFF version."
        case .encrypted: return "Encrypted XLS workbooks are not supported."
        case .cancelled: return "The XLS import was cancelled."
        }
    }
}

/// Imports supported BIFF8 workbook content into the SimpleSpread model,
/// reporting content that cannot be preserved through `unsupportedContent`.
///
/// Records the importer doesn't use are skipped, as Excel's own readers do:
/// only damage to what is read (cells, strings, styles, the container) stops
/// the import. Content that is skipped but visible to the user (comments,
/// charts, hyperlinks, …) is named in `unsupportedContent`.
public enum XLSReader {
    private static let maxInputBytes = 256 * 1024 * 1024
    private static let maxStyleRecords = 100_000

    /// Listed first: the import keeps each formula's last value, not the formula.
    public static let formulasLabel = "formulas"
    /// Cell formatting the model has no place for.
    static let unsupportedStylesLabel = "some cell formatting (rotated text, pattern fills, diagonal borders)"

    public static func read(data: Data) throws -> Workbook {
        var unsupported: [String] = []
        return try read(data: data, unsupportedContent: &unsupported, progress: nil)
    }

    public static func read(data: Data, unsupportedContent: inout [String], progress: ((Double) -> Bool)? = nil) throws -> Workbook {
        guard progress?(0) ?? true else { throw XLSError.cancelled }
        guard data.count >= 512, data.count <= maxInputBytes else { throw XLSError.invalidFile("Invalid or oversized XLS file.") }
        let compound = try CompoundFileReader(data: data)
        guard let stream = try compound.stream(named: "Workbook") ?? compound.stream(named: "Book") else {
            throw XLSError.invalidFile("The compound file does not contain a Workbook stream.")
        }
        guard stream.count <= maxInputBytes else { throw XLSError.invalidFile("The Workbook stream is too large.") }
        var findings = Findings()
        if compound.storageNames.contains("_VBA_PROJECT_CUR") { findings.content.add(.macros) }
        if compound.storageNames.contains(where: { $0.hasPrefix("MBD") }) { findings.content.add(.embeddedObjects) }
        let workbook = try parseWorkbookStream(stream, findings: &findings, progress: progress)
        unsupportedContent = (findings.hasFormulas ? [formulasLabel] : [])
            + findings.content.descriptions
            + (findings.hasUnsupportedStyles ? [unsupportedStylesLabel] : [])
        guard progress?(1) ?? true else { throw XLSError.cancelled }
        return workbook
    }

    private struct BoundSheet { let offset: Int; let name: String; let hidden: Bool; let type: UInt8 }

    /// What the import leaves behind, for the warning shown on opening.
    private struct Findings {
        var content = UnsupportedContent()
        var hasFormulas = false
        var hasUnsupportedStyles = false
    }

    private static let bofTypes: Set<UInt16> = [0x0809, 0x0409, 0x0209]

    private static func parseWorkbookStream(_ stream: Data, findings: inout Findings,
                                            progress: ((Double) -> Bool)?) throws -> Workbook {
        var reader = BIFFRecordReader(stream)
        var styleRecords: [BIFFRecord] = []
        var bounds: [BoundSheet] = []
        var sst: [String] = []
        var date1904 = false
        var sawGlobalEOF = false
        var pendingRecord: BIFFRecord?
        var globalRecordCount = 0
        while true {
            let record: BIFFRecord
            if let pending = pendingRecord { record = pending; pendingRecord = nil }
            else { guard let next = try reader.next() else { break }; record = next }
            if globalRecordCount == 0 {
                guard bofTypes.contains(record.type), record.data.count >= 4,
                      try record.data.readU16(2) == 0x0005 else {
                    throw XLSError.malformed("Invalid Workbook globals BOF record.")
                }
                guard try record.data.readU16(0) == 0x0600 else { throw XLSError.unsupportedVersion }
            }
            globalRecordCount += 1
            if globalRecordCount % 256 == 0,
               !(progress?(Double(reader.offset) / Double(max(1, stream.count))) ?? true) {
                throw XLSError.cancelled
            }
            if record.type == 0x000A { sawGlobalEOF = true; break }
            switch record.type {
            case 0x002F: throw XLSError.encrypted
            case 0x0085:
                guard record.data.count >= 8 else { throw XLSError.malformed("Invalid BOUNDSHEET record.") }
                let offset = Int(try record.data.readU32(0))
                let sheetState = record.data[4] & 0x03
                let sheetType = record.data[5]
                let length = Int(record.data[6]); let wide = record.data[7] & 1 != 0
                let bytes = length * (wide ? 2 : 1)
                guard record.data.count >= 8 + bytes else { throw XLSError.malformed("Truncated BOUNDSHEET name.") }
                let nameData = record.data.subdata(in: 8..<(8 + bytes))
                let name = wide
                    ? String(decoding: stride(from: 0, to: bytes, by: 2).map { UInt16(nameData[$0]) | UInt16(nameData[$0 + 1]) << 8 }, as: UTF16.self)
                    : BIFFString.decodeCompressed(Array(nameData))
                switch sheetType {
                case 0: if sheetState == 2 { findings.content.add(.veryHiddenSheets) }
                case 2: findings.content.add(.chartSheets)
                case 1, 6: findings.content.add(.macros)
                default: break
                }
                bounds.append(BoundSheet(offset: offset, name: name, hidden: sheetState != 0, type: sheetType))
            case 0x00FC:
                // The table runs on through the CONTINUE records after it.
                var segments = [record.data]
                while let continuation = try reader.next() {
                    guard continuation.type == 0x003C else { pendingRecord = continuation; break }
                    globalRecordCount += 1
                    segments.append(continuation.data)
                }
                let sharedStrings = try parseSST(segments)
                sst = sharedStrings.strings
                if sharedStrings.hasRichText { findings.content.add(.richText) }
            case 0x0022:
                guard record.data.count >= 2 else { throw XLSError.malformed("Invalid DATEMODE record.") }
                date1904 = try record.data.readU16(0) == 1
            case 0x0012:
                if record.data.count >= 2, try record.data.readU16(0) != 0 { findings.content.add(.workbookProtection) }
            case 0x01AE:
                // SUPBOOK: 0x0401 is this workbook, 0x3A01 add-in functions; others are other files.
                if record.data.count >= 4, ![UInt16(0x0401), 0x3A01].contains(try record.data.readU16(2)) {
                    findings.content.add(.externalLinks)
                }
            case 0x00D3: findings.content.add(.macros) // OBJPROJ
            case 0x0031, 0x041E, 0x00E0, 0x0092:
                guard styleRecords.count < maxStyleRecords else {
                    throw XLSError.invalidFile("The Workbook has too many style records.")
                }
                styleRecords.append(record)
            default: break // CONTINUE of a skipped record, or a record not imported
            }
        }
        guard sawGlobalEOF else { throw XLSError.malformed("The Workbook globals substream is missing EOF.") }
        let physicalOrder = bounds.indices.sorted { bounds[$0].offset < bounds[$1].offset }
        let physicalOffsets = physicalOrder.map { bounds[$0].offset }
        guard offsetsAreAscending(physicalOffsets) else { throw XLSError.malformed("Invalid worksheet stream offsets.") }
        let styles = try XLSStyleCatalog.parse(styleRecords)
        let workbook = Workbook()
        var styleIndexes: [Int] = []
        styleIndexes.reserveCapacity(styles.xfs.count)
        for index in 0..<styles.xfs.count { styleIndexes.append(workbook.styleIndex(for: styles.cellStyle(index))) }
        let worksheetIndices = bounds.indices.filter { bounds[$0].type == 0 }
        guard !worksheetIndices.isEmpty else { throw XLSError.malformed("The workbook contains no worksheets.") }
        for (sheetIndex, boundIndex) in worksheetIndices.enumerated() {
            let bound = bounds[boundIndex]
            guard bound.offset >= 0, bound.offset < stream.count else { throw XLSError.malformed("Invalid worksheet stream offset.") }
            let sheet = workbook.addSheet(named: bound.name)
            sheet.isHidden = bound.hidden
            let orderPosition = physicalOrder.firstIndex(of: boundIndex)!
            let end = orderPosition + 1 < physicalOrder.count ? bounds[physicalOrder[orderPosition + 1]].offset : stream.count
            guard end > bound.offset, end <= stream.count else { throw XLSError.malformed("Invalid worksheet stream boundary.") }
            let sheetProgress: ((Double) -> Bool)? = progress.map { callback in
                { fraction in callback((Double(sheetIndex) + fraction) / Double(worksheetIndices.count)) }
            }
            try parseSheet(stream.subdata(in: bound.offset..<end), into: sheet,
                           strings: sst, styleIndexes: styleIndexes, unsupportedXFs: styles.unsupportedXFs,
                           progress: sheetProgress, findings: &findings)
        }
        if date1904 {
            for sheet in workbook.sheets {
                for (address, cell) in sheet.cells where workbook.style(at: cell.styleIndex).numberFormat.isDateTime {
                    if case .number(let value) = cell.value {
                        var shifted = cell; shifted.value = .number(value + ExcelDate.date1904Offset); sheet.setCell(shifted, at: address)
                    }
                }
            }
        }
        return workbook
    }

    private static func parseSheet(_ data: Data, into sheet: Sheet, strings: [String],
                                   styleIndexes: [Int], unsupportedXFs: Set<Int>, progress: ((Double) -> Bool)?,
                                   findings: inout Findings) throws {
        var reader = BIFFRecordReader(data)
        var pendingFormulaString: CellAddress?
        var pendingRecord: BIFFRecord?
        var sawEOF = false
        var recordCount = 0
        var paneSplit: (columns: Int, rows: Int)?
        var frozenPane = false
        var nestedSubstreamDepth = 0
        var defaultRowTwips: UInt16 = 255 // 12.75 pt until DEFAULTROWHEIGHT says otherwise
        /// The model style for an XF index; one out of range falls back to the default.
        func style(_ xf: Int) -> Int {
            if !unsupportedXFs.isEmpty, unsupportedXFs.contains(xf) { findings.hasUnsupportedStyles = true }
            return styleIndexes.indices.contains(xf) ? styleIndexes[xf] : 0
        }
        func put(_ value: CellValue, at address: CellAddress, xf: Int) {
            var cell = Cell(value: value); cell.styleIndex = style(xf)
            sheet.setCell(cell, at: address)
        }
        sheetRecords: while true {
            let record: BIFFRecord
            if let pending = pendingRecord { record = pending; pendingRecord = nil }
            else { guard let next = try reader.next() else { break }; record = next }
            recordCount += 1
            if recordCount % 256 == 0, !(progress?(Double(reader.offset) / Double(max(1, data.count))) ?? true) {
                throw XLSError.cancelled
            }
            let d = record.data
            if recordCount == 1 {
                guard bofTypes.contains(record.type), d.count >= 4,
                      try d.readU16(0) == 0x0600, try d.readU16(2) == 0x0010 else {
                    throw XLSError.malformed("Invalid worksheet BOF record.")
                }
                continue
            }
            if nestedSubstreamDepth > 0 {
                if bofTypes.contains(record.type) { nestedSubstreamDepth += 1 }
                if record.type == 0x000A { nestedSubstreamDepth -= 1 }
                continue
            }
            // A string-valued FORMULA is followed by its STRING record, after any
            // shared-formula, array or data-table record that belongs to it.
            if pendingFormulaString != nil, ![UInt16(0x0207), 0x04BC, 0x0221, 0x0236].contains(record.type) {
                pendingFormulaString = nil
            }
            if bofTypes.contains(record.type) {
                // An embedded chart's substream.
                if d.count >= 4, try d.readU16(2) == 0x0020 { findings.content.add(.charts) }
                nestedSubstreamDepth = 1
                continue
            }
            switch record.type {
            case 0x000A: sawEOF = true; break sheetRecords
            case 0x0203:
                guard d.count >= 14 else { throw XLSError.malformed("Invalid NUMBER record.") }
                put(.number(try d.readDouble(6)), at: try cellAddress(d), xf: Int(try d.readU16(4)))
            case 0x027E:
                guard d.count >= 10 else { throw XLSError.malformed("Invalid RK record.") }
                put(.number(decodedRK(try d.readU32(6))), at: try cellAddress(d), xf: Int(try d.readU16(4)))
            case 0x00BD:
                guard d.count >= 6 else { throw XLSError.malformed("Invalid MULRK record.") }
                let row = Int(try d.readU16(0))
                let firstColumn = Int(try d.readU16(2))
                let lastColumn = Int(try d.readU16(d.count - 2))
                guard lastColumn >= firstColumn,
                      d.count == 6 + (lastColumn - firstColumn + 1) * 6 else {
                    throw XLSError.malformed("Invalid MULRK range.")
                }
                for column in firstColumn...lastColumn {
                    let position = 4 + (column - firstColumn) * 6
                    let address = CellAddress(row: row, column: column)
                    guard address.isValid else { throw XLSError.malformed("Cell reference is out of range.") }
                    put(.number(decodedRK(try d.readU32(position + 2))), at: address, xf: Int(try d.readU16(position)))
                }
            case 0x00FD:
                guard d.count >= 10 else { throw XLSError.malformed("Invalid LABELSST record.") }
                let index = Int(try d.readU32(6)); guard strings.indices.contains(index) else { throw XLSError.malformed("Invalid shared string index.") }
                put(.string(strings[index]), at: try cellAddress(d), xf: Int(try d.readU16(4)))
            case 0x0204:
                guard d.count >= 8 else { throw XLSError.malformed("Invalid LABEL record.") }
                let string = try BIFFString.read(d, at: 6)
                put(.string(string.text), at: try cellAddress(d), xf: Int(try d.readU16(4)))
            case 0x0205:
                guard d.count >= 8 else { throw XLSError.malformed("Invalid BOOLERR record.") }
                let value: CellValue
                if d[7] == 0 {
                    value = .bool(d[6] != 0)
                } else {
                    value = .error(error(d[6]) ?? .na)
                }
                put(value, at: try cellAddress(d), xf: Int(try d.readU16(4)))
            case 0x0201:
                guard d.count >= 6 else { throw XLSError.malformed("Invalid BLANK record.") }
                put(.empty, at: try cellAddress(d), xf: Int(try d.readU16(4)))
            case 0x00BE:
                guard d.count >= 6 else { throw XLSError.malformed("Invalid MULBLANK record.") }
                let row = Int(try d.readU16(0))
                let firstColumn = Int(try d.readU16(2))
                let lastColumn = Int(try d.readU16(d.count - 2))
                guard lastColumn >= firstColumn,
                      d.count == 6 + (lastColumn - firstColumn + 1) * 2 else {
                    throw XLSError.malformed("Invalid MULBLANK range.")
                }
                for column in firstColumn...lastColumn {
                    let address = CellAddress(row: row, column: column)
                    guard address.isValid else { throw XLSError.malformed("Cell reference is out of range.") }
                    put(.empty, at: address, xf: Int(try d.readU16(4 + (column - firstColumn) * 2)))
                }
            case 0x0006, 0x0406: // FORMULA (0x0406 from some old writers): import the cached value
                guard d.count >= 14 else { throw XLSError.malformed("Invalid FORMULA record.") }
                let addr = try cellAddress(d); let value: CellValue
                if d[12] == 0xFF && d[13] == 0xFF {
                    switch d[6] {
                    case 0: value = .string(""); pendingFormulaString = addr
                    case 1: value = .bool(d[8] != 0)
                    case 2: value = .error(error(d[8]) ?? .na)
                    default: value = .empty
                    }
                } else { value = .number(try d.readDouble(6)) }
                put(value, at: addr, xf: Int(try d.readU16(4)))
                findings.hasFormulas = true
            case 0x0207:
                // A STRING with no string-valued FORMULA before it is ignored.
                guard let address = pendingFormulaString, d.count >= 3 else { break }
                var segments = [d]
                while let continuation = try reader.next() {
                    guard continuation.type == 0x003C else { pendingRecord = continuation; break }
                    segments.append(continuation.data)
                }
                var cursor = BIFFSSTCursor(segments)
                let value = try cursor.readString()
                if cursor.hasRichText { findings.content.add(.richText) }
                var cell = sheet.cell(at: address)
                cell.value = .string(value)
                sheet.setCell(cell, at: address)
                pendingFormulaString = nil
            case 0x00E5:
                guard d.count >= 2 else { throw XLSError.malformed("Invalid MERGEDCELLS record.") }
                let count = Int(try d.readU16(0))
                guard d.count >= 2 + count * 8 else { throw XLSError.malformed("Invalid MERGEDCELLS ranges.") }
                for index in 0..<count {
                    let position = 2 + index * 8
                    let range = CellRange(
                        start: CellAddress(row: Int(try d.readU16(position)), column: Int(try d.readU16(position + 4))),
                        end: CellAddress(row: Int(try d.readU16(position + 2)), column: Int(try d.readU16(position + 6))))
                    if range.start.isValid && range.end.isValid && !range.isSingleCell { sheet.mergedRanges.append(range) }
                }
            case 0x007D:
                guard d.count >= 10 else { throw XLSError.malformed("Invalid COLINFO record.") }
                let first = Int(try d.readU16(0))
                let last = min(Int(try d.readU16(2)), CellAddress.maxColumns - 1)
                // 1/256ths of a character -> pixels (as the XLSX reader) -> points.
                let width = (Double(try d.readU16(4)) * 7 / 256 + 5) * 0.75
                let xf = Int(try d.readU16(6))
                let flags = try d.readU16(8)
                guard first <= last else { break }
                if (flags >> 8) & 0x07 != 0 { findings.content.add(.outlines) }
                for column in first...last {
                    sheet.columnWidths[column] = CGFloat(width)
                    if flags & 1 != 0 { sheet.hiddenColumns.insert(column) }
                    if xf > 15 { sheet.columnStyles[column] = style(xf) } // 15 is the default cell XF
                }
            case 0x0208:
                guard d.count >= 16 else { throw XLSError.malformed("Invalid ROW record.") }
                let row = Int(try d.readU16(0))
                let rawHeight = try d.readU16(6)
                let flags = try d.readU16(12)
                guard row < CellAddress.maxRows else { throw XLSError.malformed("Invalid row index.") }
                // Every row with cells has a ROW record; like Excel's XLSX writer, keep a
                // height only when it is custom or differs from the sheet's default.
                let height = rawHeight & 0x7FFF
                if rawHeight & 0x8000 == 0, flags & 0x40 != 0 || height != defaultRowTwips {
                    sheet.rowHeights[row] = CGFloat(height) / 20
                }
                if flags & 0x20 != 0 { sheet.hiddenRows.insert(row) }
                if flags & 0x07 != 0 { findings.content.add(.outlines) }
                // The row's XF applies only when fGhostDirty says the row is formatted.
                if flags & 0x80 != 0 { sheet.rowStyles[row] = style(Int(try d.readU16(14)) & 0x0FFF) }
            case 0x0055:
                guard d.count >= 2 else { throw XLSError.malformed("Invalid DEFCOLWIDTH record.") }
                sheet.defaultColumnWidth = CGFloat(Double(Int(try d.readU16(0)) * 7 + 5) * 0.75)
            case 0x0225:
                guard d.count >= 4 else { throw XLSError.malformed("Invalid DEFAULTROWHEIGHT record.") }
                // Scaled as the XLSX reader scales defaultRowHeight (Excel's 15 pt is 22).
                defaultRowTwips = try d.readU16(2)
                sheet.defaultRowHeight = CGFloat(max(12, Double(defaultRowTwips) / 20 * 22 / 15))
            case 0x0041:
                guard d.count >= 4 else { throw XLSError.malformed("Invalid PANE record.") }
                let columns = Int(try d.readU16(0)), rows = Int(try d.readU16(2))
                if rows < CellAddress.maxRows, columns < CellAddress.maxColumns { paneSplit = (columns, rows) }
            case 0x023E:
                guard d.count >= 2 else { throw XLSError.malformed("Invalid WINDOW2 record.") }
                frozenPane = try d.readU16(0) & 0x0008 != 0
            // Content that isn't imported, named in the warning.
            case 0x001C: findings.content.add(.comments) // NOTE
            case 0x005D: // OBJ: its first subrecord (ftCmo) gives the object type
                if d.count >= 6, try d.readU16(0) == 0x0015 {
                    switch try d.readU16(4) {
                    case 0x08: findings.content.add(.images)
                    case 0x05, 0x19: break // charts and comments are counted from their own records
                    case 0x07, 0x0B, 0x0C, 0x0E, 0x10, 0x11, 0x12, 0x13, 0x14: findings.content.add(.formControls)
                    default: findings.content.add(.drawings)
                    }
                }
            case 0x01B8: findings.content.add(.hyperlinks)
            case 0x01BE: findings.content.add(.dataValidation)
            case 0x01B0, 0x0879: findings.content.add(.conditionalFormatting)
            case 0x00B0: findings.content.add(.pivotTables) // SXVIEW
            case 0x0012:
                if d.count >= 2, try d.readU16(0) != 0 { findings.content.add(.sheetProtection) }
            case 0x0014, 0x0015:
                if d.count > 3 { findings.content.add(.printSettings) } // a non-empty header or footer
            default: break // CONTINUE of a skipped record, or a record not imported
            }
        }
        guard sawEOF else { throw XLSError.malformed("The worksheet substream is missing EOF.") }
        if frozenPane, let paneSplit {
            sheet.frozenColumns = paneSplit.columns
            sheet.frozenRows = paneSplit.rows
        }
    }

    private static func cellAddress(_ data: Data) throws -> CellAddress {
        guard data.count >= 6 else { throw XLSError.malformed("Truncated cell record.") }
        let address = CellAddress(row: Int(try data.readU16(0)), column: Int(try data.readU16(2)))
        guard address.isValid else { throw XLSError.malformed("Cell reference is out of range.") }
        return address
    }

    private static func error(_ code: UInt8) -> CellError? {
        switch code { case 0x00: return .null; case 0x07: return .div0; case 0x0F: return .value; case 0x17: return .ref; case 0x1D: return .name; case 0x24: return .num; case 0x2A: return .na; default: return nil }
    }

    private static func decodedRK(_ raw: UInt32) -> Double {
        let value = raw & 2 != 0
            ? Double(Int32(bitPattern: raw) >> 2)
            : Double(bitPattern: UInt64(raw & 0xFFFFFFFC) << 32)
        return raw & 1 != 0 ? value / 100 : value
    }

    private static func parseSST(_ segments: [Data]) throws -> (strings: [String], hasRichText: Bool) {
        guard let data = segments.first else { throw XLSError.malformed("Invalid SST record.") }
        guard data.count >= 8 else { throw XLSError.malformed("Invalid SST record.") }
        let count = Int(try data.readU32(4)); guard count <= 2_000_000 else { throw XLSError.invalidFile("The shared string table is too large.") }
        var cursor = BIFFSSTCursor(segments)
        try cursor.skip(8)
        var strings: [String] = []; strings.reserveCapacity(count)
        for _ in 0..<count { strings.append(try cursor.readString()) }
        return (strings, cursor.hasRichText)
    }

    private static func offsetsAreAscending(_ offsets: [Int]) -> Bool {
        zip(offsets, offsets.dropFirst()).allSatisfy { pair in pair.0 < pair.1 }
    }
}

private extension Data {
    func readDouble(_ offset: Int) throws -> Double {
        guard offset >= 0, count - offset >= 8 else { throw XLSError.malformed("Truncated floating point value.") }
        var bits: UInt64=0
        for index in 0..<8 { bits |= UInt64(self[offset+index]) << (index*8) }
        return Double(bitPattern: bits)
    }
}
