import Foundation

public struct FormulaParseError: Error, Equatable {
    public let message: String
}

/// Recursive-descent parser for formula text (leading '=' already stripped).
///
/// Precedence, tightest first (Excel/Sheets):
///   reference ':'  >  unary +/-  >  '%'  >  '^' (left-assoc)  >  '*' '/'
///   >  '+' '-'  >  '&'  >  comparisons
/// Note: unary minus binds tighter than '^', so -2^2 == 4.
public enum FormulaParser {
    public static func parse(_ text: String) throws -> FormulaExpr {
        let tokens: [FormulaToken]
        do {
            tokens = try FormulaLexer.tokenize(text)
        } catch let e as FormulaLexError {
            throw FormulaParseError(message: e.message)
        }
        var parser = Parser(tokens: tokens)
        let expr = try parser.parseExpression()
        guard parser.isAtEnd else {
            throw FormulaParseError(message: "Unexpected trailing tokens")
        }
        return expr
    }

    private struct Parser {
        let tokens: [FormulaToken]
        var pos = 0

        var isAtEnd: Bool { pos >= tokens.count }

        func peek(_ offset: Int = 0) -> FormulaToken? {
            let i = pos + offset
            return i < tokens.count ? tokens[i] : nil
        }

        mutating func advance() -> FormulaToken? {
            guard pos < tokens.count else { return nil }
            defer { pos += 1 }
            return tokens[pos]
        }

        mutating func expect(_ token: FormulaToken, _ what: String) throws {
            guard peek() == token else {
                throw FormulaParseError(message: "Expected \(what)")
            }
            pos += 1
        }

        // expression := comparison
        mutating func parseExpression() throws -> FormulaExpr {
            try parseComparison()
        }

        mutating func parseComparison() throws -> FormulaExpr {
            var left = try parseConcat()
            while let t = peek() {
                let op: BinaryOperator?
                switch t {
                case .equal: op = .equal
                case .notEqual: op = .notEqual
                case .less: op = .less
                case .lessOrEqual: op = .lessOrEqual
                case .greater: op = .greater
                case .greaterOrEqual: op = .greaterOrEqual
                default: op = nil
                }
                guard let binOp = op else { break }
                pos += 1
                let right = try parseConcat()
                left = .binary(binOp, left, right)
            }
            return left
        }

        mutating func parseConcat() throws -> FormulaExpr {
            var left = try parseAdditive()
            while peek() == .ampersand {
                pos += 1
                let right = try parseAdditive()
                left = .binary(.concat, left, right)
            }
            return left
        }

        mutating func parseAdditive() throws -> FormulaExpr {
            var left = try parseMultiplicative()
            while let t = peek(), t == .plus || t == .minus {
                pos += 1
                let right = try parseMultiplicative()
                left = .binary(t == .plus ? .add : .subtract, left, right)
            }
            return left
        }

        mutating func parseMultiplicative() throws -> FormulaExpr {
            var left = try parseExponent()
            while let t = peek(), t == .star || t == .slash {
                pos += 1
                let right = try parseExponent()
                left = .binary(t == .star ? .multiply : .divide, left, right)
            }
            return left
        }

        // Left-associative '^' over unary-level operands.
        mutating func parseExponent() throws -> FormulaExpr {
            var left = try parseUnary()
            while peek() == .caret {
                pos += 1
                let right = try parseUnary()
                left = .binary(.power, left, right)
            }
            return left
        }

        mutating func parseUnary() throws -> FormulaExpr {
            if peek() == .minus {
                pos += 1
                return .unary(.minus, try parseUnary())
            }
            if peek() == .plus {
                pos += 1
                return .unary(.plus, try parseUnary())
            }
            return try parsePostfix()
        }

        mutating func parsePostfix() throws -> FormulaExpr {
            var expr = try parsePrimary()
            while peek() == .percent {
                pos += 1
                expr = .percent(expr)
            }
            return expr
        }

