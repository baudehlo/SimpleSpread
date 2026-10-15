import Foundation

/// Parts of an opened file the model doesn't hold but a save writes back
/// (charts, images, comments, conditional formatting, …). The file format
/// layer supplies it and never lets Core look inside; Core tells it about
/// every edit that moves cells or renames or removes sheets, so what it
/// carries still lines up with the cells when it's written back.
public protocol CarriedContent: Sendable {
    /// This content after `edit`; nil when nothing is left.
    ///
    /// `rewriteFormula` rewrites the references in formula text the way the
    /// edit rewrites cell formulas; its second argument is the name of the
    /// sheet the formula belongs to (unqualified references point there),
    /// nil for none.
    func applying(_ edit: CarriedContentEdit,
                  rewriteFormula: (_ formula: String, _ ownSheetName: String?) -> String) -> (any CarriedContent)?
}

public enum CarriedContentEdit: Sendable {
    /// Rows or columns inserted or deleted on the sheet named `sheetName`.
    case structural(StructuralChange, sheetName: String)
    /// A sheet renamed (its id stays).
    case renameSheet(id: Int, from: String, to: String)
    /// A sheet removed, with what was on it.
    case deleteSheet(id: Int, name: String)
}
