import Foundation

/// Owns formula parsing, the dependency graph, and incremental recalculation
/// for one workbook. All mutations of cell values/formulas should flow through
/// this engine so the graph stays consistent.
public final class CalculationEngine {
    public let workbook: Workbook
    public var clock: EvalClock

    /// Parsed formulas by cell.
    private var asts: [AbsoluteAddress: FormulaExpr] = [:]
    /// Exact-cell dependency edges: precedent -> dependents.
    private var dependents: [AbsoluteAddress: Dependents] = [:]
    /// Large-range dependencies, indexed by sheet, column and row.
    private var rangeIndex = RangeDependencyIndex()
    /// Reverse index for edge removal.
    private var precedentsIndex: [AbsoluteAddress: Precedents] = [:]
    /// Cells containing volatile functions (NOW/TODAY/RAND/...).
    private var volatiles: Set<AbsoluteAddress> = []
    /// Formula cells naming a sheet that doesn't exist (yet), by lowercased
    /// sheet name: re-installed when a sheet of that name appears.
    private var unresolvedSheetReferences: [String: Set<AbsoluteAddress>] = [:]

    /// The formulas reading one cell. Most cells have one reader, kept
    /// inline: a set for each would be a million allocations on a big sheet.
    private enum Dependents: Sendable {
        case one(AbsoluteAddress)
        case many(Set<AbsoluteAddress>)

        mutating func insert(_ addr: AbsoluteAddress) {
            switch self {
            case .one(let existing):
                if existing != addr { self = .many([existing, addr]) }
            case .many(var set):
                self = .one(addr) // drop the reference so the set is unique
                set.insert(addr)
                self = .many(set)
            }
        }

        /// False when nothing is left.
        mutating func remove(_ addr: AbsoluteAddress) -> Bool {
            switch self {
            case .one(let existing):
                return existing != addr
            case .many(var set):
                self = .one(addr)
                set.remove(addr)
                if set.count == 1 { self = .one(set.first!) } else { self = .many(set) }
                return !set.isEmpty
            }
        }

        func append(to nodes: inout [Node]) {
            switch self {
            case .one(let addr): nodes.append(.cell(addr))
            case .many(let set): for addr in set { nodes.append(.cell(addr)) }
            }
        }
    }

    private struct Precedents: Sendable {
        var cells: [AbsoluteAddress] = []
        var rangeIDs: [Int] = []
        var unresolvedSheets: [String] = []
        /// The sheet the formula reads (-1: none, -2: more than one) and the
        /// last row and column it reads there: a row or column edit past
        /// them leaves its references alone (`apply`).
        var reachSheetID = -1
        var lastRow = -1
        var lastColumn = -1

        mutating func reach(_ range: CellRange, onSheet sheetID: Int) {
            if reachSheetID == -1 { reachSheetID = sheetID } else if reachSheetID != sheetID { reachSheetID = -2 }
            lastRow = max(lastRow, range.start.row, range.end.row)
            lastColumn = max(lastColumn, range.start.column, range.end.column)
        }

        /// True if a row or column edit at `change.index` on its sheet can
        /// change what one of the formula's references reads.
        func mayReach(_ change: StructuralChange) -> Bool {
            reachSheetID == -2
                || (reachSheetID == change.sheetID && (change.axisIsRow ? lastRow : lastColumn) >= change.index)
        }
    }

    /// During `rebuildAll`: formulas that can only give #NAME? here (a
    /// function we don't have, an undefined name) keep the value the file
    /// stored instead of being recalculated into an error.
    private var keepingStoredValues = false
    private var keepStoredValue: Set<AbsoluteAddress> = []

    /// Ranges larger than this register as range-dependencies instead of
    /// per-cell edges.
    private let cellEdgeLimit = 256

    public init(workbook: Workbook, clock: EvalClock = EvalClock()) {
        self.workbook = workbook
        self.clock = clock
        rebuildAll()
    }

    // MARK: Public mutation API

    /// Set a literal value (clears any formula). Returns all recalculated cells.
    @discardableResult
    public func setCellValue(_ value: CellValue, at addr: AbsoluteAddress) -> Set<AbsoluteAddress> {
        guard let sheet = workbook.sheet(withID: addr.sheetID) else { return [] }
        var cell = sheet.cell(at: addr.address)
        cell.value = value
        cell.formula = nil
        sheet.setCell(cell, at: addr.address)
        removeFormula(at: addr)
        return recalculate(seeds: [addr])
    }

