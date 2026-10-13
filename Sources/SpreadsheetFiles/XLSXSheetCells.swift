import Foundation
import SpreadsheetCore

/// Cell text as either worksheet reader holds it: a `String` (XMLParser)
/// or raw UTF-8 bytes (the byte scanner).
protocol CellText {
    var cellString: String { get }
    var cellDouble: Double? { get }
    var cellInt: Int? { get }
}

extension String: CellText {
    var cellString: String { self }
    var cellDouble: Double? { Double(self) }
    var cellInt: Int? { Int(self) }
}

extension Array: CellText where Element == UInt8 {
    var cellString: String { String(decoding: self, as: UTF8.self) }
    var cellDouble: Double? { SheetDataScanner.double(self) }
    var cellInt: Int? { SheetDataScanner.int(self) }
}

/// The per-row and per-cell rules of `<sheetData>`, shared by both worksheet
/// readers (the XMLParser delegate and the byte scanner) so they cannot
/// drift: row and column inference, shared formulas, value types, styles,
/// and the bounds every untrusted number is held to.
struct SheetCellBuilder {
    let sheet: Sheet
    let sharedStrings: [String]
    let styleIndexMap: [Int: Int]

    enum CellType {
        case number, shared, string, bool, error, inline, date, other

        init(_ t: String?) {
            switch t {
            case nil, "n": self = .number
            case "s": self = .shared
            case "str": self = .string
            case "b": self = .bool
            case "e": self = .error
            case "inlineStr": self = .inline
            case "d": self = .date
            default: self = .other
            }
        }
    }

    /// Row formatting and outline levels seen (neither is kept).
    private(set) var sawRowFormatting = false
    private(set) var sawOutline = false

    /// 0-based row of the `<row>` being read; `CellAddress.maxRows` once past the end.
    private var currentRow = -1
    /// Column for the next cell without an `r`.
    private var nextColumn = 0
    private var cellAddress: CellAddress?
    private var cellType = CellType.number
    private var cellStyle = 0
    /// si -> (master address, formula text)
    private var sharedFormulas: [String: (CellAddress, String)] = [:]

    /// Row heights beyond this (points) are not believed.
    static let maxRowHeight: Double = 4096

    init(sheet: Sheet, sharedStrings: [String], styleIndexMap: [Int: Int]) {
        self.sheet = sheet
        self.sharedStrings = sharedStrings
        self.styleIndexMap = styleIndexMap
    }

    mutating func startRow(r: Int?, height: Double?, hidden: Bool, customFormat: Bool, style: Int?,
                           outlineLevel: Int?) {
        if let r, r >= 1 {
            currentRow = min(r - 1, CellAddress.maxRows)
        } else {
            currentRow = min(currentRow + 1, CellAddress.maxRows)
        }
        nextColumn = 0
        guard currentRow < CellAddress.maxRows else { return }
        if let height, height.isFinite, height >= 0 {
            sheet.rowHeights[currentRow] = CGFloat(min(height, Self.maxRowHeight))
        }
        if hidden {
            sheet.hiddenRows.insert(currentRow)
        }
        if customFormat, let style, (styleIndexMap[style] ?? 0) != 0 { sawRowFormatting = true }
        if let outlineLevel, outlineLevel > 0 { sawOutline = true }
    }

    mutating func startCell(address: CellAddress?, type: CellType, style: Int?) {
        if let address {
            cellAddress = address
            nextColumn = min(address.column + 1, CellAddress.maxColumns)
            if currentRow < 0 { currentRow = min(max(0, address.row), CellAddress.maxRows) }
        } else {
            cellAddress = CellAddress(row: max(0, currentRow), column: nextColumn)
            nextColumn = min(nextColumn + 1, CellAddress.maxColumns)
        }
        cellType = type
        cellStyle = style ?? 0
    }

    /// The formula a finished `<f>` stands for: its own text, or a shared
    /// formula's master translated to this cell.
    mutating func formula(text: String?, shared: Bool, si: String?) -> String? {
        guard shared, let si, let addr = cellAddress, addr.isValid else { return text }
        if let text, !text.isEmpty {
            sharedFormulas[si] = (addr, text)
            return text
        }
        if let (masterAddr, masterText) = sharedFormulas[si] {
            return XLSXReader.translateFormula(masterText, byRows: addr.row - masterAddr.row,
                                               columns: addr.column - masterAddr.column)
        }
        return text
    }

    /// Store the cell begun by `startCell` (`</c>`).
    mutating func commitCell<T: CellText>(value: T, inlineText: T, formula: String?) {
        defer { cellAddress = nil }
        guard let addr = cellAddress, addr.isValid else { return }
        var cellValue = CellValue.empty
        switch cellType {
        case .number, .other:
            if let n = value.cellDouble { cellValue = .number(n) }
        case .shared:
            if let idx = value.cellInt, idx >= 0, idx < sharedStrings.count {
                cellValue = .string(sharedStrings[idx])
            }
        case .string:
            cellValue = .string(XML.decodeIllegalCharacters(value.cellString))
        case .bool:
            let text = value.cellString
            cellValue = .bool(text == "1" || text.lowercased() == "true")
        case .error:
            cellValue = .error(CellError.parse(value.cellString) ?? .value)
        case .inline:
            cellValue = .string(XML.decodeIllegalCharacters(inlineText.cellString))
        case .date:
            if let serial = XLSXReader.isoDateToSerial(value.cellString) { cellValue = .number(serial) }
        }
        let cell = Cell(value: cellValue, formula: formula.flatMap { $0.isEmpty ? nil : $0 },
                        styleIndex: styleIndexMap[cellStyle] ?? 0)
        if !cell.isDefault {
            sheet.setCell(cell, at: addr)
        }
    }
}

/// XML attribute-value normalisation, as XMLParser applies it: a CR LF pair
/// or a lone CR, LF or TAB becomes one space (character references are
/// decoded afterwards, so `&#10;` stays a line feed).
func normalizedAttributeBytes<C: Collection>(_ bytes: C) -> [UInt8] where C.Element == UInt8 {
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var previousCR = false
    for b in bytes {
        if b == 0x0A, previousCR { previousCR = false; continue }
        previousCR = b == 0x0D
        out.append(b == 0x0D || b == 0x0A || b == 0x09 ? 0x20 : b)
    }
    return out
}

/// XML end-of-line handling for text: CR LF and a lone CR become LF.
func normalizedLineEnds<C: Collection>(_ bytes: C) -> [UInt8] where C.Element == UInt8 {
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var previousCR = false
    for b in bytes {
        if b == 0x0A, previousCR { previousCR = false; continue }
        previousCR = b == 0x0D
        out.append(b == 0x0D ? 0x0A : b)
    }
    return out
}
