import Foundation

/// A workbook defined name: `Sales` = `Data!$B$2:$B$100`, a constant, or an
/// expression. Excel's own names (`_xlnm.Print_Area`, `_xlnm.Print_Titles`)
/// are kept here too so they survive a save.
public struct DefinedName: Equatable, Sendable {
    public var name: String
    /// The sheet a sheet-scoped name belongs to; nil = workbook scope.
    public var scopeSheetID: Int?
    /// Formula text without the leading '='.
    public var formula: String
    public var hidden: Bool

    public init(name: String, scopeSheetID: Int? = nil, formula: String, hidden: Bool = false) {
        self.name = name
        self.scopeSheetID = scopeSheetID
        self.formula = formula
        self.hidden = hidden
    }
}

/// Name lookup plus parsed formulas, rebuilt when `definedNames` changes.
struct DefinedNameCache {
    /// Upper-cased name -> indices into `definedNames`.
    var indices: [String: [Int]] = [:]
    /// Parsed formula per index; nil when the formula doesn't parse.
    var parsed: [Int: FormulaExpr?] = [:]
}

extension Workbook {
    /// The parsed formula `name` stands for in a formula on `sheetID`: a
    /// name scoped to that sheet wins over a workbook-scoped one. Nil when
    /// nothing defines it (or its formula doesn't parse).
    public func definedNameFormula(_ name: String, sheetID: Int?) -> FormulaExpr? {
        guard !definedNames.isEmpty else { return nil }
        if definedNameCache == nil {
            var cache = DefinedNameCache()
            for (i, defined) in definedNames.enumerated() {
                cache.indices[defined.name.uppercased(), default: []].append(i)
            }
            definedNameCache = cache
        }
        guard let candidates = definedNameCache?.indices[name.uppercased()] else { return nil }
        let index = candidates.first { sheetID != nil && definedNames[$0].scopeSheetID == sheetID }
            ?? candidates.first { definedNames[$0].scopeSheetID == nil }
        guard let index else { return nil }
        if let cached = definedNameCache?.parsed[index] { return cached }
        var text = definedNames[index].formula.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("=") { text.removeFirst() }
        let expr = try? FormulaParser.parse(text)
        definedNameCache?.parsed[index] = .some(expr)
        return expr
    }

    /// `expr` with every defined name it uses replaced by what it stands for.
    public func expandingDefinedNames(in expr: FormulaExpr, sheetID: Int) -> FormulaExpr {
        guard !definedNames.isEmpty else { return expr }
        return expr.expandingDefinedNames { self.definedNameFormula($0, sheetID: sheetID) }
    }
}