    /// Set a formula (text without '='). Returns all recalculated cells.
    @discardableResult
    public func setCellFormula(_ text: String, at addr: AbsoluteAddress) -> Set<AbsoluteAddress> {
        guard let sheet = workbook.sheet(withID: addr.sheetID) else { return [] }
        var cell = sheet.cell(at: addr.address)
        cell.formula = text
        sheet.setCell(cell, at: addr.address)
        installFormula(text, at: addr)
        return recalculate(seeds: [addr])
    }

    /// Clear value and formula (keeps style). Returns all recalculated cells.
    @discardableResult
    public func clearCell(at addr: AbsoluteAddress) -> Set<AbsoluteAddress> {
        guard let sheet = workbook.sheet(withID: addr.sheetID) else { return [] }
        var cell = sheet.cell(at: addr.address)
        cell.value = .empty
        cell.formula = nil
        sheet.setCell(cell, at: addr.address)
        removeFormula(at: addr)
        return recalculate(seeds: [addr])
    }

    /// Apply a batch of cell writes (paste, fill, import) then recalculate once.
    /// Each entry may carry a value or a formula.
    @discardableResult
    public func setCells(_ entries: [(AbsoluteAddress, CellValue, String?)]) -> Set<AbsoluteAddress> {
        var seeds = Set<AbsoluteAddress>()
        for (addr, value, formula) in entries {
            guard let sheet = workbook.sheet(withID: addr.sheetID) else { continue }
            var cell = sheet.cell(at: addr.address)
            cell.value = value
            cell.formula = formula
            sheet.setCell(cell, at: addr.address)
            if let f = formula {
                installFormula(f, at: addr)
            } else {
                removeFormula(at: addr)
            }
            seeds.insert(addr)
        }
        return recalculate(seeds: seeds)
    }


    /// Reparse every formula in the workbook and recalculate everything.
    /// Call after structural changes (row/col insert/delete, sheet ops).
    public func rebuildAll() {
        // Size the tables once; big imports have a million formulas.
        let formulaCount = workbook.sheets.reduce(0) { total, sheet in
            total + sheet.cells.values.reduce(0) { $0 + ($1.formula == nil ? 0 : 1) }
        }
        clearGraph(reservingCapacity: formulaCount)
        keepingStoredValues = true
        for sheet in workbook.sheets {
            for (address, cell) in sheet.cells {
                if let formula = cell.formula {
                    // The tables were just cleared: nothing to remove first.
                    installFormula(formula, at: AbsoluteAddress(sheetID: sheet.id, address: address),
                                   replacing: false)
                }
            }
        }
        keepingStoredValues = false
        recalculateAll()
        keepStoredValue.removeAll()
    }

    /// True when a formula being installed by `rebuildAll` has a stored
    /// (cached) value worth keeping over an error we would compute.
    private func hasStoredValue(at addr: AbsoluteAddress) -> Bool {
        keepingStoredValues && !(workbook.sheet(withID: addr.sheetID)?.value(at: addr.address).isEmpty ?? true)
    }

    /// Recalculate every formula cell.
    @discardableResult
    public func recalculateAll() -> Set<AbsoluteAddress> {
        evaluate(roots: asts.keys.map { .cell($0) })
    }

    /// Call after adding or renaming a sheet without `rebuildAll`: formulas
    /// that named a sheet which didn't exist yet start reading it. (The next
    /// edit does this too; this shows the result straight away.)
    @discardableResult
    public func sheetsDidChange() -> Set<AbsoluteAddress> {
        let resolved = resolvePendingSheetReferences()
        return resolved.isEmpty ? [] : recalculate(seeds: resolved)
    }

    // MARK: Structural edits

