import Foundation

/// A reference as it appears in formula text.
public struct FormulaTextReference: Equatable, Sendable {
    /// The reference; `sheetName` is the first sheet of a 3-D reference.
    public var ref: ReferenceExpr
    /// The last sheet of a 3-D reference (`Sheet1:Sheet3!A1`); nil otherwise.
    public var lastSheetName: String?

    public init(ref: ReferenceExpr, lastSheetName: String? = nil) {
        self.ref = ref
        self.lastSheetName = lastSheetName
    }

    public var isThreeD: Bool { lastSheetName != nil }
}

/// Rewrites the A1 references in formula text and copies everything else
/// through untouched, using only a tolerant tokenizer -- no parse.
///
/// Structural edits, sort, copy and fill must move every formula's
/// references, including formulas the parser does not understand (array
/// constants `{1,2}`, table references `Table1[Col]`, 3-D references,
/// the intersection operator, functions we don't have). Working on tokens
/// also leaves the rest of the text exactly as written: constants keep all
/// their digits, spacing and case are kept, and an unchanged reference is
/// copied verbatim.
public enum FormulaTextRewriter {
    /// `text` with each reference replaced by `transform`'s result: the same
    /// reference keeps its original text, nil becomes `#REF!`. References
    /// into other workbooks (`[1]Sheet1!A1`) are left alone. Text with no
    /// reference to change is returned as is, without a copy.
    public static func rewritingReferences(
        in text: String, _ transform: (FormulaTextReference) -> FormulaTextReference?
    ) -> String {
        var text = text
        // Native strings are contiguous already; this copies only bridged ones.
        return text.withUTF8 { bytes in
            let lexemes = lex(bytes)
            var out: [UInt8] = []
            var copied = 0 // bytes of `text` already in `out`
            func replace(_ span: Range<Int>, with replacement: String) {
                if out.isEmpty { out.reserveCapacity(bytes.count + 8) }
                out.append(contentsOf: bytes[copied..<span.lowerBound])
                out.append(contentsOf: replacement.utf8)
                copied = span.upperBound
            }
            var i = 0
            while i < lexemes.count {
                guard let match = matchReference(lexemes, bytes, at: i) else {
                    i += 1
                    continue
                }
                let span = lexemes[i].range.lowerBound..<lexemes[match.end - 1].range.upperBound
                i = match.end
                guard !match.external, let found = match.reference else { continue }
                guard let replaced = transform(found) else {
                    replace(span, with: CellError.ref.rawValue)
                    continue
                }
                if replaced == found { continue }
                // The sheet prefix keeps its original spelling unless it changed.
                var replacement = ""
                if replaced.ref.sheetName == found.ref.sheetName && replaced.lastSheetName == found.lastSheetName {
                    if let prefix = match.prefix { replacement = string(bytes, prefix) }
                } else if let first = replaced.ref.sheetName {
                    replacement = sheetPrefix(first, last: replaced.lastSheetName)
                }
                replacement += replaced.ref.start.a1
                if let end = replaced.ref.end { replacement += ":" + end.a1 }
                replace(span, with: replacement)
            }
            guard copied > 0 else { return nil }
            out.append(contentsOf: bytes[copied...])
            return String(decoding: out, as: UTF8.self)
        } ?? text
    }

    /// Every reference in `text` (for tests and diagnostics).
    public static func references(in text: String) -> [FormulaTextReference] {
        var found: [FormulaTextReference] = []
        _ = rewritingReferences(in: text) { found.append($0); return $0 }
        return found
    }

    /// "Sheet1!", "'My Sheet'!", "Sheet1:Sheet3!", "'Jan:Mar 2'!".
    static func sheetPrefix(_ first: String, last: String?) -> String {
        guard let last else { return ReferenceExpr.quoteSheetNameIfNeeded(first) + "!" }
        let quoted = ReferenceExpr.quoteSheetNameIfNeeded(first) != first
            || ReferenceExpr.quoteSheetNameIfNeeded(last) != last
        if quoted {
            func escape(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }
            return "'" + escape(first) + ":" + escape(last) + "'!"
        }
        return first + ":" + last + "!"
    }

