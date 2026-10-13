import Foundation
import SpreadsheetCore

/// Reads a worksheet's `<sheetData>` (rows and cells — nearly all of a big
/// sheet) straight from the bytes, skipping XMLParser's per-element object
/// overhead. It follows the XMLParser delegate in `parseWorksheet` rule for
/// rule; that delegate still reads everything else in the sheet, and tests
/// compare the two on every fixture.
struct SheetDataScanner {
    /// The cell rules, shared with the XMLParser reader.
    private(set) var builder: SheetCellBuilder

    // Parse state: the text of the cell being read.
    private var value: [UInt8] = []
    private var formula: [UInt8]?
    private var resolvedFormula: String?
    private var inlineText: [UInt8] = []
    private var inV = false, inF = false, inIS = false, inIST = false
    private var formulaIsShared = false
    private var sharedSI: String?

    /// Never reserve room for more cells than this up front: the estimate
    /// is extrapolated, and the table grows as needed past it.
    static let maxReservedCells = 16_000_000

    init(sheet: Sheet, sharedStrings: [String], styleIndexMap: [Int: Int]) {
        builder = SheetCellBuilder(sheet: sheet, sharedStrings: sharedStrings, styleIndexMap: styleIndexMap)
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
        let sample = min(n, 256 * 1024)
        if sample >= 3 {
            var cells = 0
            for k in 0..<(sample - 2) where base[k] == lt && base[k + 1] == 0x63 // "<c"
                && (base[k + 2] == 0x20 || base[k + 2] == gt || base[k + 2] == slash) {
                cells += 1
            }
            let estimate = Double(cells) / Double(sample) * Double(n) * 1.05
            let sheet = builder.sheet
            sheet.reserveCellCapacity(sheet.cells.count + min(Int(estimate), Self.maxReservedCells))
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
            builder.startRow(r: attributes.int(.r), height: attributes.double(.ht),
                             hidden: attributes.bool(.hidden), customFormat: attributes.bool(.customFormat),
                             style: attributes.int(.s), outlineLevel: attributes.int(.outlineLevel))
        } else if name == "c" {
            builder.startCell(address: attributes.address(.r),
                              type: attributes.cellType(),
                              style: attributes.int(.s))
            value.removeAll(keepingCapacity: true)
            formula = nil
            resolvedFormula = nil
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
            resolvedFormula = builder.formula(text: formula.map { String(decoding: $0, as: UTF8.self) },
                                              shared: formulaIsShared, si: sharedSI)
        } else if name == "t" {
            inIST = false
        } else if name == "is" {
            inIS = false
        } else if name == "c" {
            builder.commitCell(value: value, inlineText: inlineText, formula: resolvedFormula)
            resolvedFormula = nil
        }
    }

    // MARK: Text

    /// Append character data, decoding the five XML entities and character
    /// references, to whichever value is being read.
    /// Line ends are normalised first (CR LF and CR become LF), as XML
    /// requires; a `&#13;` reference still gives a CR.
    private mutating func appendText(_ p: UnsafePointer<UInt8>, _ count: Int) throws {
        let buffer = UnsafeBufferPointer(start: p, count: count)
        if buffer.contains(0x0D) {
            let normalized = normalizedLineEnds(buffer)
            try normalized.withUnsafeBufferPointer { try appendDecoded($0) }
        } else {
            try appendDecoded(buffer)
        }
    }

    private mutating func appendDecoded(_ buffer: UnsafeBufferPointer<UInt8>) throws {
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
    enum Key: Int { case r, s, t, ht, hidden, si, customFormat, outlineLevel }
    private var slots: (UnsafeBufferPointer<UInt8>?, UnsafeBufferPointer<UInt8>?, UnsafeBufferPointer<UInt8>?,
                        UnsafeBufferPointer<UInt8>?, UnsafeBufferPointer<UInt8>?, UnsafeBufferPointer<UInt8>?,
                        UnsafeBufferPointer<UInt8>?, UnsafeBufferPointer<UInt8>?)
        = (nil, nil, nil, nil, nil, nil, nil, nil)

    mutating func set(_ name: Element, _ value: UnsafeBufferPointer<UInt8>) {
        if name == "r" { slots.0 = value }
        else if name == "s" { slots.1 = value }
        else if name == "t" { slots.2 = value }
        else if name == "ht" { slots.3 = value }
        else if name == "hidden" { slots.4 = value }
        else if name == "si" { slots.5 = value }
        else if name == "customFormat" { slots.6 = value }
        else if name == "outlineLevel" { slots.7 = value }
    }

    private func slot(_ key: Key) -> UnsafeBufferPointer<UInt8>? {
        switch key {
        case .r: return slots.0
        case .s: return slots.1
        case .t: return slots.2
        case .ht: return slots.3
        case .hidden: return slots.4
        case .si: return slots.5
        case .customFormat: return slots.6
        case .outlineLevel: return slots.7
        }
    }

    /// True when the value needs XML's attribute processing (entities, or
    /// whitespace to normalise) before it can be compared.
    private static func needsProcessing(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        bytes.contains { $0 == 0x26 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
    }

    /// Attribute text, normalised and entity-decoded as XMLParser does it.
    func string(_ key: Key) -> String? {
        guard let bytes = slot(key) else { return nil }
        guard Self.needsProcessing(bytes) else { return String(decoding: bytes, as: UTF8.self) }
        let normalized = normalizedAttributeBytes(bytes)
        let decoded = normalized.withUnsafeBufferPointer { try? SheetDataScanner.decodeEntities($0) }
        return String(decoding: decoded ?? normalized, as: UTF8.self)
    }

    func int(_ key: Key) -> Int? {
        guard let bytes = slot(key) else { return nil }
        if Self.needsProcessing(bytes) { return string(key).flatMap { Int($0) } }
        return SheetDataScanner.int(bytes)
    }

    func double(_ key: Key) -> Double? {
        guard let bytes = slot(key) else { return nil }
        if Self.needsProcessing(bytes) { return string(key).flatMap { Double($0) } }
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

    func cellType() -> SheetCellBuilder.CellType {
        guard let bytes = slots.2 else { return .number }
        if bytes.count == 1 {
            switch bytes[0] {
            case 0x6E: return .number   // n
            case 0x73: return .shared   // s
            case 0x62: return .bool     // b
            case 0x65: return .error    // e
            case 0x64: return .date     // d
            default: break
            }
        }
        return SheetCellBuilder.CellType(string(.t))
    }
}