    /// Bring the graph in line with a row or column insert or delete (the
    /// result of `WorkbookOperations.apply`) and recalculate what it can
    /// have changed; returns the recalculated cells.
    ///
    /// Formulas the edit moved or rewrote are re-installed at their new
    /// addresses from their adjusted parse trees (re-parsed only when they
    /// use names); the rest keep their entries. A formula that moved along
    /// with everything it reads already has the right value, so only these
    /// recalculate, with their dependents:
    /// - a formula reading a range the edit spans or cuts into (it grew,
    ///   shrank, or now holds other cells), or a reference it deleted;
    /// - ROW and COLUMN (FunctionRegistry.positionFunctions) when they or
    ///   the references they name moved;
    /// - formulas using a defined name the edit rewrote.
    @discardableResult
    public func apply(_ edit: StructuralEditResult) -> Set<AbsoluteAddress> {
        let change = edit.change
        guard let editedName = workbook.sheet(withID: change.sheetID)?.name else { return [] }

        // Plan every formula's move before changing the tables: entries are
        // removed at their old addresses and installed at their new ones.
        // A nil tree is re-parsed from the cell's (rewritten) text.
        var moves: [(old: AbsoluteAddress, new: AbsoluteAddress, expr: FormulaExpr?)] = []
        var deleted: [AbsoluteAddress] = []
        var seeds = Set<AbsoluteAddress>()
        for (addr, entry) in precedentsIndex {
            let onEditedSheet = addr.sheetID == change.sheetID
            var newAddr = addr
            if onEditedSheet {
                guard let address = change.address(after: addr.address) else {
                    deleted.append(addr)
                    continue
                }
                newAddr.address = address
            }
            let moved = newAddr != addr
            // Most formulas neither move nor read past the edit.
            guard moved || entry.mayReach(change) || edit.definedNamesChanged,
                  let expr = asts[addr] else { continue }
            var scan = StructuralScan(change: change, editedSheetName: editedName, ownSheetIsEdited: onEditedSheet)
            scan.visit(expr)
            // A tree with names expanded is re-parsed: the names' own
            // references were rewritten in their text, not in the tree.
            let names = scan.usesNames && (edit.definedNamesChanged || scan.refsChanged)
            if scan.reshaped || (names && edit.definedNamesChanged)
                || ((moved || scan.refsChanged) && scan.callsPositionFunction) {
                seeds.insert(newAddr)
            }
            guard moved || scan.refsChanged || names else { continue }
            if names || scan.reparse {
                moves.append((addr, newAddr, nil))
            } else if scan.refsChanged {
                moves.append((addr, newAddr, expr.mappingReferences { ref in
                    scan.readsEditedSheet(ref) ? change.adjusting(ref) : ref
                }))
            } else {
                moves.append((addr, newAddr, expr))
            }
        }

        keepingStoredValues = true
        func reinstall(_ move: (old: AbsoluteAddress, new: AbsoluteAddress, expr: FormulaExpr?)) {
            if let expr = move.expr {
                install(expr, at: move.new)
            } else if let text = workbook.sheet(withID: move.new.sheetID)?.cells[move.new.address]?.formula {
                installFormula(text, at: move.new, replacing: false)
            }
        }
        if (moves.count + deleted.count) * 2 > asts.count {
            // Most formulas move (an insert near the top of a big sheet):
            // building the tables afresh beats taking entries out one by one.
            // Every formula on the edited sheet at or past the edit moved or
            // went; the rest of `moves` were rewritten where they are.
            let rewrittenInPlace = Set(moves.lazy.filter { $0.old == $0.new }.map(\.old))
            let old = clearGraph(reservingCapacity: asts.count + moves.count - deleted.count)
            for (addr, expr) in old.asts {
                if addr.sheetID == change.sheetID
                    && (change.axisIsRow ? addr.address.row : addr.address.column) >= change.index { continue }
                if rewrittenInPlace.contains(addr) { continue }
                install(expr, at: addr)
            }
            for move in moves { reinstall(move) }
            // A million entries take a while to free: not on this thread.
            DispatchQueue.global(qos: .utility).async { withExtendedLifetime(old) {} }
        } else {
            for addr in deleted { removeFormula(at: addr) }
            for move in moves { removeFormula(at: move.old) }
            for move in moves { reinstall(move) }
        }
        let recalculated = recalculate(seeds: seeds)
        keepingStoredValues = false
        keepStoredValue.removeAll()
        return recalculated
    }

    /// What a row or column edit does to one formula's references: one walk
    /// of its tree (`apply`).
    private struct StructuralScan {
        let change: StructuralChange
        let editedSheetName: String
        let ownSheetIsEdited: Bool
        /// A reference moves, grows, shrinks or becomes #REF!.
        var refsChanged = false
        /// A reference may read other contents than before.
        var reshaped = false
        /// A reference moves off the grid: re-parse the rewritten text.
        var reparse = false
        var callsPositionFunction = false
        var usesNames = false