        mutating func parsePrimary() throws -> FormulaExpr {
            guard let t = peek() else {
                throw FormulaParseError(message: "Unexpected end of formula")
            }
            switch t {
            case .number(let n):
                pos += 1
                // Whole-row range: 1:3
                if peek() == .colon, let rowRef = rowComponent(from: t), let after = peek(1),
                   let endRef = rowComponent(from: after) {
                    pos += 2
                    return .reference(ReferenceExpr(start: rowRef, end: endRef))
                }
                return .number(n)
            case .string(let s):
                pos += 1
                return .string(s)
            case .errorLiteral(let e):
                pos += 1
                return .errorLiteral(e)
            case .leftParen:
                pos += 1
                let inner = try parseExpression()
                try expect(.rightParen, "')'")
                return .paren(inner)
            case .quotedSheetName(let sheet):
                pos += 1
                try expect(.bang, "'!' after sheet name")
                return try parseReferenceBody(sheetName: sheet)
            case .name(let s):
                // Function call?
                if peek(1) == .leftParen, isFunctionName(s) {
                    pos += 2
                    var args: [FormulaExpr] = []
                    if peek() == .rightParen {
                        pos += 1
                    } else {
                        while true {
                            args.append(try parseExpression())
                            if peek() == .comma { pos += 1; continue }
                            try expect(.rightParen, "')' or ','")
                            break
                        }
                    }
                    return .function(s.uppercased(), args)
                }
                // Sheet-qualified reference: Name!A1
                if peek(1) == .bang {
                    pos += 2
                    return try parseReferenceBody(sheetName: s)
                }
                // Boolean literals
                if s.caseInsensitiveCompare("TRUE") == .orderedSame {
                    pos += 1
                    return .boolean(true)
                }
                if s.caseInsensitiveCompare("FALSE") == .orderedSame {
                    pos += 1
                    return .boolean(false)
                }
                return try parseReferenceBody(sheetName: nil)
            default:
                throw FormulaParseError(message: "Unexpected token")
            }
        }

        func isFunctionName(_ s: String) -> Bool {
            // Anything followed by '(' that isn't a pure cell reference is treated
            // as a function name; unknown functions evaluate to #NAME?.
            !s.contains("$")
        }

        /// Parse a reference starting at the current token (a name or number),
        /// optionally qualified by a sheet name already consumed.
        mutating func parseReferenceBody(sheetName: String?) throws -> FormulaExpr {
            guard let t = peek() else {
                throw FormulaParseError(message: "Expected reference")
            }

            // Whole-row range after sheet name: Sheet1!1:3 or $1:$3
            if let startRow = rowComponent(from: t) {
                if peek(1) == .colon, let endTok = peek(2), let endRow = rowComponent(from: endTok) {
                    pos += 3
                    return .reference(ReferenceExpr(sheetName: sheetName, start: startRow, end: endRow))
                }
            }

            guard case .name(let s) = t else {
                throw FormulaParseError(message: "Expected reference")
            }

            // Full cell reference A1 / $A$1
            if let (addr, colAbs, rowAbs) = CellAddress.parseA1(s) {
                pos += 1
                let start = RefComponent(column: addr.column, row: addr.row,
                                         columnAbsolute: colAbs, rowAbsolute: rowAbs)
                if peek() == .colon {
                    // Range: A1:B2
                    if case .name(let s2)? = peek(1),
                       let (addr2, colAbs2, rowAbs2) = CellAddress.parseA1(s2) {
                        pos += 2
                        let end = RefComponent(column: addr2.column, row: addr2.row,
                                               columnAbsolute: colAbs2, rowAbsolute: rowAbs2)
                        return .reference(ReferenceExpr(sheetName: sheetName, start: start, end: end))
                    }
                    throw FormulaParseError(message: "Malformed range")
                }
                return .reference(ReferenceExpr(sheetName: sheetName, start: start))
            }

            // Whole-column range: A:A / $A:$C
            if let startCol = columnComponent(from: s) {
                if peek(1) == .colon, case .name(let s2)? = peek(2),
                   let endCol = columnComponent(from: s2) {
                    pos += 3
                    return .reference(ReferenceExpr(sheetName: sheetName, start: startCol, end: endCol))
                }
            }

            if sheetName != nil {
                throw FormulaParseError(message: "Malformed sheet reference")
            }
            pos += 1
            return .unknownName(s)
        }

        /// "$A" or "A" -> whole-column component.
        func columnComponent(from s: String) -> RefComponent? {
            var body = Substring(s)
            var abs = false
            if body.first == "$" { abs = true; body = body.dropFirst() }
            guard !body.isEmpty, body.count <= 3, body.allSatisfy({ $0.isLetter }),
                  let col = CellAddress.columnIndex(String(body)) else { return nil }
            return RefComponent(column: col, row: nil, columnAbsolute: abs)
        }

        /// Number token "3" or name token "$3" -> whole-row component.
        func rowComponent(from token: FormulaToken) -> RefComponent? {
            switch token {
            case .number(let n):
                guard n >= 1, n == n.rounded(), n <= Double(CellAddress.maxRows) else { return nil }
                return RefComponent(column: nil, row: Int(n) - 1)
            case .name(let s):
                guard s.hasPrefix("$"), let row = Int(s.dropFirst()), row >= 1 else { return nil }
                return RefComponent(column: nil, row: row - 1, rowAbsolute: true)
            default:
                return nil
            }
        }
    }
}
