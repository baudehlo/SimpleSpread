import Foundation
import SpreadsheetCore

/// Reads a worksheet's `<sheetData>` (rows and cells — nearly all of a big
/// sheet) straight from the bytes, skipping XMLParser's per-element object
/// overhead. It follows the XMLParser delegate in `parseWorksheet` rule for
/// rule; that delegate still reads everything else in the sheet, and tests
/// compare the two on every fixture.
struct SheetDataScanner {
    let sheet: Sheet
    let sharedStrings: [String]
    let styleIndexMap: [Int: Int]

    // Parse state, as in the delegate.
    private var currentRow = -1
    private var nextColumn = 0
    private var cellAddress: CellAddress?
    private var cellType: CellType = .number
    private var cellStyleIndex = 0
    private var value: [UInt8] = []
    private var formula: [UInt8]?
    private var inlineText: [UInt8] = []
    private var inV = false, inF = false, inIS = false, inIST = false
    private var formulaIsShared = false
    private var sharedSI: String?
    private var sharedFormulas: [String: (CellAddress, String)] = [:]

    enum CellType { case number, shared, string, bool, error, inline, date, other }

    init(sheet: Sheet, sharedStrings: [String], styleIndexMap: [Int: Int]) {
        self.sheet = sheet
        self.sharedStrings = sharedStrings
        self.styleIndexMap = styleIndexMap
    }

    /// Scan the bytes between `<sheetData>` and `</sheetData>`.
    /// `shouldContinue(fraction)` is asked every ~1 MB; returning false stops
    /// the scan and makes this return false.
    mutating func scan(_ bytes: UnsafeBufferPointer<UInt8>, shouldContinue: (Double) -> Bool) throws -> Bool {
        guard let base = bytes.baseAddress else { return true }
        let n = bytes.count
        var i = 0
        var nextCheck = 0
        let lt: UInt8 = 0x3C, gt: UInt8 = 0x3E, slash: UInt8 = 0x2F

        // Size the cell table from the density of the first stretch.
        if n > 0 {
            let sample = min(n, 256 * 1024)
            var cells = 0
            for k in 0..<(sample - 2) where base[k] == lt && base[k + 1] == 0x63 // "<c"
                && (base[k + 2] == 0x20 || base[k + 2] == gt || base[k + 2] == slash) {
                cells += 1
            }
            sheet.reserveCellCapacity(sheet.cells.count + Int(Double(cells) / Double(sample) * Double(n) * 1.05))
        }

        while i < n {
            if i >= nextCheck {
                nextCheck = i + 1 << 20
                if !shouldContinue(Double(i) / Double(n)) { return false }
            }
            // Text up to the next tag.
            if base[i] != lt {
                let start = i
                while i < n, base[i] != lt { i += 1 }
                if inV || inF || inIST { try appendText(base + start, i - start) }
                continue
            }
            // Markup.
            guard i + 1 < n else { throw XLSXError.invalidXML("unterminated tag in sheetData") }
            let next = base[i + 1]
            if next == 0x21 { // "<!": comment or CDATA (ignored, as by the delegate)
                if matches(base, i, n, "<!--") {
                    i = try skip(past: "-->", base, i + 4, n)
                } else if matches(base, i, n, "<![CDATA[") {
                    i = try skip(past: "]]>", base, i + 9, n)
                } else {
                    i = try skip(past: ">", base, i + 2, n)
                }
                continue
            }
            if next == 0x3F { // "<?"
                i = try skip(past: "?>", base, i + 2, n)
                continue
            }
            let isEnd = next == slash
            var j = isEnd ? i + 2 : i + 1
            // Element name, minus any namespace prefix.
            var localStart = j
            while j < n, !isSpace(base[j]), base[j] != gt, base[j] != slash {
                if base[j] == 0x3A { localStart = j + 1 }
                j += 1
            }
            let name = Element(base + localStart, j - localStart)
            if isEnd {
                while j < n, base[j] != gt { j += 1 }
                guard j < n else { throw XLSXError.invalidXML("unterminated end tag in sheetData") }
                i = j + 1
                end(name)
                continue
            }
            // Attributes.
            var attributes = Attributes()
            var selfClosing = false
            while j < n {
                while j < n, isSpace(base[j]) { j += 1 }
                guard j < n else { break }
                if base[j] == gt { j += 1; break }
                if base[j] == slash, j + 1 < n, base[j + 1] == gt { selfClosing = true; j += 2; break }
                // name="value" / name='value'
                let attrStart = j
                var attrLocal = j
                while j < n, base[j] != 0x3D, !isSpace(base[j]), base[j] != gt {
                    if base[j] == 0x3A { attrLocal = j + 1 }
                    j += 1
                }
                let attrName = Element(base + attrLocal, j - attrLocal)
                let hasPrefix = attrLocal != attrStart
                while j < n, isSpace(base[j]) { j += 1 }
                guard j < n, base[j] == 0x3D else { throw XLSXError.invalidXML("malformed attribute in sheetData") }
                j += 1
                while j < n, isSpace(base[j]) { j += 1 }
                guard j < n, base[j] == 0x22 || base[j] == 0x27 else {
                    throw XLSXError.invalidXML("unquoted attribute in sheetData")
                }
                let quote = base[j]
                j += 1
                let valueStart = j
                while j < n, base[j] != quote { j += 1 }
                guard j < n else { throw XLSXError.invalidXML("unterminated attribute in sheetData") }
                // The delegate (namespace processing off) sees prefixed names
                // whole, so "x14ac:dyDescent" never matches "r"/"s"/"t"…
                if !hasPrefix {
                    attributes.set(attrName, UnsafeBufferPointer(start: base + valueStart, count: j - valueStart))
                }
                j += 1
            }
            i = j
            try start(name, attributes)
            if selfClosing { end(name) }
        }
        return true
    }

