import Foundation
import SpreadsheetCore

/// Where a new pivot table goes.
public enum PivotDestination: Equatable {
    case newSheet
    case existing(sheetID: Int, at: CellAddress)
}

/// Pivot tables in the document: create, edit, refresh — each one undoable
/// step that recomputes and redraws the affected tables.
extension SpreadsheetDocument {
    /// The pivot table whose area holds `address` on a sheet (default: active).
    public func pivotIndex(at address: CellAddress, sheetID: Int? = nil) -> Int? {
        let id = sheetID ?? activeSheetID
        return workbook.pivotTables.lastIndex { $0.sheetID == id && $0.occupiedRange.contains(address) }
    }

    /// The pivot table under the active cell.
    public var activePivotIndex: Int? { pivotIndex(at: selection.activeCell) }

    /// Why a pivot table can't be edited or refreshed here, or nil.
    public func pivotEditBlocker(_ index: Int) -> String? {
        let table = workbook.pivotTables[index]
        guard let definition = table.definition, let data = workbook.pivotCache(withID: table.cacheID)?.data else {
            return "SimpleSpread couldn't read its definition"
        }
        return PivotEngine(cache: data, definition: definition).unsupportedReason
    }

    // MARK: Creating

    /// The data range a new pivot would summarize: the selection when it
    /// spans more than one cell, else the filled region around the active cell.
    public func suggestedPivotSource() -> CellRange? {
        if !selection.isSingleCell { return selection.range }
        let sheet = activeSheet
        let start = selection.activeCell
        guard !sheet.value(at: start).isEmpty else { return nil }
        var region = CellRange(start)
        var grew = true
        while grew {
            grew = false
            let outer = CellRange(start: CellAddress(row: max(0, region.start.row - 1), column: max(0, region.start.column - 1)),
                                  end: CellAddress(row: region.end.row + 1, column: region.end.column + 1))
            let filled = sheet.cells.keys.filter { outer.contains($0) && !sheet.value(at: $0).isEmpty }
            for address in filled where !region.contains(address) {
                region = region.union(CellRange(address))
                grew = true
            }
        }
        return region
    }

    /// Insert a pivot table over `source` (on the active sheet) and select it.
    @discardableResult
    public func insertPivotTable(source: CellRange, destination: PivotDestination = .newSheet) -> Bool {
        let sourceSheetID = activeSheetID
        registerWorkbookUndo(actionName: "Insert PivotTable")
        let target: (sheetID: Int, at: CellAddress)
        switch destination {
        case .newSheet:
            let sheet = workbook.addSheet()
            target = (sheet.id, CellAddress(row: 2, column: 0))
        case .existing(let sheetID, let at):
            target = (sheetID, at)
        }
        do {
            let index = try workbook.createPivotTable(sourceSheetID: sourceSheetID, source: source,
                                                      destinationSheetID: target.sheetID, at: target.at)
            let result = try workbook.computePivotTable(at: index)
            let conflicts = workbook.pivotLayoutConflicts(for: index, result: result)
            guard conflicts.cells.isEmpty && conflicts.tables.isEmpty else {
                undoManager.undo()
                notice = DocumentNotice(message: "There isn’t room for a pivot table there.",
                                        detail: "Choose an empty area or a new sheet.")
                return false
            }
            workbook.applyPivotLayout(at: index, result: result)
            activeSheetID = target.sheetID
            selection = SelectionState()
            selection.select(workbook.pivotTables[index].location.start)
            engine.rebuildAll()
            markChanged()
            return true
        } catch {
            undoManager.undo()
            notice = DocumentNotice(message: "Couldn’t create the pivot table.", detail: Self.reason(error))
            return false
        }
    }

    // MARK: Editing and refreshing

    /// Group or ungroup a field: `change` edits the shared cache, so every
    /// pivot table using it is redrawn.
    @discardableResult
    public func regroupPivot(_ index: Int, actionName: String, _ change: (Workbook) throws -> Void) -> Bool {
        guard workbook.pivotTables.indices.contains(index) else { return false }
        let cacheID = workbook.pivotTables[index].cacheID
        let tables = workbook.pivotTables.indices.filter { workbook.pivotTables[$0].cacheID == cacheID }
        if let blocked = tables.first(where: { pivotEditBlocker($0) != nil }) {
            let other = blocked == index ? "" : " “\(workbook.pivotTables[blocked].name)” shares its data, and"
            notice = DocumentNotice(message: "This field can’t be grouped in SimpleSpread.",
                                    detail: "Pivot table\(other) \(pivotEditBlocker(blocked)!). It’s kept intact for Excel.")
            return false
        }
        let changed = transaction(actionName: actionName, tables: tables) { try change(workbook) }
        if !changed, let detail = notice?.detail, notice?.message == "Couldn’t update the pivot table." {
            notice = DocumentNotice(message: "Couldn’t group the field.", detail: detail)
        }
        return changed
    }

    /// Change a pivot table's definition and redraw it.
    @discardableResult
    public func editPivot(_ index: Int, actionName: String,
                          _ change: (inout PivotDefinition, PivotCacheData) -> Void) -> Bool {
        guard workbook.pivotTables.indices.contains(index) else { return false }
        if let blocker = pivotEditBlocker(index) {
            notice = DocumentNotice(message: "This pivot table can’t be changed in SimpleSpread.",
                                    detail: "It came from Excel, and \(blocker). It’s kept intact for Excel.")
            return false
        }
        return transaction(actionName: actionName, tables: [index]) {
            let table = workbook.pivotTables[index]
            guard var definition = table.definition, let data = workbook.pivotCache(withID: table.cacheID)?.data else { return }
            change(&definition, data)
            workbook.pivotTables[index].definition = definition
            workbook.pivotTables[index].isModified = true
        }
    }