        func readsEditedSheet(_ ref: ReferenceExpr) -> Bool {
            guard let name = ref.sheetName else { return ownSheetIsEdited }
            return name == editedSheetName || name.caseInsensitiveCompare(editedSheetName) == .orderedSame
        }

        mutating func visit(_ expr: FormulaExpr) {
            switch expr {
            case .reference(let ref):
                visit(ref)
            case .unary(_, let e), .percent(let e), .paren(let e):
                visit(e)
            case .binary(_, let l, let r):
                visit(l)
                visit(r)
            case .function(let name, let args):
                if FunctionRegistry.positionFunctions.contains(where: { $0 == name }) { callsPositionFunction = true }
                for arg in args { visit(arg) }
            case .definedName(_, let e):
                usesNames = true
                visit(e)
            case .unknownName:
                usesNames = true
            default:
                break
            }
        }

        private mutating func visit(_ ref: ReferenceExpr) {
            guard readsEditedSheet(ref) else { return }
            switch change.effect(on: ref) {
            case .untouched:
                break
            case .shifted:
                refsChanged = true
            case .reshaped:
                reshaped = true
                let adjusted = change.adjusting(ref)
                if adjusted != ref { refsChanged = true }
                // Off the grid, the text no longer parses the same way.
                if let adjusted, !adjusted.isOnGrid { reparse = true }
            }
        }
    }

    /// Bring the graph in line with an undone row or column edit
    /// (`StructuralEditResult.undo`); returns the recalculated cells.
    @discardableResult
    public func apply(_ undo: StructuralUndoResult) -> Set<AbsoluteAddress> {
        var recalculated = apply(undo.inverse)
        var changed = undo.restoredCells
        if undo.definedNamesChanged {
            // Names are expanded into the trees of the formulas using them.
            for (addr, expr) in asts where expr.usesNames { changed.insert(addr) }
        }
        // Put-back cells are the file's again: one we can't read or
        // evaluate keeps its value, as on open.
        keepingStoredValues = true
        recalculated.formUnion(cellsDidChange(at: changed))
        keepingStoredValues = false
        keepStoredValue.removeAll()
        return recalculated
    }

    /// Re-read the cells at `addresses`, changed directly on their sheets
    /// (formulas and values), and recalculate them and their dependents.
    @discardableResult
    public func cellsDidChange(at addresses: Set<AbsoluteAddress>) -> Set<AbsoluteAddress> {
        guard !addresses.isEmpty else { return [] }
        for addr in addresses {
            if let text = workbook.sheet(withID: addr.sheetID)?.cells[addr.address]?.formula {
                installFormula(text, at: addr)
            } else {
                removeFormula(at: addr)
            }
        }
        return recalculate(seeds: addresses)
    }

    /// The graph's tables, emptied by `clearGraph`.
    private struct Graph: Sendable {
        let asts: [AbsoluteAddress: FormulaExpr]
        let dependents: [AbsoluteAddress: Dependents]
        let rangeIndex: RangeDependencyIndex
        let precedentsIndex: [AbsoluteAddress: Precedents]
    }

    /// Empty the graph, sized for `formulaCount` formulas; returns the old
    /// tables.
    @discardableResult
    private func clearGraph(reservingCapacity formulaCount: Int) -> Graph {
        let old = Graph(asts: asts, dependents: dependents, rangeIndex: rangeIndex, precedentsIndex: precedentsIndex)
        asts = [:]
        dependents = [:]
        rangeIndex = RangeDependencyIndex()
        precedentsIndex = [:]
        volatiles.removeAll()
        unresolvedSheetReferences.removeAll()
        asts.reserveCapacity(formulaCount)
        precedentsIndex.reserveCapacity(formulaCount)
        dependents.reserveCapacity(formulaCount * 2)
        return old
    }

    /// True if the cell currently holds a formula.
    public func hasFormula(at addr: AbsoluteAddress) -> Bool {
        asts[addr] != nil || workbook.sheet(withID: addr.sheetID)?.cells[addr.address]?.formula != nil
    }

    // MARK: Graph maintenance

