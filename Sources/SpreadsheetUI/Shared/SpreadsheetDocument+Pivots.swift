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

    /// The pivot the PivotTable Fields panel shows: the one under the active
    /// cell, or else the one the selection was last in, so the panel stays
    /// while you look at the source data (or anything else) beside it.
    /// Unlike Excel, which hides its field list outside the pivot.
    public var pivotPanelIndex: Int? {
        if let active = activePivotIndex { return active }
        guard let target = pivotPanelTarget else { return nil }
        return workbook.pivotTables.firstIndex { $0.sheetID == target.sheetID && $0.name == target.name }
    }

    /// Note the pivot under the active cell for the panel (selection and
    /// sheet changes call this).
    func rememberPivotForPanel() {
        guard let index = activePivotIndex else { return }
        let table = workbook.pivotTables[index]
        pivotPanelTarget = (table.sheetID, table.name)
    }

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
        // Excel's current region; it costs about the region's border (a
        // scan of every cell per row it grew took minutes on 20,000 rows).
        return sheet.currentRegion(around: start)
    }

    /// Insert a pivot table over `source` (on the active sheet) and select it.
    @discardableResult
    public func insertPivotTable(source: CellRange, destination: PivotDestination = .newSheet) -> Bool {
        let sourceSheetID = activeSheetID
        // Everything that can fail or be refused happens before the workbook
        // changes, so a refusal leaves nothing to undo.
        let data: PivotCacheData
        do {
            data = try PivotCacheBuilder.build(sheet: activeSheet, range: source, workbook: workbook)
        } catch {
            notice = DocumentNotice(message: "Couldn’t create the pivot table.", detail: Self.reason(error))
            return false
        }
        if case .existing(let sheetID, let at) = destination {
            let area = Workbook.newPivotTableArea(at: at)
            guard area.end.isValid else {
                notice = DocumentNotice(message: "There isn’t room for a pivot table there.",
                                        detail: "Choose a cell further up or to the left, or a new sheet.")
                return false
            }
            if sheetID == sourceSheetID && area.intersects(source) {
                notice = DocumentNotice(message: "A pivot table can’t go on top of its own data.",
                                        detail: "Choose a place outside \(source.a1), or a new sheet.")
                return false
            }
            let conflicts = workbook.pivotAreaConflicts(onSheet: sheetID, area: area)
            if let other = conflicts.tables.first {
                notice = DocumentNotice(message: "The pivot table would overlap “\(other)”.",
                                        detail: "Choose an empty area or a new sheet.")
                return false
            }
            if !conflicts.cells.isEmpty {
                guard askToConfirm("There’s already data where the pivot table needs to go. Replace it?",
                                   Self.overwriteDetail(conflicts.cells), "Replace", retry: { [weak self] in
                                       self?.insertPivotTable(source: source, destination: destination)
                                   }) else { return false }
            }
        }

        let before = takeSnapshot()
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
                                                      destinationSheetID: target.sheetID, at: target.at, data: data)
            let result = try workbook.computePivotTable(at: index)
            workbook.applyPivotLayout(at: index, result: result)
            activeSheetID = target.sheetID
            selection = SelectionState()
            selection.select(workbook.pivotTables[index].location.start)
            engine.rebuildAll()
            registerSnapshotUndo(before, actionName: "Insert PivotTable")
            markChanged()
            return true
        } catch {
            // Put the workbook back from the snapshot (never by undoing,
            // which would undo the user's previous action). No cell has
            // changed yet, so the engine needs no rebuild.
            before.workbook.restore(into: workbook)
            notice = DocumentNotice(message: "Couldn’t create the pivot table.", detail: Self.reason(error))
            return false
        }
    }

    static func overwriteDetail(_ cells: [CellAddress]) -> String {
        "Cells \(cells.prefix(3).map(\.a1).joined(separator: ", "))\(cells.count > 3 ? "…" : "") would be overwritten."
    }

    // MARK: Editing and refreshing

    /// Group or ungroup a field: `change` edits the shared cache, so every
    /// pivot table using it is redrawn.
    @discardableResult
    public func regroupPivot(_ index: Int, actionName: String, _ change: @escaping (Workbook) throws -> Void) -> Bool {
        guard workbook.pivotTables.indices.contains(index) else { return false }
        let cacheID = workbook.pivotTables[index].cacheID
        let tables = workbook.pivotTables.indices.filter { workbook.pivotTables[$0].cacheID == cacheID }
        if let blocked = tables.first(where: { pivotEditBlocker($0) != nil }) {
            let other = blocked == index ? "" : " “\(workbook.pivotTables[blocked].name)” shares its data, and"
            notice = DocumentNotice(message: "This field can’t be grouped in SimpleSpread.",
                                    detail: "Pivot table\(other) \(pivotEditBlocker(blocked)!). It’s kept intact for Excel.")
            return false
        }
        let changed = transaction(actionName: actionName, tables: tables, retry: { [weak self] in
            self?.regroupPivot(index, actionName: actionName, change)
        }) { try change(self.workbook) }
        if !changed, let detail = notice?.detail, notice?.message == "Couldn’t update the pivot table." {
            notice = DocumentNotice(message: "Couldn’t group the field.", detail: detail)
        }
        return changed
    }

    /// Change a pivot table's definition and redraw it.
    @discardableResult
    public func editPivot(_ index: Int, actionName: String,
                          _ change: @escaping (inout PivotDefinition, PivotCacheData) -> Void) -> Bool {
        guard workbook.pivotTables.indices.contains(index) else { return false }
        if let blocker = pivotEditBlocker(index) {
            notice = DocumentNotice(message: "This pivot table can’t be changed in SimpleSpread.",
                                    detail: "It came from Excel, and \(blocker). It’s kept intact for Excel.")
            return false
        }
        return transaction(actionName: actionName, tables: [index], retry: { [weak self] in
            self?.editPivot(index, actionName: actionName, change)
        }) {
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
        let done = transaction(actionName: "Refresh", tables: tables, retry: { [weak self] in
            _ = self?.refresh(cacheIDs: cacheIDs)
        }) {
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
    /// `retry` runs the whole command again (see `askToConfirm`).
    private func transaction(actionName: String, tables: [Int], retry: @escaping () -> Void,
                             _ change: () throws -> Void) -> Bool {
        let before = takeSnapshot()
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
            guard askToConfirm("There’s already data where the pivot table needs to go. Replace it?",
                               Self.overwriteDetail(cells), "Replace", retry: retry) else {
                rollBack()
                return false
            }
        }
        // Commit. Undo puts back the snapshot taken before `change`, pivot
        // definitions and caches included, so pivots stay editable.
        for (i, result) in results { workbook.applyPivotLayout(at: i, result: result) }
        engine.rebuildAll()
        registerSnapshotUndo(before, actionName: actionName)
        markChanged()
        return true
    }

    static func reason(_ error: Error) -> String {
        if let e = error as? PivotEngineError { return e.reason.prefix(1).uppercased() + e.reason.dropFirst() + "." }
        return error.localizedDescription
    }

    // MARK: Drawing support

    /// The role of a pivot cell on the active sheet (computable pivots only).
    /// Roles are stored when a pivot is laid out; a pivot read from a file is
    /// computed once, on first draw, never again per edit.
    public func pivotRole(at address: CellAddress) -> PivotCellRole? {
        guard let i = pivotIndex(at: address) else { return nil }
        let start = workbook.pivotTables[i].location.start
        return pivotCellRoles(i)[PivotOffset(row: address.row - start.row, column: address.column - start.column)]
    }

    private func pivotCellRoles(_ i: Int) -> [PivotOffset: PivotCellRole] {
        if let roles = workbook.pivotTables[i].cellRoles { return roles }
        let roles = (try? workbook.computePivotTable(at: i))?.cells.mapValues(\.role) ?? [:]
        workbook.pivotTables[i].cellRoles = roles
        return roles
    }
}