    /// Refresh the cache behind a pivot table (and every table sharing it).
    @discardableResult
    public func refreshPivot(_ index: Int) -> Bool {
        guard workbook.pivotTables.indices.contains(index) else { return false }
        let cacheID = workbook.pivotTables[index].cacheID
        return refresh(cacheIDs: [cacheID])
    }

    /// Refresh every pivot table in the workbook that can be refreshed.
    @discardableResult
    public func refreshAllPivots() -> Bool {
        let refreshable = Set(workbook.pivotTables.indices.filter { pivotEditBlocker($0) == nil }
            .map { workbook.pivotTables[$0].cacheID })
        guard !refreshable.isEmpty else {
            notice = DocumentNotice(message: "There are no pivot tables to refresh.",
                                    detail: workbook.pivotTables.isEmpty ? "This workbook has no pivot tables."
                                        : "Its pivot tables came from Excel with features SimpleSpread keeps but can’t recompute.")
            return false
        }
        return refresh(cacheIDs: refreshable)
    }

    private func refresh(cacheIDs: Set<Int>) -> Bool {
        let tables = workbook.pivotTables.indices.filter { cacheIDs.contains(workbook.pivotTables[$0].cacheID) }
        if let blocked = tables.first(where: { pivotEditBlocker($0) != nil }) {
            notice = DocumentNotice(message: "This pivot table can’t be refreshed in SimpleSpread.",
                                    detail: "It came from Excel, and \(pivotEditBlocker(blocked)!). It’s kept intact for Excel.")
            return false
        }
        var failure: Error?
        let done = transaction(actionName: "Refresh", tables: tables) {
            do {
                for id in cacheIDs.sorted() { try workbook.refreshPivotCache(withID: id) }
            } catch {
                failure = error
            }
        }
        if let failure {
            notice = DocumentNotice(message: "Couldn’t refresh the pivot table.", detail: Self.reason(failure))
        }
        return done && failure == nil
    }

    /// Run a pivot change as one undoable step: apply it, lay out `tables`,
    /// ask before overwriting cells, then redraw. Cancelled or failed changes
    /// leave the workbook untouched.
    private func transaction(actionName: String, tables: [Int], _ change: () throws -> Void) -> Bool {
        let savedCaches = workbook.pivotCaches, savedTables = workbook.pivotTables
        func rollBack() {
            workbook.pivotCaches = savedCaches
            workbook.pivotTables = savedTables
        }
        do {
            try change()
        } catch {
            rollBack()
            notice = DocumentNotice(message: "Couldn’t update the pivot table.", detail: Self.reason(error))
            return false
        }
        // A change that threw left the pivots partly modified.
        var results: [(Int, PivotLayoutResult)] = []
        do {
            for i in tables { results.append((i, try workbook.computePivotTable(at: i))) }
        } catch {
            rollBack()
            notice = DocumentNotice(message: "Couldn’t update the pivot table.", detail: Self.reason(error))
            return false
        }
        if workbook.pivotCaches.map(\.isModified) == savedCaches.map(\.isModified)
            && workbook.pivotTables.map(\.definition) == savedTables.map(\.definition)
            && results.allSatisfy({ i, r in r.rowLines == savedTables[i].definition?.rowLines && !workbook.pivotTables[i].isModified }) {
            // Nothing changed (e.g. a refresh that failed before touching anything).
            rollBack()
            return false
        }
        var cells: [CellAddress] = []
        var others: [String] = []
        for (i, result) in results {
            let conflicts = workbook.pivotLayoutConflicts(for: i, result: result)
            cells += conflicts.cells
            others += conflicts.tables
        }
        if !others.isEmpty {
            rollBack()
            notice = DocumentNotice(message: "The pivot table would overlap “\(others[0])”.",
                                    detail: "Move one of them, or make room, and try again.")
            return false
        }
        if !cells.isEmpty {
            let detail = "Cells \(cells.prefix(3).map(\.a1).joined(separator: ", "))\(cells.count > 3 ? "…" : "") would be overwritten."
            guard confirm?("There’s already data where the pivot table needs to go. Replace it?", detail, "Replace") == true else {
                rollBack()
                return false
            }
        }
        // Snapshot the old state for undo, then commit.
        let newCaches = workbook.pivotCaches, newTables = workbook.pivotTables
        rollBack()
        registerWorkbookUndo(actionName: actionName)
        workbook.pivotCaches = newCaches
        workbook.pivotTables = newTables
        for (i, result) in results { workbook.applyPivotLayout(at: i, result: result) }
        engine.rebuildAll()
        markChanged()
        return true
    }

    static func reason(_ error: Error) -> String {
        if let e = error as? PivotEngineError { return e.reason.prefix(1).uppercased() + e.reason.dropFirst() + "." }
        return error.localizedDescription
    }

    // MARK: Drawing support

    /// The role of a pivot cell on the active sheet (computable pivots only).
    public func pivotRole(at address: CellAddress) -> PivotCellRole? {
        if pivotRoleCache?.revision != revision || pivotRoleCache?.sheetID != activeSheetID {
            var roles: [CellAddress: PivotCellRole] = [:]
            for (i, table) in workbook.pivotTables.enumerated() where table.sheetID == activeSheetID {
                guard let result = try? workbook.computePivotTable(at: i) else { continue }
                for (offset, cell) in result.cells {
                    roles[CellAddress(row: table.location.start.row + offset.row,
                                      column: table.location.start.column + offset.column)] = cell.role
                }
            }
            pivotRoleCache = (revision, activeSheetID, roles)
        }
        return pivotRoleCache?.roles[address]
    }
}