    static func string(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: bytes[range]), as: UTF8.self)
    }

    // MARK: Tokens

    /// Tokens work on the text's UTF-8 bytes: every character with a meaning
    /// in a formula is ASCII, and a multi-byte character can't contain an
    /// ASCII byte. Ranges are byte offsets.
    enum Kind: Equatable {
        case space
        case string
        /// 'Sheet name'; its range includes the quotes (see `quotedName`).
        case quoted
        /// `[...]`: a table reference's column part, or a workbook index.
        case bracket
        case error
        case number
        case name
        case punct(UInt8)
    }

    struct Lexeme {
        let kind: Kind
        let range: Range<Int>
    }

    /// Where a lexer step stands: a byte offset into the text.
    private struct Cursor {
        let bytes: UnsafeBufferPointer<UInt8>
        var i = 0

        var atEnd: Bool { i >= bytes.count }
        func byte(at k: Int) -> UInt8? { k < bytes.count ? bytes[k] : nil }

        /// Length of the whitespace character at `k`, or 0.
        func spaceLength(at k: Int) -> Int {
            guard let b = byte(at: k) else { return 0 }
            switch b {
            case 0x20, 0x09, 0x0A, 0x0D: return 1
            case 0xC2 where byte(at: k + 1) == 0xA0: return 2 // no-break space
            default: return 0
            }
        }

        /// The Unicode scalar starting at `k` and its length in bytes.
        func scalar(at k: Int) -> (Unicode.Scalar, Int)? {
            var iterator = bytes[k...].makeIterator()
            var decoder = UTF8()
            guard case .scalarValue(let scalar) = decoder.decode(&iterator) else { return nil }
            return (scalar, UTF8.width(scalar))
        }

        /// Length of the character at `k` when it can be part of a name
        /// (letters, digits, `_ $ . \`, and letters beyond ASCII with their
        /// combining marks), or 0.
        func nameCharacterLength(at k: Int, first: Bool) -> Int {
            guard let b = byte(at: k) else { return 0 }
            if b < 0x80 {
                switch b {
                case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                     UInt8(ascii: "_"), UInt8(ascii: "$"), UInt8(ascii: "\\"):
                    return 1
                case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."):
                    return first ? 0 : 1
                default:
                    return 0
                }
            }
            guard let (scalar, length) = scalar(at: k) else { return 0 }
            let properties = scalar.properties
            if properties.isAlphabetic { return length }
            if !first {
                switch properties.generalCategory {
                case .nonspacingMark, .spacingMark, .enclosingMark:
                    return length
                default:
                    if properties.numericType != nil { return length }
                }
            }
            return 0
        }
    }

    /// Tokenize without ever failing: anything unexpected is a one-character
    /// punctuation token, and an unterminated string runs to the end.
    static func lex(_ bytes: UnsafeBufferPointer<UInt8>) -> [Lexeme] {
        var out: [Lexeme] = []
        var c = Cursor(bytes: bytes)
        let n = bytes.count
        /// Length of the digit at `k` (any script's, as Character.isNumber), or 0.
        func digitLength(at k: Int) -> Int {
            guard let b = c.byte(at: k) else { return 0 }
            if b < 0x80 { return b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") ? 1 : 0 }
            guard let (scalar, length) = c.scalar(at: k), scalar.properties.numericType != nil else { return 0 }
            return length
        }
        func isDigit(_ k: Int) -> Bool { digitLength(at: k) > 0 }
        while !c.atEnd {
            let start = c.i
            let b = bytes[c.i]
            if c.spaceLength(at: c.i) > 0 {
                while case let length = c.spaceLength(at: c.i), length > 0 { c.i += length }
                out.append(Lexeme(kind: .space, range: start..<c.i))
                continue
            }
            switch b {
            case UInt8(ascii: "\""), UInt8(ascii: "'"):
                // A string, or a quoted sheet name; a doubled quote is one.
                c.i += 1
                while c.i < n {
                    if bytes[c.i] == b {
                        if c.byte(at: c.i + 1) == b { c.i += 2; continue }
                        c.i += 1
                        break
                    }
                    c.i += 1
                }
                out.append(Lexeme(kind: b == UInt8(ascii: "'") ? .quoted : .string, range: start..<c.i))
            case UInt8(ascii: "["):
                var depth = 0
                while c.i < n {
                    let d = bytes[c.i]
                    if d == UInt8(ascii: "'") { c.i += 2; continue } // escaped character in a column name
                    if d == UInt8(ascii: "[") { depth += 1 }
                    if d == UInt8(ascii: "]") {
                        depth -= 1
                        if depth == 0 { c.i += 1; break }
                    }
                    c.i += 1
                }
                c.i = min(c.i, n)
                out.append(Lexeme(kind: .bracket, range: start..<c.i))
            case UInt8(ascii: "#"):
                var matched = 0
                for err in CellError.allCases {
                    let raw = err.rawValue.utf8
                    if raw.count > matched, raw.count <= n - c.i,
                       zip(raw, bytes[c.i..<(c.i + raw.count)]).allSatisfy({ $0 | 0x20 == $1 | 0x20 }) {
                        matched = raw.count
                    }
                }
                c.i += max(matched, 1)
                out.append(Lexeme(kind: matched > 0 ? .error : .punct(b), range: start..<c.i))
            default:
                if isDigit(c.i) || (b == UInt8(ascii: ".") && isDigit(c.i + 1)) {
                    while true {
                        if c.byte(at: c.i) == UInt8(ascii: ".") { c.i += 1; continue }
                        let length = digitLength(at: c.i)
                        guard length > 0 else { break }
                        c.i += length
                    }
                    if let e = c.byte(at: c.i), e | 0x20 == UInt8(ascii: "e") {
                        let sign = c.byte(at: c.i + 1) == UInt8(ascii: "+") || c.byte(at: c.i + 1) == UInt8(ascii: "-") ? 1 : 0
                        if isDigit(c.i + 1 + sign) {
                            c.i += 1 + sign
                            while case let length = digitLength(at: c.i), length > 0 { c.i += length }
                        }
                    }
                    out.append(Lexeme(kind: .number, range: start..<c.i))
                } else if case let length = c.nameCharacterLength(at: c.i, first: true), length > 0 {
                    c.i += length
                    while case let length = c.nameCharacterLength(at: c.i, first: false), length > 0 { c.i += length }
                    out.append(Lexeme(kind: .name, range: start..<c.i))
                } else {
                    // One character, however many bytes it takes.
                    c.i += b < 0x80 ? 1 : (c.scalar(at: c.i)?.1 ?? 1)
                    out.append(Lexeme(kind: .punct(b < 0x80 ? b : 0), range: start..<c.i))
                }
            }
        }
        return out
    }

    /// A quoted sheet name without its quotes, a doubled quote made one.
    static func quotedName(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> String {
        var inner = range.lowerBound + 1..<range.upperBound
        if inner.upperBound > inner.lowerBound, bytes[inner.upperBound - 1] == UInt8(ascii: "'") {
            inner = inner.lowerBound..<inner.upperBound - 1
        }
        return string(bytes, inner).replacingOccurrences(of: "''", with: "'")
    }

    // MARK: Reference matching

    struct Match {
        /// One past the last lexeme of the reference (prefix included).
        let end: Int
        /// The original sheet prefix text, "Sheet1!" included.
        let prefix: Range<Int>?
        let reference: FormulaTextReference?
        /// A reference into another workbook: copied through unchanged.
        let external: Bool
    }

    static func matchReference(_ lx: [Lexeme], _ bytes: UnsafeBufferPointer<UInt8>, at i: Int) -> Match? {
        func kind(_ j: Int) -> Kind? { j < lx.count ? lx[j].kind : nil }
        func isPunct(_ j: Int, _ c: Character) -> Bool { kind(j) == .punct(c.asciiValue!) }
        func text(_ j: Int) -> String { string(bytes, lx[j].range) }

        // 1. Optional sheet prefix.
        var first: String?
        var last: String?
        var external = false
        var j = i
        switch kind(i) {
        case .bracket:
            // [1]Sheet1!A1 or [1]!Name: another workbook.
            if kind(i + 1) == .name, isPunct(i + 2, "!") {
                external = true
                j = i + 3
            } else if isPunct(i + 1, "!") {
                return Match(end: i + 2, prefix: nil, reference: nil, external: true)
            } else {
                return nil
            }
        case .quoted:
            guard isPunct(i + 1, "!") else { return nil }
            let sheet = quotedName(bytes, lx[i].range)
            if sheet.contains("[") { external = true } // '[1]Sheet1'!A1: another workbook
            // Sheet names can't contain ':', so one here is a 3-D range.
            let parts = sheet.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, !external {
                first = String(parts[0])
                last = String(parts[1])
            } else {
                first = sheet
            }
            j = i + 2
        case .name:
            if isPunct(i + 1, "!") {
                first = text(i)
                j = i + 2
            } else if isPunct(i + 1, ":"), kind(i + 2) == .name, isPunct(i + 3, "!") {
                first = text(i)
                last = text(i + 2)
                j = i + 4
            }
        default:
            break
        }
        let prefixRange: Range<Int>? = j > i ? lx[i].range.lowerBound..<lx[j - 1].range.upperBound : nil

        // 2. The reference body.
        guard let (body, end) = matchBody(lx, bytes, at: j) else {
            // A prefix without a reference body (Sheet1!Name, Sheet1!#REF!)
            // is copied as is.
            if j > i {
                if kind(j) == .error {
                    return Match(end: j + 1, prefix: prefixRange, reference: nil, external: true)
                }
                return Match(end: j, prefix: prefixRange, reference: nil, external: true)
            }
            return nil
        }
        var ref = body
        ref.sheetName = first
        return Match(end: end, prefix: prefixRange,
                     reference: FormulaTextReference(ref: ref, lastSheetName: last), external: external)
    }

    /// A1, A1:B2, A:C, 1:3 (with $ markers) starting at lexeme `j`.
    static func matchBody(_ lx: [Lexeme], _ bytes: UnsafeBufferPointer<UInt8>, at j: Int) -> (ReferenceExpr, Int)? {
        func kind(_ k: Int) -> Kind? { k < lx.count ? lx[k].kind : nil }
        func slice(_ k: Int) -> Slice<UnsafeBufferPointer<UInt8>> { bytes[lx[k].range] }
        // Not a reference when it names a function or a table: A1(...) / T1[...].
        func endsReference(_ k: Int) -> Bool {
            switch kind(k) {
            case .punct(UInt8(ascii: "("))?, .bracket?, .punct(UInt8(ascii: "!"))?: return false
            default: return true
            }
        }
        func isColon(_ k: Int) -> Bool { kind(k) == .punct(UInt8(ascii: ":")) }
        guard let k0 = kind(j) else { return nil }

        if k0 == .name, let start = cellComponent(slice(j)) {
            if isColon(j + 1), kind(j + 2) == .name, let end = cellComponent(slice(j + 2)), endsReference(j + 3) {
                return (ReferenceExpr(start: start, end: end), j + 3)
            }
            guard endsReference(j + 1) else { return nil }
            return (ReferenceExpr(start: start), j + 1)
        }
        if k0 == .name, let start = columnComponent(slice(j)),
           isColon(j + 1), kind(j + 2) == .name, let end = columnComponent(slice(j + 2)), endsReference(j + 3) {
            return (ReferenceExpr(start: start, end: end), j + 3)
        }
        if let start = rowComponent(k0, slice(j)), isColon(j + 1), let k2 = kind(j + 2),
           let end = rowComponent(k2, slice(j + 2)), endsReference(j + 3) {
            return (ReferenceExpr(start: start, end: end), j + 3)
        }
        return nil
    }

    /// "A1" / "$A$1" inside the grid.
    static func cellComponent(_ s: Slice<UnsafeBufferPointer<UInt8>>) -> RefComponent? {
        var k = s.startIndex
        let end = s.endIndex
        let columnAbsolute = k < end && s[k] == UInt8(ascii: "$")
        if columnAbsolute { k += 1 }
        var column = 0, letters = 0
        while k < end, case let b = s[k] | 0x20, b >= UInt8(ascii: "a"), b <= UInt8(ascii: "z") {
            guard letters < 3 else { return nil }
            column = column * 26 + Int(b - UInt8(ascii: "a")) + 1
            letters += 1
            k += 1
        }
        guard letters > 0 else { return nil }
        let rowAbsolute = k < end && s[k] == UInt8(ascii: "$")
        if rowAbsolute { k += 1 }
        guard let row = digits(s[k..<end]), row >= 1 else { return nil }
        let address = CellAddress(row: row - 1, column: column - 1)
        guard address.isValid else { return nil }
        return RefComponent(column: column - 1, row: row - 1, columnAbsolute: columnAbsolute, rowAbsolute: rowAbsolute)
    }

    /// "A" / "$A" -> whole-column component.
    static func columnComponent(_ s: Slice<UnsafeBufferPointer<UInt8>>) -> RefComponent? {
        var k = s.startIndex
        let absolute = k < s.endIndex && s[k] == UInt8(ascii: "$")
        if absolute { k += 1 }
        let count = s.endIndex - k
        guard count > 0, count <= 3 else { return nil }
        var column = 0
        while k < s.endIndex {
            let b = s[k] | 0x20
            guard b >= UInt8(ascii: "a"), b <= UInt8(ascii: "z") else { return nil }
            column = column * 26 + Int(b - UInt8(ascii: "a")) + 1
            k += 1
        }
        guard column - 1 < CellAddress.maxColumns else { return nil }
        return RefComponent(column: column - 1, row: nil, columnAbsolute: absolute)
    }

    /// "3" / "$3" -> whole-row component.
    static func rowComponent(_ kind: Kind, _ s: Slice<UnsafeBufferPointer<UInt8>>) -> RefComponent? {
        var digits = s[...]
        var absolute = false
        switch kind {
        case .number: break
        case .name where s.first == UInt8(ascii: "$"): digits = s.dropFirst(); absolute = true
        default: return nil
        }
        guard digits.count <= 7, let row = Self.digits(digits), row >= 1, row <= CellAddress.maxRows else { return nil }
        return RefComponent(column: nil, row: row - 1, rowAbsolute: absolute)
    }

    /// The value of a non-empty run of ASCII digits; nil for anything else
    /// or a value too large to be a row.
    private static func digits(_ s: Slice<UnsafeBufferPointer<UInt8>>) -> Int? {
        guard !s.isEmpty, s.count <= 10 else { return nil }
        var value = 0
        for b in s {
            guard b >= UInt8(ascii: "0"), b <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int(b - UInt8(ascii: "0"))
        }
        return value
    }
}

// MARK: - Function-name prefixes in files

/// Excel writes functions added after Excel 2007 with a `_xlfn.` prefix in
/// files (and `_xlfn._xlws.` for a few); without it Excel shows #NAME?.
/// The model keeps formula text without prefixes: readers strip them and
/// the writer adds them back.
public enum FormulaFunctionPrefixes {
    /// Future functions, by name, with the prefix Excel expects.
    static let prefixes: [String: String] = {
        var map: [String: String] = [:]
        let xlfn = """
            ACOT ACOTH AGGREGATE ANCHORARRAY ARABIC ARRAYTOTEXT BASE BETA.DIST BETA.INV BINOM.DIST \
            BINOM.DIST.RANGE BINOM.INV BITAND BITLSHIFT BITOR BITRSHIFT BITXOR BYCOL BYROW \
            CEILING.MATH CEILING.PRECISE CHISQ.DIST CHISQ.DIST.RT CHISQ.INV CHISQ.INV.RT CHISQ.TEST \
            CHOOSECOLS CHOOSEROWS COMBINA CONCAT CONFIDENCE.NORM CONFIDENCE.T COT COTH COVARIANCE.P \
            COVARIANCE.S CSC CSCH DAYS DECIMAL DROP ECMA.CEILING ENCODEURL ERF.PRECISE ERFC.PRECISE \
            EXPAND EXPON.DIST F.DIST F.DIST.RT F.INV F.INV.RT F.TEST FIELDVALUE FILTERXML FLOOR.MATH \
            FLOOR.PRECISE FORECAST.ETS FORECAST.ETS.CONFINT FORECAST.ETS.SEASONALITY FORECAST.ETS.STAT \
            FORECAST.LINEAR FORMULATEXT GAMMA GAMMA.DIST GAMMA.INV GAMMALN.PRECISE GAUSS GROUPBY HSTACK \
            HYPGEOM.DIST IFNA IFS IMAGE IMCOSH IMCOT IMCSC IMCSCH IMSEC IMSECH IMSINH IMTAN ISFORMULA \
            ISOMITTED ISOWEEKNUM LAMBDA LET LOGNORM.DIST LOGNORM.INV MAKEARRAY MAP MAXIFS MINIFS \
            MODE.MULT MODE.SNGL MUNIT NEGBINOM.DIST NETWORKDAYS.INTL NORM.DIST NORM.INV NORM.S.DIST \
            NORM.S.INV NUMBERVALUE PDURATION PERCENTILE.EXC PERCENTILE.INC PERCENTOF PERCENTRANK.EXC \
            PERCENTRANK.INC PERMUTATIONA PHI PIVOTBY POISSON.DIST QUARTILE.EXC QUARTILE.INC QUERYSTRING \
            RANDARRAY RANK.AVG RANK.EQ REDUCE REGEXEXTRACT REGEXREPLACE REGEXTEST RRI SCAN SEC SECH \
            SEQUENCE SHEET SHEETS SINGLE SKEW.P SORTBY STDEV.P STDEV.S STOCKHISTORY SWITCH T.DIST \
            T.DIST.2T T.DIST.RT T.INV T.INV.2T T.TEST TAKE TEXTAFTER TEXTBEFORE TEXTJOIN TEXTSPLIT \
            TOCOL TOROW TRIMRANGE UNICHAR UNICODE UNIQUE VALUETOTEXT VAR.P VAR.S VSTACK WEBSERVICE \
            WEIBULL.DIST WORKDAY.INTL WRAPCOLS WRAPROWS XLOOKUP XMATCH XOR Z.TEST
            """
        for name in xlfn.split(separator: " ") { map[String(name)] = "_xlfn." }
        for name in ["FILTER", "SORT"] { map[name] = "_xlfn._xlws." }
        return map
    }()

    /// Formula text from a file with the `_xlfn.` / `_xlws.` prefixes taken
    /// off its function names. Text without "_xl" is returned as is.
    public static func stripped(_ text: String) -> String {
        guard text.utf8.count >= 6, containsXL(text) else { return text }
        return rewritingFunctionNames(text) { name in
            let bare = FormulaParser.strippingFunctionPrefix(name)
            return bare.count == name.count ? nil : bare
        }
    }

    /// Formula text for a file: future functions get the prefix Excel needs.
    public static func adding(_ text: String) -> String {
        // Fast path (this runs for every formula on save): a byte scan for a
        // call of a function that needs a prefix.
        guard callsFutureFunction(text) else { return text }
        return rewritingFunctionNames(text) { name in
            guard let prefix = prefixes[name.uppercased()] else { return nil }
            return prefix + name
        }
    }

    private static func containsXL(_ text: String) -> Bool {
        var previous: (UInt8, UInt8) = (0, 0)
        for b in text.utf8 {
            if previous.0 == UInt8(ascii: "_") && previous.1 | 0x20 == UInt8(ascii: "x")
                && b | 0x20 == UInt8(ascii: "l") {
                return true
            }
            previous = (previous.1, b)
        }
        return false
    }

    /// FNV-1a of each upper-cased name in `prefixes`.
    private static let prefixHashes: Set<UInt64> = Set(prefixes.keys.map { name in
        name.utf8.reduce(fnvBasis) { ($0 ^ UInt64($1)) &* fnvPrime }
    })
    private static let fnvBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let fnvPrime: UInt64 = 0x0000_0100_0000_01b3

    /// True if some name directly before a '(' outside string literals,
    /// quoted sheet names and brackets may be in `prefixes` (by hash: no
    /// allocation, as this runs for every formula on save; a collision only
    /// costs the exact check in `rewritingFunctionNames`).
    static func callsFutureFunction(_ text: String) -> Bool {
        var hash = fnvBasis
        var length = 0
        var quote: UInt8 = 0 // the closing quote while inside "..." or '...'
        var brackets = 0
        for b in text.utf8 {
            if quote != 0 {
                if b == quote { quote = 0 } // a doubled quote reopens at once
                continue
            }
            if brackets > 0 {
                if b == UInt8(ascii: "[") { brackets += 1 } else if b == UInt8(ascii: "]") { brackets -= 1 }
                continue
            }
            switch b {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "."):
                let upper = b >= UInt8(ascii: "a") ? b & 0xDF : b
                hash = (hash ^ UInt64(upper)) &* fnvPrime
                length += 1
                continue
            case UInt8(ascii: "("):
                if length >= 2, prefixHashes.contains(hash) { return true }
            case UInt8(ascii: "\""), UInt8(ascii: "'"):
                quote = b
            case UInt8(ascii: "["):
                brackets = 1
            default:
                break
            }
            hash = fnvBasis
            length = 0
        }
        return false
    }

    /// Replace function names (a name directly followed by '(') where
    /// `replace` returns non-nil; strings, sheet names and table columns are
    /// never touched.
    private static func rewritingFunctionNames(_ text: String, _ replace: (String) -> String?) -> String {
        var text = text
        return text.withUTF8 { bytes in
            let lexemes = FormulaTextRewriter.lex(bytes)
            var out = ""
            var changed = false
            for (k, lexeme) in lexemes.enumerated() {
                let original = FormulaTextRewriter.string(bytes, lexeme.range)
                if lexeme.kind == .name, k + 1 < lexemes.count,
                   lexemes[k + 1].kind == .punct(UInt8(ascii: "(")), let replacement = replace(original) {
                    out += replacement
                    changed = true
                } else {
                    out += original
                }
            }
            return changed ? out : nil
        } ?? text
    }
}
