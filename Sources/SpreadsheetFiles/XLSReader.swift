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

/// 将 BIFF8 工作簿的有限内容读入 SimpleSpread 模型；未承载的内容会通过 unsupportedContent 报告。
public enum XLSReader {
    private static let maxInputBytes = 256 * 1024 * 1024
    private static let maxCells = 1_000_000
    private static let maxRecords = 1_000_000
    private static let maxStyleRecords = 100_000

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
        let parsed = try parseWorkbookStream(stream, progress: progress)
        var warnings = parsed.unsupported
        let knownStreamNames = Set(["Root Entry", "Workbook", "Book"])
        if compound.streamNames.contains(where: { !knownStreamNames.contains($0) }) {
            warnings.append("additional compound streams")
        }
        unsupportedContent = warnings.sorted()
        guard progress?(1) ?? true else { throw XLSError.cancelled }
        return parsed.workbook
    }

    private struct BoundSheet { let offset: Int; let name: String; let hidden: Bool; let type: UInt8 }
    private struct ParseResult { let workbook: Workbook; let unsupported: [String] }

    private static func parseWorkbookStream(_ stream: Data, progress: ((Double) -> Bool)?) throws -> ParseResult {
        var reader = BIFFRecordReader(stream)
        var styleRecords: [BIFFRecord] = []
        var globalRecordTypes = Set<UInt16>()
        var bounds: [BoundSheet] = []
        var sst: [String] = []
        var date1904 = false
        var sawBOF = false
        var sawGlobalEOF = false
        var unsupported = Set<String>()
        var pendingRecord: BIFFRecord?
        var globalRecordCount = 0
        var firstGlobalRecord = true
        while true {
            let record: BIFFRecord
            if let pending = pendingRecord { record = pending; pendingRecord = nil }
            else { guard let next = try reader.next() else { break }; record = next }
            globalRecordTypes.insert(record.type)
            if firstGlobalRecord {
                guard [UInt16(0x0809),0x0409,0x0209].contains(record.type),
                      record.data.count >= 4, try record.data.readU16(2) == 0x0005 else {
                    throw XLSError.malformed("Invalid Workbook globals BOF record.")
                }
                firstGlobalRecord = false
            }
            globalRecordCount += 1
            guard globalRecordCount <= maxRecords else {
                throw XLSError.invalidFile("The Workbook stream has too many records.")
            }
            if globalRecordCount % 256 == 0,
               !(progress?(Double(reader.offset) / Double(max(1, stream.count))) ?? true) {
                throw XLSError.cancelled
            }
            if record.type == 0x000A { sawGlobalEOF = true; break }
            switch record.type {
            case 0x0809, 0x0409, 0x0209:
                guard record.data.count >= 4 else { throw XLSError.malformed("Invalid BOF record.") }
                let version = try record.data.readU16(0)
                guard version == 0x0600 else { throw XLSError.unsupportedVersion }
                sawBOF = true
                if try record.data.readU16(2) != 0x0005 { unsupported.insert("non-worksheet substreams") }
            case 0x002F: throw XLSError.encrypted
            case 0x0085:
                guard record.data.count >= 8 else { throw XLSError.malformed("Invalid BOUNDSHEET record.") }
                let offset = Int(try record.data.readU32(0))
                let sheetState = record.data[4]
                let sheetType = record.data[5]
                guard sheetState <= 2, [UInt8(0),1,2,6].contains(sheetType) else {
                    throw XLSError.malformed("Invalid BOUNDSHEET state or type.")
                }
                let hidden = sheetState != 0
                let length = Int(record.data[6]); let wide = record.data[7] & 1 != 0
                let bytes = length * (wide ? 2 : 1)
                guard record.data.count >= 8 + bytes else { throw XLSError.malformed("Truncated BOUNDSHEET name.") }
                let nameData = record.data.subdata(in: 8..<(8 + bytes))
                let name = wide
                    ? String(decoding: stride(from: 0, to: bytes, by: 2).map { UInt16(nameData[$0]) | UInt16(nameData[$0 + 1]) << 8 }, as: UTF16.self)
                    : BIFFString.decodeCompressed(Array(nameData))
                bounds.append(BoundSheet(offset: offset, name: name, hidden: hidden, type: sheetType))
            case 0x00FC:
                var segments = [record.data]
                while let continuation = try reader.next() {
                    guard continuation.type == 0x003C else { pendingRecord = continuation; break }
                    globalRecordTypes.insert(continuation.type)
                    globalRecordCount += 1
                    guard globalRecordCount <= maxRecords else {
                        throw XLSError.invalidFile("The Workbook stream has too many records.")
                    }
                    segments.append(continuation.data)
                }
                let sharedStrings = try parseSST(segments)
                sst = sharedStrings.strings
                if sharedStrings.hasRichText { unsupported.insert("rich text formatting") }
            case 0x003C: throw XLSError.malformed("Unexpected SST CONTINUE record.")
            case 0x0022:
                guard record.data.count >= 2 else { throw XLSError.malformed("Invalid DATEMODE record.") }
                date1904 = try record.data.readU16(0) == 1
            case 0x0006: unsupported.insert("formula text (only cached values are imported)")
            case 0x0014, 0x0015:
                unsupported.insert("print settings")
            case 0x005D, 0x00EB, 0x00EC, 0x00ED, 0x01B6:
                unsupported.insert("charts and drawing objects")
            default: break
            }
            if [UInt16(0x0031),0x041E,0x00E0,0x0092].contains(record.type) {
                guard styleRecords.count < maxStyleRecords else {
                    throw XLSError.invalidFile("The Workbook has too many style records.")
                }
                styleRecords.append(record)
            }
        }
        guard sawGlobalEOF else { throw XLSError.malformed("The Workbook globals substream is missing EOF.") }
        guard sawBOF, !bounds.isEmpty else { throw XLSError.malformed("The Workbook stream has no BIFF8 worksheets.") }
        let knownGlobals: Set<UInt16> = [0x0809,0x0409,0x0209,0x000A,0x0042,0x003D,0x0022,0x0085,0x0031,0x041E,0x00E0,0x0092,0x00FC,0x003C,0x00FF,0x0293,0x008C,0x0017,0x0019,0x0012,0x0013,0x0014,0x0015,0x005D,0x0063]
        if !globalRecordTypes.isSubset(of: knownGlobals) {
            unsupported.insert("unsupported workbook records")
        }
        let physicalOrder = bounds.indices.sorted { bounds[$0].offset < bounds[$1].offset }
        let physicalOffsets = physicalOrder.map { bounds[$0].offset }
        guard offsetsAreAscending(physicalOffsets) else { throw XLSError.malformed("Invalid worksheet stream offsets.") }
        let styles = try XLSStyleCatalog.parse(styleRecords)
        if styles.hasUnsupportedFeatures { unsupported.insert("unsupported styles") }
        let workbook = Workbook()
        var styleIndexes: [Int: Int] = [:]
        for index in 0..<styles.xfs.count { styleIndexes[index] = workbook.styleIndex(for: styles.cellStyle(index)) }
        var cellCount = 0
        let worksheetIndices = bounds.indices.filter { bounds[$0].type == 0 }
        if worksheetIndices.count != bounds.count { unsupported.insert("non-worksheet streams") }
        guard !worksheetIndices.isEmpty else { throw XLSError.malformed("The workbook contains no worksheet streams.") }
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
            try parseSheet(stream.subdata(in: bound.offset..<end), into: sheet, workbook: workbook,
                           strings: sst, styles: styles, styleIndexes: styleIndexes,
                           progress: sheetProgress, cellCount: &cellCount, unsupported: &unsupported)
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
        return ParseResult(workbook: workbook, unsupported: unsupported.sorted())
    }

    private static func parseSheet(_ data: Data, into sheet: Sheet, workbook: Workbook, strings: [String], styles: XLSStyleCatalog,
                                   styleIndexes: [Int: Int], progress: ((Double) -> Bool)?,
                                   cellCount: inout Int, unsupported: inout Set<String>) throws {
        var reader = BIFFRecordReader(data)
        var recordTypes = Set<UInt16>()
        var pendingFormulaString: CellAddress?
        var pendingRecord: BIFFRecord?
        var firstRecord = true
        var sawEOF = false
        var recordCount = 0
        var paneSplit: (columns: Int, rows: Int)?
        var frozenPane = false
        var nestedSubstreamDepth = 0
        sheetRecords: while true {
            let record: BIFFRecord
            if let pending = pendingRecord { record = pending; pendingRecord = nil }
            else { guard let next = try reader.next() else { break }; record = next }
            recordCount += 1
            guard recordCount <= maxRecords else {
                throw XLSError.invalidFile("A worksheet has too many records.")
            }
            if recordCount % 256 == 0, !(progress?(Double(reader.offset) / Double(max(1, data.count))) ?? true) {
                throw XLSError.cancelled
            }
            recordTypes.insert(record.type)
            let d = record.data
            if firstRecord {
                guard [UInt16(0x0809),0x0409,0x0209].contains(record.type), d.count >= 4,
                      try d.readU16(0) == 0x0600, try d.readU16(2) == 0x0010 else {
                    throw XLSError.malformed("Invalid worksheet BOF record.")
                }
                firstRecord = false
            }
            if pendingFormulaString != nil && record.type != 0x0207 {
                throw XLSError.malformed("Formula STRING record is missing or displaced.")
            }
            if nestedSubstreamDepth > 0 {
                if [UInt16(0x0809),0x0409,0x0209].contains(record.type) { nestedSubstreamDepth += 1 }
                if record.type == 0x000A { nestedSubstreamDepth -= 1 }
                continue
            }
            if [UInt16(0x0809),0x0409,0x0209].contains(record.type), recordCount > 1 {
                guard d.count >= 4, try d.readU16(0) == 0x0600 else { throw XLSError.malformed("Invalid nested BIFF BOF record.") }
                if try d.readU16(2) == 0x0020 { unsupported.insert("charts and drawing objects") }
                else { unsupported.insert("nested BIFF substreams") }
                nestedSubstreamDepth = 1
                continue
            }
            switch record.type {
            case 0x000A: sawEOF = true; break sheetRecords
            case 0x0203:
                guard d.count == 14 else { throw XLSError.malformed("Invalid NUMBER record.") }
                let address = try cellAddress(d)
                try put(.number(try d.readDouble(6)), at: address, xf: Int(try d.readU16(4)),
                        sheet: sheet, workbook: workbook, styleIndexes: styleIndexes, count: &cellCount)
            case 0x027E:
                guard d.count == 10 else { throw XLSError.malformed("Invalid RK record.") }
                let value = decodedRK(try d.readU32(6))
                try put(.number(value), at: try cellAddress(d), xf: Int(try d.readU16(4)),
                        sheet: sheet, workbook: workbook, styleIndexes: styleIndexes, count: &cellCount)
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
                    let rk = try d.readU32(position + 2)
                    let number = decodedRK(rk)
                    try put(.number(number), at: CellAddress(row: row, column: column),
                            xf: Int(try d.readU16(position)), sheet: sheet, workbook: workbook,
                            styleIndexes: styleIndexes, count: &cellCount)
                }
            case 0x00FD:
                guard d.count == 10 else { throw XLSError.malformed("Invalid LABELSST record.") }
                let index = Int(try d.readU32(6)); guard strings.indices.contains(index) else { throw XLSError.malformed("Invalid shared string index.") }
                try put(.string(strings[index]), at: try cellAddress(d), xf: Int(try d.readU16(4)),
                        sheet: sheet, workbook: workbook, styleIndexes: styleIndexes, count: &cellCount)
            case 0x0204:
                guard d.count >= 8 else { throw XLSError.malformed("Invalid LABEL record.") }
                let string = try BIFFString.read(d, at: 6)
                try put(.string(string.text), at: try cellAddress(d), xf: Int(try d.readU16(4)),
                        sheet: sheet, workbook: workbook, styleIndexes: styleIndexes, count: &cellCount)
            case 0x0205:
                guard d.count == 8 else { throw XLSError.malformed("Invalid BOOLERR record.") }
                let value: CellValue
                if d[7] == 0 {
                    guard d[6] <= 1 else { throw XLSError.malformed("Invalid BOOLERR boolean.") }
                    value = .bool(d[6] != 0)
                } else {
                    guard d[7] == 1, let parsed = error(d[6]) else { throw XLSError.malformed("Invalid BOOLERR error.") }
                    value = .error(parsed)
                }
                try put(value, at: try cellAddress(d), xf: Int(try d.readU16(4)),
                        sheet: sheet, workbook: workbook, styleIndexes: styleIndexes, count: &cellCount)
            case 0x0201:
                guard d.count >= 6 else { throw XLSError.malformed("Invalid BLANK record.") }
                try put(.empty, at: try cellAddress(d), xf: Int(try d.readU16(4)),
                        sheet: sheet, workbook: workbook, styleIndexes: styleIndexes, count: &cellCount)
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
                    let styleOffset = 4 + (column - firstColumn) * 2
                    try put(.empty, at: CellAddress(row: row, column: column),
                            xf: Int(try d.readU16(styleOffset)), sheet: sheet, workbook: workbook,
                            styleIndexes: styleIndexes, count: &cellCount)
                }
            case 0x0006:
                guard d.count >= 14 else { throw XLSError.malformed("Invalid FORMULA record.") }
                let addr = try cellAddress(d); let value: CellValue
                let cache = d.subdata(in: 6..<14)
                if cache[6] == 0xFF && cache[7] == 0xFF {
                    switch cache[0] {
                    case 0: value = .string(""); pendingFormulaString = addr
                    case 1:
                        guard cache[2] <= 1 else { throw XLSError.malformed("Invalid cached formula boolean.") }
                        value = .bool(cache[2] != 0)
                    case 2: guard let parsed = error(cache[2]) else { throw XLSError.malformed("Invalid cached formula error.") }; value = .error(parsed)
                    case 3: value = .empty
                    default: throw XLSError.malformed("Invalid cached formula value type.")
                    }
                } else { value = .number(try d.readDouble(6)) }
                try put(value, at: addr, xf: Int(try d.readU16(4)), sheet: sheet, workbook: workbook,
                        styleIndexes: styleIndexes, count: &cellCount)
                unsupported.insert("formula text (only cached values are imported)")
            case 0x0207:
                guard d.count >= 3, let address = pendingFormulaString else { throw XLSError.malformed("Unexpected formula STRING record.") }
                var segments = [d]
                while let continuation = try reader.next() {
                    guard continuation.type == 0x003C else { pendingRecord = continuation; break }
                    recordTypes.insert(continuation.type)
                    segments.append(continuation.data)
                }
                var cursor = BIFFSSTCursor(segments)
                let value = try cursor.readString()
                if cursor.hasRichText { unsupported.insert("rich text formatting") }
                var cell = sheet.cell(at: address)
                cell.value = .string(value)
                sheet.setCell(cell, at: address)
                pendingFormulaString = nil
            case 0x003C: throw XLSError.malformed("Unexpected worksheet CONTINUE record.")
            case 0x00E5:
                guard d.count >= 2 else { throw XLSError.malformed("Invalid MERGEDCELLS record.") }
                let count = Int(try d.readU16(0))
                guard d.count == 2 + count * 8 else { throw XLSError.malformed("Invalid MERGEDCELLS ranges.") }
                for index in 0..<count {
                    let position = 2 + index * 8
                    let range = CellRange(
                        start: CellAddress(row: Int(try d.readU16(position)), column: Int(try d.readU16(position + 4))),
                        end: CellAddress(row: Int(try d.readU16(position + 2)), column: Int(try d.readU16(position + 6))))
                    guard range.start.isValid && range.end.isValid else {
                        throw XLSError.malformed("Invalid merged cell reference.")
                    }
                    sheet.mergedRanges.append(range)
                }
            case 0x007D:
                guard d.count >= 10 else { throw XLSError.malformed("Invalid COLINFO record.") }
                let first = Int(try d.readU16(0))
                let last = Int(try d.readU16(2))
                let width = Double(try d.readU16(4)) * 7 / 256 + 5
                let xf = Int(try d.readU16(6))
                let flags = try d.readU16(8)
                guard first <= last, last < CellAddress.maxColumns else { throw XLSError.malformed("Invalid column range.") }
                if xf > 0, let styleIndex = styleIndexes[xf] {
                    for column in first...last { sheet.columnStyles[column] = styleIndex }
                } else if xf > 0 { throw XLSError.malformed("Invalid column style index.") }
                for column in first...last {
                    sheet.columnWidths[column] = CGFloat(width)
                    if flags & 1 != 0 { sheet.hiddenColumns.insert(column) }
                }
            case 0x0208:
                guard d.count >= 16 else { throw XLSError.malformed("Invalid ROW record.") }
                let row = Int(try d.readU16(0))
                let height = Int(try d.readU16(6)) & 0x7FFF
                let flags = try d.readU16(12)
                let xf = Int(try d.readU16(14)) & 0x0FFF
                guard row < CellAddress.maxRows else { throw XLSError.malformed("Invalid row index.") }
                sheet.rowHeights[row] = CGFloat(height) / 20
                if flags & 0x20 != 0 { sheet.hiddenRows.insert(row) }
                if xf > 0, let styleIndex = styleIndexes[xf] { sheet.rowStyles[row] = styleIndex }
                else if xf > 0 { throw XLSError.malformed("Invalid row style index.") }
            case 0x0055:
                guard d.count == 2 else { throw XLSError.malformed("Invalid DEFCOLWIDTH record.") }
                sheet.defaultColumnWidth = CGFloat(Int(try d.readU16(0)) * 7 + 5)
            case 0x0225:
                guard d.count == 4 else { throw XLSError.malformed("Invalid DEFAULTROWHEIGHT record.") }
                sheet.defaultRowHeight = CGFloat(try d.readU16(2)) / 20
            case 0x0041:
                guard d.count == 10 else { throw XLSError.malformed("Invalid PANE record.") }
                let columns = Int(try d.readU16(0)), rows = Int(try d.readU16(2))
                guard rows < CellAddress.maxRows, columns < CellAddress.maxColumns else { throw XLSError.malformed("Invalid frozen pane reference.") }
                paneSplit = (columns, rows)
            case 0x023E:
                guard d.count >= 2 else { throw XLSError.malformed("Invalid WINDOW2 record.") }
                frozenPane = try d.readU16(0) & 0x0008 != 0
            case 0x0000: break
            default: break
            }
        }
        guard sawEOF else { throw XLSError.malformed("The worksheet substream is missing EOF.") }
        if reader.offset < data.count {
            let trailing = data[reader.offset..<data.count]
            if trailing.contains(where: { $0 != 0 }) { unsupported.insert("worksheet trailing data") }
        }
        if frozenPane, let paneSplit {
            sheet.frozenColumns = paneSplit.columns
            sheet.frozenRows = paneSplit.rows
        } else if frozenPane {
            throw XLSError.malformed("A frozen pane has no PANE record.")
        } else if paneSplit != nil {
            unsupported.insert("split panes")
        }
        if pendingFormulaString != nil { throw XLSError.malformed("Formula STRING record is missing.") }
        let known: Set<UInt16> = [0x0809,0x0409,0x0209,0x000A,0x0203,0x027E,0x00BD,0x00FD,0x0204,0x0205,0x0201,0x00BE,0x0006,0x0207,0x003C,0x00E5,0x007D,0x0208,0x0041,0x023E,0x0055,0x0225,0x0000,0x000D,0x000E,0x000F,0x0010,0x0011,0x0012,0x0013,0x0017,0x0023,0x0026,0x0027,0x0028,0x0029,0x002A,0x002B,0x0081,0x0099]
        if !recordTypes.isSubset(of: known) { unsupported.insert("unsupported worksheet records") }
    }

    private static func put(_ value: CellValue, at address: CellAddress, xf: Int, sheet: Sheet, workbook: Workbook,
                            styleIndexes: [Int: Int], count: inout Int) throws {
        guard address.isValid, xf < 4096, styleIndexes[xf] != nil else { throw XLSError.malformed("Cell reference or style index is out of range.") }
        count += 1; guard count <= maxCells else { throw XLSError.invalidFile("The workbook exceeds the supported cell limit.") }
        var cell = Cell(value: value); cell.styleIndex = styleIndexes[xf] ?? 0
        sheet.setCell(cell, at: address)
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