    // MARK: Elements

    private mutating func start(_ name: Element, _ attributes: Attributes) throws {
        if name == "row" {
            if let r = attributes.int(.r), r >= 1 {
                currentRow = r - 1
            } else {
                currentRow += 1
            }
            nextColumn = 0
            if let ht = attributes.double(.ht) {
                sheet.rowHeights[currentRow] = CGFloat(ht)
            }
            if attributes.bool(.hidden), currentRow < CellAddress.maxRows {
                sheet.hiddenRows.insert(currentRow)
            }
        } else if name == "c" {
            if let addr = attributes.address(.r) {
                cellAddress = addr
                nextColumn = addr.column + 1
                if currentRow < 0 { currentRow = addr.row }
            } else {
                cellAddress = CellAddress(row: max(0, currentRow), column: nextColumn)
                nextColumn += 1
            }
            cellType = attributes.cellType()
            cellStyleIndex = attributes.int(.s) ?? 0
            value.removeAll(keepingCapacity: true)
            formula = nil
            inlineText.removeAll(keepingCapacity: true)
            sharedSI = nil
            formulaIsShared = false
        } else if name == "v" {
            inV = true
            value.removeAll(keepingCapacity: true)
        } else if name == "f" {
            inF = true
            formula = []
            formulaIsShared = attributes.string(.t) == "shared"
            sharedSI = attributes.string(.si)
        } else if name == "is" {
            inIS = true
        } else if name == "t" {
            if inIS { inIST = true }
        }
    }

    private mutating func end(_ name: Element) {
        if name == "v" {
            inV = false
        } else if name == "f" {
            inF = false
            if formulaIsShared, let si = sharedSI, let addr = cellAddress {
                if let text = formula, !text.isEmpty {
                    sharedFormulas[si] = (addr, String(decoding: text, as: UTF8.self))
                } else if let (masterAddr, masterText) = sharedFormulas[si] {
                    // Follower: translate the master formula by the offset.
                    let translated = XLSXReader.translateFormula(
                        masterText, byRows: addr.row - masterAddr.row,
                        columns: addr.column - masterAddr.column)
                    formula = Array(translated.utf8)
                }
            }
        } else if name == "t" {
            inIST = false
        } else if name == "is" {
            inIS = false
        } else if name == "c" {
            commitCell()
        }
    }

    private mutating func commitCell() {
        guard let addr = cellAddress, addr.isValid else { return }
        var cellValue = CellValue.empty
        switch cellType {
        case .number, .other:
            if let n = Self.double(value) { cellValue = .number(n) }
        case .shared:
            if let idx = Self.int(value), idx >= 0, idx < sharedStrings.count {
                cellValue = .string(sharedStrings[idx])
            }
        case .string:
            cellValue = .string(XML.decodeIllegalCharacters(String(decoding: value, as: UTF8.self)))
        case .bool:
            let text = String(decoding: value, as: UTF8.self)
            cellValue = .bool(text == "1" || text.lowercased() == "true")
        case .error:
            cellValue = .error(CellError.parse(String(decoding: value, as: UTF8.self)) ?? .value)
        case .inline:
            cellValue = .string(XML.decodeIllegalCharacters(String(decoding: inlineText, as: UTF8.self)))
        case .date:
            if let serial = XLSXReader.isoDateToSerial(String(decoding: value, as: UTF8.self)) {
                cellValue = .number(serial)
            }
        }
        let formulaText = formula.flatMap { $0.isEmpty ? nil : String(decoding: $0, as: UTF8.self) }
        let cell = Cell(value: cellValue, formula: formulaText, styleIndex: styleIndexMap[cellStyleIndex] ?? 0)
        if !cell.isDefault {
            sheet.setCell(cell, at: addr)
        }
        cellAddress = nil
    }