    private func installFormula(_ text: String, at addr: AbsoluteAddress, replacing: Bool = true) {
        if replacing { removeFormula(at: addr) }
        let expr: FormulaExpr
        do {
            expr = try FormulaParser.parse(text)
        } catch {
            // A file's formula we can't read keeps the value the file stored.
            if hasStoredValue(at: addr) { return }
            // Sheets-style: commit the formula, value is #ERROR!.
            if let sheet = workbook.sheet(withID: addr.sheetID) {
                var cell = sheet.cell(at: addr.address)
                cell.value = .error(.parse)
                sheet.setCell(cell, at: addr.address)
            }
            return
        }
        // Defined names are substituted, so their references are tracked.
        install(workbook.expandingDefinedNames(in: expr, sheetID: addr.sheetID), at: addr)
    }

    /// Add a parsed formula (names already expanded) to the graph; nothing
    /// may be installed at `addr`.
    private func install(_ expr: FormulaExpr, at addr: AbsoluteAddress) {
        if expr.hasUnsupportedNames && hasStoredValue(at: addr) { keepStoredValue.insert(addr) }
        asts[addr] = expr
        if expr.isVolatile {
            volatiles.insert(addr)
        }
        var precedents = Precedents()
        for ref in expr.references {
            let sheetID: Int
            if let name = ref.sheetName {
                guard let sheet = workbook.sheet(named: name) else {
                    // #REF! for now; remember it for when the sheet appears.
                    let key = name.lowercased()
                    if !precedents.unresolvedSheets.contains(key) {
                        precedents.unresolvedSheets.append(key)
                        unresolvedSheetReferences[key, default: []].insert(addr)
                    }
                    continue
                }
                sheetID = sheet.id
            } else {
                sheetID = addr.sheetID
            }
            guard let range = ref.concreteRange() else { continue }
            precedents.reach(range, onSheet: sheetID)
            if range.cellCount <= cellEdgeLimit {
                range.forEachAddress { cellAddr in
                    let p = AbsoluteAddress(sheetID: sheetID, address: cellAddr)
                    if dependents[p] == nil {
                        dependents[p] = .one(addr)
                    } else {
                        dependents[p]!.insert(addr)
                    }
                    precedents.cells.append(p)
                }
            } else {
                precedents.rangeIDs.append(rangeIndex.add(sheetID: sheetID, range: range, dependent: addr))
            }
        }
        precedentsIndex[addr] = precedents
    }

    private func removeFormula(at addr: AbsoluteAddress) {
        asts.removeValue(forKey: addr)
        volatiles.remove(addr)
        guard let entry = precedentsIndex.removeValue(forKey: addr) else { return }
        for p in entry.cells {
            if dependents[p]?.remove(addr) == false { dependents.removeValue(forKey: p) }
        }
        for id in entry.rangeIDs {
            rangeIndex.remove(id: id, dependent: addr)
        }
        for name in entry.unresolvedSheets {
            unresolvedSheetReferences[name]?.remove(addr)
            if unresolvedSheetReferences[name]?.isEmpty == true {
                unresolvedSheetReferences.removeValue(forKey: name)
            }
        }
    }

    /// Re-install the formulas whose missing sheet now exists; returns them.
    private func resolvePendingSheetReferences() -> Set<AbsoluteAddress> {
        guard !unresolvedSheetReferences.isEmpty else { return [] }
        var cells = Set<AbsoluteAddress>()
        for (name, waiting) in unresolvedSheetReferences where workbook.sheet(named: name) != nil {
            cells.formUnion(waiting)
        }
        for addr in cells {
            if let text = workbook.sheet(withID: addr.sheetID)?.cells[addr.address]?.formula {
                installFormula(text, at: addr)
            } else {
                removeFormula(at: addr)
            }
        }
        return cells
    }

    // MARK: Recalculation

    /// A vertex of the dependency graph: a cell, or a large range shared by
    /// the formulas that read it. Cells inside the range point at the range
    /// node and the range node at its readers, so n formulas over one range
    /// cost n edges, not n × (formulas inside the range).
    private enum Node: Hashable {
        case cell(AbsoluteAddress)
        case range(Int)
    }

