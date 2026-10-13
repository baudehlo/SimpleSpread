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
    /// into other workbooks (`[1]Sheet1!A1`) are left alone.
    public static func rewritingReferences(
        in text: String, _ transform: (FormulaTextReference) -> FormulaTextReference?
    ) -> String {
        let chars = Array(text)
        let lexemes = lex(chars)
        var out = ""
        out.reserveCapacity(chars.count + 8)
        var i = 0
        func emit(_ range: Range<Int>) { out.append(contentsOf: String(chars[range])) }

        while i < lexemes.count {
            guard let match = matchReference(lexemes, at: i) else {
                emit(lexemes[i].range)
                i += 1
                continue
            }
            let span = lexemes[i].range.lowerBound..<lexemes[match.end - 1].range.upperBound
            defer { i = match.end }
            guard !match.external, let found = match.reference else {
                emit(span)
                continue
            }
            guard let replaced = transform(found) else {
                out += CellError.ref.rawValue
                continue
            }
            if replaced == found {
                emit(span)
                continue
            }
            // The sheet prefix keeps its original spelling unless it changed.
            if replaced.ref.sheetName == found.ref.sheetName && replaced.lastSheetName == found.lastSheetName {
                if let prefix = match.prefix { emit(prefix) }
            } else if let first = replaced.ref.sheetName {
                out += sheetPrefix(first, last: replaced.lastSheetName)
            }
            out += replaced.ref.start.a1
            if let end = replaced.ref.end { out += ":" + end.a1 }
        }
        return out
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

    // MARK: Tokens

    enum Kind: Equatable {
        case space
        case string
        /// 'Sheet name' (unescaped).
        case quoted(String)
        /// `[...]`: a table reference's column part, or a workbook index.
        case bracket
        case error
        case number(String)
        case name(String)
        case punct(Character)
    }

    struct Lexeme {
        let kind: Kind
        let range: Range<Int>
    }

    /// Tokenize without ever failing: anything unexpected is a one-character
    /// punctuation token, and an unterminated string runs to the end.
    static func lex(_ chars: [Character]) -> [Lexeme] {
        var out: [Lexeme] = []
        var i = 0
        let n = chars.count
        while i < n {
            let start = i
            let c = chars[i]
            switch c {
            case " ", "\t", "\n", "\r", "\u{00A0}":
                while i < n, [" ", "\t", "\n", "\r", "\u{00A0}"].contains(chars[i]) { i += 1 }
                out.append(Lexeme(kind: .space, range: start..<i))
            case "\"":
                i += 1
                while i < n {
                    if chars[i] == "\"" {
                        if i + 1 < n, chars[i + 1] == "\"" { i += 2; continue }
                        i += 1
                        break
                    }
                    i += 1
                }
                out.append(Lexeme(kind: .string, range: start..<i))
            case "'":
                var name = ""
                i += 1
                while i < n {
                    if chars[i] == "'" {
                        if i + 1 < n, chars[i + 1] == "'" { name.append("'"); i += 2; continue }
                        i += 1
                        break
                    }
                    name.append(chars[i])
                    i += 1
                }
                out.append(Lexeme(kind: .quoted(name), range: start..<i))
            case "[":
                var depth = 0
                while i < n {
                    let d = chars[i]
                    if d == "'" { i += 2; continue } // escaped character in a column name
                    if d == "[" { depth += 1 }
                    if d == "]" {
                        depth -= 1
                        if depth == 0 { i += 1; break }
                    }
                    i += 1
                }
                i = min(i, n)
                out.append(Lexeme(kind: .bracket, range: start..<i))
            case "#":
                var matched = 0
                for err in CellError.allCases {
                    let raw = Array(err.rawValue)
                    if raw.count > matched, raw.count <= n - i,
                       zip(raw, chars[i..<(i + raw.count)]).allSatisfy({ $0.uppercased() == $1.uppercased() }) {
                        matched = raw.count
                    }
                }
                if matched > 0 {
                    i += matched
                    out.append(Lexeme(kind: .error, range: start..<i))
                } else {
                    i += 1
                    out.append(Lexeme(kind: .punct(c), range: start..<i))
                }
            default:
                if isDigit(c) || (c == "." && i + 1 < n && isDigit(chars[i + 1])) {
                    while i < n, isDigit(chars[i]) || chars[i] == "." { i += 1 }
                    if i < n, chars[i] == "e" || chars[i] == "E" {
                        let sign = i + 1 < n && (chars[i + 1] == "+" || chars[i + 1] == "-") ? 1 : 0
                        if i + 1 + sign < n, isDigit(chars[i + 1 + sign]) {
                            i += 1 + sign
                            while i < n, isDigit(chars[i]) { i += 1 }
                        }
                    }
                    out.append(Lexeme(kind: .number(String(chars[start..<i])), range: start..<i))
                } else if isLetter(c) || c == "_" || c == "$" || c == "\\" {
                    while i < n, isLetter(chars[i]) || isDigit(chars[i])
                            || chars[i] == "_" || chars[i] == "$" || chars[i] == "." || chars[i] == "\\" {
                        i += 1
                    }
                    out.append(Lexeme(kind: .name(String(chars[start..<i])), range: start..<i))
                } else {
                    i += 1
                    out.append(Lexeme(kind: .punct(c), range: start..<i))
                }
            }
        }
        return out
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

    static func matchReference(_ lx: [Lexeme], at i: Int) -> Match? {
        func kind(_ j: Int) -> Kind? { j < lx.count ? lx[j].kind : nil }
        func isPunct(_ j: Int, _ c: Character) -> Bool { kind(j) == .punct(c) }

        // 1. Optional sheet prefix.
        var first: String?
        var last: String?
        var external = false
        var j = i
        switch kind(i) {
        case .bracket:
            // [1]Sheet1!A1 or [1]!Name: another workbook.
            if case .name? = kind(i + 1), isPunct(i + 2, "!") {
                external = true
                j = i + 3
            } else if isPunct(i + 1, "!") {
                return Match(end: i + 2, prefix: nil, reference: nil, external: true)
            } else {
                return nil
            }
        case .quoted(let sheet):
            guard isPunct(i + 1, "!") else { return nil }
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
        case .name(let sheet):
            if isPunct(i + 1, "!") {
                first = sheet
                j = i + 2
            } else if isPunct(i + 1, ":"), case .name(let lastSheet)? = kind(i + 2), isPunct(i + 3, "!") {
                first = sheet
                last = lastSheet
                j = i + 4
            }
        default:
            break
        }
        let prefixRange: Range<Int>? = j > i ? lx[i].range.lowerBound..<lx[j - 1].range.upperBound : nil

        // 2. The reference body.
        guard let (body, end) = matchBody(lx, at: j) else {
            // A prefix without a reference body (Sheet1!Name, Sheet1!#REF!)
            // is copied as is.
            if j > i {
                if case .error? = kind(j) {
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
    static func matchBody(_ lx: [Lexeme], at j: Int) -> (ReferenceExpr, Int)? {
        func kind(_ k: Int) -> Kind? { k < lx.count ? lx[k].kind : nil }
        // Not a reference when it names a function or a table: A1(...) / T1[...].
        func endsReference(_ k: Int) -> Bool {
            switch kind(k) {
            case .punct("(")?, .bracket?, .punct("!")?: return false
            default: return true
            }
        }
        guard let k0 = kind(j) else { return nil }

        if case .name(let s) = k0, let start = cellComponent(s) {
            if kind(j + 1) == .punct(":"), case .name(let s2)? = kind(j + 2), let end = cellComponent(s2),
               endsReference(j + 3) {
                return (ReferenceExpr(start: start, end: end), j + 3)
            }
            guard endsReference(j + 1) else { return nil }
            return (ReferenceExpr(start: start), j + 1)
        }
        if case .name(let s) = k0, let start = columnComponent(s),
           kind(j + 1) == .punct(":"), case .name(let s2)? = kind(j + 2), let end = columnComponent(s2),
           endsReference(j + 3) {
            return (ReferenceExpr(start: start, end: end), j + 3)
        }
        if let start = rowComponent(k0), kind(j + 1) == .punct(":"), let k2 = kind(j + 2),
           let end = rowComponent(k2), endsReference(j + 3) {
            return (ReferenceExpr(start: start, end: end), j + 3)
        }
        return nil
    }

    /// "A1" / "$A$1" inside the grid.
    static func cellComponent(_ s: String) -> RefComponent? {
        guard let (addr, colAbs, rowAbs) = CellAddress.parseA1(s), addr.isValid else { return nil }
        return RefComponent(column: addr.column, row: addr.row, columnAbsolute: colAbs, rowAbsolute: rowAbs)
    }

    /// "A" / "$A" -> whole-column component.
    static func columnComponent(_ s: String) -> RefComponent? {
        var body = Substring(s)
        var abs = false
        if body.first == "$" { abs = true; body = body.dropFirst() }
        guard !body.isEmpty, body.count <= 3, body.allSatisfy({ $0.isASCII && $0.isLetter }),
              let col = CellAddress.columnIndex(String(body)), col < CellAddress.maxColumns else { return nil }
        return RefComponent(column: col, row: nil, columnAbsolute: abs)
    }

    /// "3" / "$3" -> whole-row component.
    static func rowComponent(_ kind: Kind) -> RefComponent? {
        let text: Substring
        var abs = false
        switch kind {
        case .number(let s): text = Substring(s)
        case .name(let s) where s.hasPrefix("$"): text = Substring(s).dropFirst(); abs = true
        default: return nil
        }
        guard !text.isEmpty, text.count <= 7, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let row = Int(text), row >= 1, row <= CellAddress.maxRows else { return nil }
        return RefComponent(column: nil, row: row - 1, rowAbsolute: abs)
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
        let chars = Array(text)
        let lexemes = FormulaTextRewriter.lex(chars)
        var out = ""
        var changed = false
        for (k, lexeme) in lexemes.enumerated() {
            if case .name(let name) = lexeme.kind, k + 1 < lexemes.count,
               lexemes[k + 1].kind == .punct("("), let replacement = replace(name) {
                out += replacement
                changed = true
            } else {
                out.append(contentsOf: String(chars[lexeme.range]))
            }
        }
        return changed ? out : text
    }
}