    // MARK: Text

    /// Append character data, decoding the five XML entities and character
    /// references, to whichever value is being read.
    private mutating func appendText(_ p: UnsafePointer<UInt8>, _ count: Int) throws {
        let buffer = UnsafeBufferPointer(start: p, count: count)
        if buffer.contains(0x26) {
            append(try Self.decodeEntities(buffer))
        } else {
            append(buffer)
        }
    }

    private mutating func append<C: Collection>(_ text: C) where C.Element == UInt8 {
        if inV { value.append(contentsOf: text) }
        else if inF { formula?.append(contentsOf: text) }
        else if inIST { inlineText.append(contentsOf: text) }
    }

    static func decodeEntities(_ s: UnsafeBufferPointer<UInt8>) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.count)
        var i = 0
        while i < s.count {
            let b = s[i]
            guard b == 0x26 else { out.append(b); i += 1; continue }
            var j = i + 1
            while j < s.count, s[j] != 0x3B, j - i < 12 { j += 1 }
            guard j < s.count, s[j] == 0x3B else { throw XLSXError.invalidXML("bad entity in sheetData") }
            let entity = String(decoding: UnsafeBufferPointer(rebasing: s[(i + 1)..<j]), as: UTF8.self)
            switch entity {
            case "lt": out.append(0x3C)
            case "gt": out.append(0x3E)
            case "amp": out.append(0x26)
            case "quot": out.append(0x22)
            case "apos": out.append(0x27)
            default:
                var scalar: UInt32?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    scalar = UInt32(entity.dropFirst(2), radix: 16)
                } else if entity.hasPrefix("#") {
                    scalar = UInt32(entity.dropFirst())
                }
                guard let value = scalar, let unicode = Unicode.Scalar(value) else {
                    throw XLSXError.invalidXML("unknown entity &\(entity); in sheetData")
                }
                out.append(contentsOf: Array(String(Character(unicode)).utf8))
            }
            i = j + 1
        }
        return out
    }

    // MARK: Numbers

    private static let powersOfTen: [Double] = (0...22).map { pow(10, Double($0)) }

    /// `Double(String)` on the bytes, with a fast exact path for plain
    /// decimals of up to 15 digits (one correctly rounded division).
    static func double(_ bytes: [UInt8]) -> Double? {
        let n = bytes.count
        guard n > 0 else { return nil }
        var i = 0
        var negative = false
        if bytes[0] == 0x2D { negative = true; i = 1 } else if bytes[0] == 0x2B { i = 1 }
        var mantissa: UInt64 = 0
        var digits = 0, fraction = 0
        var sawDot = false, plain = i < n
        while i < n {
            let b = bytes[i]
            if b >= 0x30 && b <= 0x39 {
                mantissa = mantissa &* 10 &+ UInt64(b - 0x30)
                digits += 1
                if sawDot { fraction += 1 }
            } else if b == 0x2E, !sawDot {
                sawDot = true
            } else {
                plain = false
                break
            }
            i += 1
        }
        if plain, digits > 0, digits <= 15 {
            var value = Double(mantissa)
            if fraction > 0 { value /= powersOfTen[fraction] }
            return negative ? -value : value
        }
        return Double(String(decoding: bytes, as: UTF8.self))
    }

    static func int<C: Collection>(_ bytes: C) -> Int? where C.Element == UInt8 {
        guard !bytes.isEmpty, bytes.count <= 18 else { return Int(String(decoding: bytes, as: UTF8.self)) }
        var value = 0
        for b in bytes {
            guard b >= 0x30 && b <= 0x39 else { return Int(String(decoding: bytes, as: UTF8.self)) }
            value = value * 10 + Int(b - 0x30)
        }
        return value
    }

    // MARK: Helpers

    private func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 }

    private func matches(_ base: UnsafePointer<UInt8>, _ i: Int, _ n: Int, _ literal: StaticString) -> Bool {
        let count = literal.utf8CodeUnitCount
        guard i + count <= n else { return false }
        return memcmp(base + i, literal.utf8Start, count) == 0
    }

    private func skip(past literal: StaticString, _ base: UnsafePointer<UInt8>, _ from: Int, _ n: Int) throws -> Int {
        var k = from
        while k < n {
            if matches(base, k, n, literal) { return k + literal.utf8CodeUnitCount }
            k += 1
        }
        throw XLSXError.invalidXML("unterminated markup in sheetData")
    }
}

