import Foundation

/// Evaluates a pivot calculated-field formula (`'Sales' * 0.1`, `Profit/Units`).
///
/// Excel evaluates calculated fields on the SUM of each referenced field over
/// the cell's records. Field references are bare names (which may contain
/// spaces) or 'quoted' names; everything else is ordinary formula syntax.
/// Names are replaced by their values and the result goes through the normal
/// formula parser and evaluator, so worksheet functions work as in cells.
enum PivotCalculatedField {
    enum Token: Equatable {
        case text(String)       // passed through verbatim
        case name(String)       // a field reference
    }

    /// Split a formula into pass-through text and field names.
    static func tokenize(_ formula: String) -> [Token] {
        var s = Substring(formula.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("=") { s = s.dropFirst() }
        var tokens: [Token] = []
        let operators: Set<Character> = ["+", "-", "*", "/", "^", "(", ")", "&", "=", "<", ">", ",", "%"]
        while let c = s.first {
            if c == "'" {
                // 'quoted name' with '' escaping a quote.
                var name = ""
                var rest = s.dropFirst()
                while let ch = rest.first {
                    rest = rest.dropFirst()
                    if ch == "'" {
                        if rest.first == "'" { name.append("'"); rest = rest.dropFirst(); continue }
                        break
                    }
                    name.append(ch)
                }
                tokens.append(.name(name))
                s = rest
            } else if c == "\"" {
                // String literal, verbatim.
                var lit = "\""
                var rest = s.dropFirst()
                while let ch = rest.first {
                    rest = rest.dropFirst()
                    lit.append(ch)
                    if ch == "\"" {
                        if rest.first == "\"" { lit.append("\""); rest = rest.dropFirst(); continue }
                        break
                    }
                }
                tokens.append(.text(lit))
                s = rest
            } else if c.isNumber || (c == "." && s.dropFirst().first?.isNumber == true) {
                let number = s.prefix { $0.isNumber || $0 == "." || $0 == "E" || $0 == "e" }
                tokens.append(.text(String(number)))
                s = s.dropFirst(number.count)
            } else if c.isLetter || c == "_" {
                // A name runs up to the next operator; it may hold spaces.
                let run = s.prefix { !operators.contains($0) }
                let trimmed = run.trimmingCharacters(in: .whitespaces)
                let rest = s.dropFirst(run.count)
                if rest.first == "(" && !trimmed.contains(" ") {
                    tokens.append(.text(trimmed)) // function name
                } else {
                    tokens.append(.name(trimmed))
                }
                s = rest
            } else {
                tokens.append(.text(String(c)))
                s = s.dropFirst()
            }
        }
        return tokens
    }

    /// Evaluate with `resolve` giving each referenced field's value.
    static func evaluate(_ formula: String, resolve: (String) -> CellValue) -> CellValue {
        var expression = ""
        for token in tokenize(formula) {
            switch token {
            case .text(let t): expression += t
            case .name(let name):
                switch resolve(name) {
                case .number(let n): expression += n < 0 ? "(\(Self.literal(n)))" : Self.literal(n)
                case .error(let e): return .error(e)
                case .string(let s): expression += "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                case .bool(let b): expression += b ? "TRUE" : "FALSE"
                case .empty: expression += "0"
                }
            }
        }
        guard let expr = try? FormulaParser.parse(expression) else { return .error(.value) }
        let workbook = Workbook.newDocument()
        let context = EvalContext(workbook: workbook, sheetID: workbook.sheets[0].id, address: CellAddress(row: 0, column: 0))
        return FormulaEvaluator.evaluate(expr, context: context)
    }

    private static func literal(_ n: Double) -> String {
        if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        return "\(n)"
    }
}
