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
    private var dependents: [AbsoluteAddress: Set<AbsoluteAddress>] = [:]
    /// Large-range dependencies, indexed by sheet, column and row.
    private var rangeIndex = RangeDependencyIndex()
    /// Reverse index for edge removal.
    private var precedentsIndex: [AbsoluteAddress: Precedents] = [:]
    /// Cells containing volatile functions (NOW/TODAY/RAND/...).
    private var volatiles: Set<AbsoluteAddress> = []
    /// Formula cells naming a sheet that doesn't exist (yet), by lowercased
    /// sheet name: re-installed when a sheet of that name appears.
    private var unresolvedSheetReferences: [String: Set<AbsoluteAddress>] = [:]

    private struct Precedents {
        var cells: [AbsoluteAddress] = []
        var rangeIDs: [Int] = []
        var unresolvedSheets: [String] = []
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
        asts.removeAll()
        dependents.removeAll()
        rangeIndex.removeAll()
        precedentsIndex.removeAll()
        volatiles.removeAll()
        unresolvedSheetReferences.removeAll()
        // Size the tables once; big imports have a million formulas.
        let formulaCount = workbook.sheets.reduce(0) { total, sheet in
            total + sheet.cells.values.reduce(0) { $0 + ($1.formula == nil ? 0 : 1) }
        }
        asts.reserveCapacity(formulaCount)
        precedentsIndex.reserveCapacity(formulaCount)
        dependents.reserveCapacity(formulaCount * 2)
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

    /// True if the cell currently holds a formula.
    public func hasFormula(at addr: AbsoluteAddress) -> Bool {
        asts[addr] != nil || workbook.sheet(withID: addr.sheetID)?.cells[addr.address]?.formula != nil
    }

    // MARK: Graph maintenance

    private func installFormula(_ text: String, at addr: AbsoluteAddress, replacing: Bool = true) {
        if replacing { removeFormula(at: addr) }
        var expr: FormulaExpr
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
        expr = workbook.expandingDefinedNames(in: expr, sheetID: addr.sheetID)
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
            if range.cellCount <= cellEdgeLimit {
                range.forEachAddress { cellAddr in
                    let p = AbsoluteAddress(sheetID: sheetID, address: cellAddr)
                    dependents[p, default: []].insert(addr)
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
            dependents[p]?.remove(addr)
            if dependents[p]?.isEmpty == true { dependents.removeValue(forKey: p) }
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
            if let cells = dependents[addr] {
                result.reserveCapacity(cells.count)
                for cell in cells { result.append(.cell(cell)) }
            }
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