    /// Nodes that read `node` directly.
    private func successors(of node: Node) -> [Node] {
        switch node {
        case .cell(let addr):
            var result: [Node] = []
            dependents[addr]?.append(to: &result)
            var ids: [Int] = []
            rangeIndex.ranges(containing: addr.address, sheetID: addr.sheetID, into: &ids)
            for id in ids { result.append(.range(id)) }
            return result
        case .range(let id):
            return rangeIndex.dependents(of: id).map { .cell($0) }
        }
    }

    /// Recalculate everything affected by changes at `seeds`.
    @discardableResult
    public func recalculate(seeds: Set<AbsoluteAddress>) -> Set<AbsoluteAddress> {
        var roots = seeds
        // A sheet added since the last edit can satisfy waiting formulas.
        roots.formUnion(resolvePendingSheetReferences())
        // Volatile cells recalc on every edit.
        roots.formUnion(volatiles)
        let evaluated = evaluate(roots: roots.map { .cell($0) })
        return evaluated.union(seeds)
    }

    /// Evaluate every formula reachable from `roots`, precedents first.
    ///
    /// One pass of Tarjan's strongly-connected-components algorithm both
    /// finds the cells to recalculate and orders them: it emits components
    /// dependents-first, so they're evaluated in reverse. A component of more
    /// than one node, or a cell reading itself, is a cycle, and every formula
    /// in it gets #CYCLE!, whatever order the walk took; cells downstream of
    /// a cycle evaluate normally and see the error. The walk keeps its own
    /// stack: a chain of formulas (a running total) can be as deep as the
    /// sheet is long, far deeper than the thread's stack.
    @discardableResult
    private func evaluate(roots: [Node]) -> Set<AbsoluteAddress> {
        var indexOf: [Node: Int] = [:]
        var nodes: [Node] = []
        var lowLink: [Int] = []
        var onStack: [Bool] = []
        var readsItself: [Bool] = []
        var componentStack: [Int] = []
        // Components in emission order, each a run of `emitted`.
        var emitted: [Int] = []
        var components: [(start: Int, end: Int, isCycle: Bool)] = []
        var walk: [(node: Int, successors: [Node], next: Int)] = []

        func discover(_ node: Node) {
            let i = nodes.count
            indexOf[node] = i
            nodes.append(node)
            lowLink.append(i)
            onStack.append(true)
            readsItself.append(false)
            componentStack.append(i)
            walk.append((i, successors(of: node), 0))
        }

        for root in roots where indexOf[root] == nil {
            discover(root)
            while !walk.isEmpty {
                let top = walk.count - 1
                let v = walk[top].node
                if walk[top].next < walk[top].successors.count {
                    let w = walk[top].successors[walk[top].next]
                    walk[top].next += 1
                    if let wi = indexOf[w] {
                        if wi == v { readsItself[v] = true }
                        if onStack[wi] { lowLink[v] = min(lowLink[v], wi) }
                    } else {
                        discover(w)
                    }
                    continue
                }
                walk.removeLast()
                if let parent = walk.last {
                    lowLink[parent.node] = min(lowLink[parent.node], lowLink[v])
                }
                if lowLink[v] == v {
                    let start = emitted.count
                    while true {
                        let w = componentStack.removeLast()
                        onStack[w] = false
                        emitted.append(w)
                        if w == v { break }
                    }
                    components.append((start, emitted.count, emitted.count - start > 1 || readsItself[v]))
                }
            }
        }

        var evaluated = Set<AbsoluteAddress>()
        evaluated.reserveCapacity(nodes.count)
        func store(_ value: CellValue, at addr: AbsoluteAddress) {
            guard let sheet = workbook.sheet(withID: addr.sheetID) else { return }
            var cell = sheet.cell(at: addr.address)
            if cell.value != value {
                cell.value = value
                sheet.setCell(cell, at: addr.address)
            }
        }
        for component in components.reversed() {
            for k in component.start..<component.end {
                guard case .cell(let addr) = nodes[emitted[k]], let expr = asts[addr] else { continue }
                // Opened files: a formula we can't evaluate keeps the file's value.
                if keepStoredValue.contains(addr) { evaluated.insert(addr); continue }
                if component.isCycle {
                    store(.error(.circular), at: addr)
                } else {
                    let context = EvalContext(workbook: workbook, sheetID: addr.sheetID,
                                              address: addr.address, clock: clock)
                    store(FormulaEvaluator.evaluate(expr, context: context), at: addr)
                }
                evaluated.insert(addr)
            }
        }
        return evaluated
    }
}
