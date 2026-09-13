import Foundation

enum FormulaToken: Equatable {
    case number(Double)
    case string(String)
    /// Identifier-ish run: function names, TRUE/FALSE, cell refs, column letters,
    /// possibly containing $ . _ characters.
    case name(String)
    /// Single-quoted sheet name (unescaped), always followed by '!' in valid input.
    case quotedSheetName(String)
    case errorLiteral(CellError)
    case leftParen
    case rightParen
    case comma
    case colon
    case bang        // '!'
    case percent
    case caret
    case star
    case slash
    case plus
    case minus
    case ampersand
    case equal
    case notEqual
    case less
    case lessOrEqual
    case greater
    case greaterOrEqual
}

struct FormulaLexError: Error {
    let message: String
}

/// Tokenizes formula text (without the leading '='). Whitespace is skipped;
/// the space intersection operator is not supported (matching Google Sheets).
enum FormulaLexer {
    static func tokenize(_ text: String) throws -> [FormulaToken] {
        var tokens: [FormulaToken] = []
        let chars = Array(text)
        var i = 0

        func peek(_ offset: Int = 0) -> Character? {
            let idx = i + offset
            return idx < chars.count ? chars[idx] : nil
        }

        while i < chars.count {
            let c = chars[i]
            switch c {
            case " ", "\t", "\n", "\r":
                i += 1
            case "(": tokens.append(.leftParen); i += 1
            case ")": tokens.append(.rightParen); i += 1
            case ",": tokens.append(.comma); i += 1
            case ":": tokens.append(.colon); i += 1
            case "!": tokens.append(.bang); i += 1
            case "%": tokens.append(.percent); i += 1
            case "^": tokens.append(.caret); i += 1
            case "*": tokens.append(.star); i += 1
            case "/": tokens.append(.slash); i += 1
            case "+": tokens.append(.plus); i += 1
            case "-", "\u{2212}": tokens.append(.minus); i += 1
            case "&": tokens.append(.ampersand); i += 1
            case "=": tokens.append(.equal); i += 1
            case "<":
                if peek(1) == "=" { tokens.append(.lessOrEqual); i += 2 }
                else if peek(1) == ">" { tokens.append(.notEqual); i += 2 }
                else { tokens.append(.less); i += 1 }
            case ">":
                if peek(1) == "=" { tokens.append(.greaterOrEqual); i += 2 }
                else { tokens.append(.greater); i += 1 }
            case "\"":
                var s = ""
                i += 1
                var closed = false
                while i < chars.count {
                    if chars[i] == "\"" {
                        if peek(1) == "\"" { s.append("\""); i += 2 }
                        else { i += 1; closed = true; break }
                    } else {
                        s.append(chars[i]); i += 1
                    }
                }
                if !closed { throw FormulaLexError(message: "Unterminated string literal") }
                tokens.append(.string(s))
            case "'":
                var s = ""
                i += 1
                var closed = false
                while i < chars.count {
                    if chars[i] == "'" {
                        if peek(1) == "'" { s.append("'"); i += 2 }
                        else { i += 1; closed = true; break }
                    } else {
                        s.append(chars[i]); i += 1
                    }
                }
                if !closed { throw FormulaLexError(message: "Unterminated sheet name") }
                tokens.append(.quotedSheetName(s))
            case "#":
                // Error literal: longest match against known errors.
                var matched: CellError?
                var matchedLength = 0
                for err in CellError.allCases {
                    let raw = Array(err.rawValue)
                    if raw.count <= chars.count - i, Array(chars[i..<(i + raw.count)]) == raw,
                       raw.count > matchedLength {
                        matched = err
                        matchedLength = raw.count
                    }
                }
                guard let err = matched else {
                    throw FormulaLexError(message: "Unknown error literal")
                }
                tokens.append(.errorLiteral(err))
                i += matchedLength
            default:
                if c.isNumber || (c == "." && (peek(1)?.isNumber ?? false)) {
                    var s = ""
                    while let p = peek(), p.isNumber || p == "." {
                        s.append(p); i += 1
                    }
                    // Scientific notation: 1e5, 2.5E-3 — but only when followed by
                    // digits (so "1E" in a ref like E1 isn't swallowed... refs never
                    // start with a digit, so any e/E here is an exponent attempt).
                    if let p = peek(), p == "e" || p == "E" {
                        let signOffset = (peek(1) == "+" || peek(1) == "-") ? 1 : 0
                        if let d = peek(1 + signOffset), d.isNumber {
                            s.append(p); i += 1
                            if signOffset == 1 { s.append(chars[i]); i += 1 }
                            while let d2 = peek(), d2.isNumber { s.append(d2); i += 1 }
                        }
                    }
                    guard let value = Double(s) else {
                        throw FormulaLexError(message: "Malformed number: \(s)")
                    }
                    tokens.append(.number(value))
                } else if c.isLetter || c == "_" || c == "$" {
                    var s = ""
                    while let p = peek(), p.isLetter || p.isNumber || p == "_" || p == "$" || p == "." {
                        s.append(p); i += 1
                    }
                    tokens.append(.name(s))
                } else {
                    throw FormulaLexError(message: "Unexpected character: \(c)")
                }
            }
        }
        return tokens
    }
}