/// An element or attribute name (local part), compared against literals
/// without making a String.
struct Element {
    let pointer: UnsafePointer<UInt8>
    let count: Int

    init(_ pointer: UnsafePointer<UInt8>, _ count: Int) {
        self.pointer = pointer
        self.count = count
    }

    static func == (lhs: Element, rhs: StaticString) -> Bool {
        lhs.count == rhs.utf8CodeUnitCount && memcmp(lhs.pointer, rhs.utf8Start, lhs.count) == 0
    }
}

/// The few attributes the cell reader uses, kept as byte slices.
struct Attributes {
    enum Key: Int { case r, s, t, ht, hidden, si }
    private var slots: (UnsafeBufferPointer<UInt8>?, UnsafeBufferPointer<UInt8>?, UnsafeBufferPointer<UInt8>?,
                        UnsafeBufferPointer<UInt8>?, UnsafeBufferPointer<UInt8>?, UnsafeBufferPointer<UInt8>?)
        = (nil, nil, nil, nil, nil, nil)

    mutating func set(_ name: Element, _ value: UnsafeBufferPointer<UInt8>) {
        if name == "r" { slots.0 = value }
        else if name == "s" { slots.1 = value }
        else if name == "t" { slots.2 = value }
        else if name == "ht" { slots.3 = value }
        else if name == "hidden" { slots.4 = value }
        else if name == "si" { slots.5 = value }
    }

    private func slot(_ key: Key) -> UnsafeBufferPointer<UInt8>? {
        switch key {
        case .r: return slots.0
        case .s: return slots.1
        case .t: return slots.2
        case .ht: return slots.3
        case .hidden: return slots.4
        case .si: return slots.5
        }
    }

    /// Attribute text, entity-decoded as XMLParser would.
    func string(_ key: Key) -> String? {
        guard let bytes = slot(key) else { return nil }
        if bytes.contains(0x26), let decoded = try? SheetDataScanner.decodeEntities(bytes) {
            return String(decoding: decoded, as: UTF8.self)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func int(_ key: Key) -> Int? {
        guard let bytes = slot(key) else { return nil }
        if bytes.contains(0x26) { return string(key).flatMap { Int($0) } }
        return SheetDataScanner.int(Array(bytes))
    }

    func double(_ key: Key) -> Double? {
        guard let bytes = slot(key) else { return nil }
        if bytes.contains(0x26) { return string(key).flatMap { Double($0) } }
        return SheetDataScanner.double(Array(bytes))
    }

    func bool(_ key: Key) -> Bool {
        guard let value = string(key)?.lowercased() else { return false }
        return value == "1" || value == "true"
    }

    /// The cell's `r` as an address, parsed from the bytes ("AB12").
    func address(_ key: Key) -> CellAddress? {
        guard let bytes = slot(key), !bytes.isEmpty else { return nil }
        var column = 0, row = 0, k = 0
        while k < bytes.count, k < 4, bytes[k] >= 0x41, bytes[k] <= 0x5A {
            column = column * 26 + Int(bytes[k] - 0x40)
            k += 1
        }
        let letters = k
        while k < bytes.count, k - letters < 10, bytes[k] >= 0x30, bytes[k] <= 0x39 {
            row = row * 10 + Int(bytes[k] - 0x30)
            k += 1
        }
        // Anything else (lower case, "$", entities, long names or rows): the
        // general parser.
        guard letters > 0, letters <= 3, k == bytes.count, k > letters, row >= 1 else {
            return string(key).flatMap { CellAddress(a1: $0) }
        }
        return CellAddress(row: row - 1, column: column - 1)
    }

    func cellType() -> SheetDataScanner.CellType {
        guard let bytes = slots.2 else { return .number }
        if bytes.count == 1 {
            switch bytes[0] {
            case 0x6E: return .number   // n
            case 0x73: return .shared   // s
            case 0x62: return .bool     // b
            case 0x65: return .error    // e
            case 0x64: return .date     // d
            default: return .other
            }
        }
        switch String(decoding: bytes, as: UTF8.self) {
        case "str": return .string
        case "inlineStr": return .inline
        default: return .other
        }
    }
}
