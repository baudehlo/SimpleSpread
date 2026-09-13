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
    /// Large-range dependencies: sheetID -> [(range, dependent formula cell)].
    private var rangeDependents: [Int: [(range: CellRange, dependent: AbsoluteAddress)]] = [:]
    /// Reverse index for edge removal.
    private var precedentsIndex: [AbsoluteAddress: (cells: [AbsoluteAddress], ranges: [(Int, CellRange)])] = [:]
    /// Cells containing volatile functions (NOW/TODAY/RAND/...).
    private var volatiles: Set<AbsoluteAddress> = []

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
        rangeDependents.removeAll()
        precedentsIndex.removeAll()
        volatiles.removeAll()
        for sheet in workbook.sheets {
            for (address, cell) in sheet.cells {
                if let formula = cell.formula {
                    installFormula(formula, at: AbsoluteAddress(sheetID: sheet.id, address: address))
                }
            }
        }
        recalculateAll()
    }

    /// Recalculate every formula cell.
    @discardableResult
    public func recalculateAll() -> Set<AbsoluteAddress> {
        evaluate(dirty: Set(asts.keys))
    }

    /// True if the cell currently holds a formula.
    public func hasFormula(at addr: AbsoluteAddress) -> Bool {
        asts[addr] != nil || workbook.sheet(withID: addr.sheetID)?.cells[addr.address]?.formula != nil
    }

    // MARK: Graph maintenance

    private func installFormula(_ text: String, at addr: AbsoluteAddress) {
        removeFormula(at: addr)
        let expr: FormulaExpr
        do {
            expr = try FormulaParser.parse(text)
        } catch {
            // Sheets-style: commit the formula, value is #ERROR!.
            if let sheet = workbook.sheet(withID: addr.sheetID) {
                var cell = sheet.cell(at: addr.address)
                cell.value = .error(.parse)
                sheet.setCell(cell, at: addr.address)
            }
            return
        }
        asts[addr] = expr
        if expr.isVolatile {
            volatiles.insert(addr)
        }
        var cellEdges: [AbsoluteAddress] = []
        var rangeEdges: [(Int, CellRange)] = []
        for ref in expr.references {
            let sheetID: Int
            if let name = ref.sheetName {
                guard let sheet = workbook.sheet(named: name) else { continue }
                sheetID = sheet.id
            } else {
                sheetID = addr.sheetID
            }
            guard let range = ref.concreteRange() else { continue }
            if range.cellCount <= cellEdgeLimit {
                range.forEachAddress { cellAddr in
                    let p = AbsoluteAddress(sheetID: sheetID, address: cellAddr)
                    dependents[p, default: []].insert(addr)
                    cellEdges.append(p)
                }
            } else {
                rangeDependents[sheetID, default: []].append((range, addr))
                rangeEdges.append((sheetID, range))
            }
        }
        precedentsIndex[addr] = (cellEdges, rangeEdges)
    }

    private func removeFormula(at addr: AbsoluteAddress) {
        asts.removeValue(forKey: addr)
        volatiles.remove(addr)
        guard let entry = precedentsIndex.removeValue(forKey: addr) else { return }
        for p in entry.cells {
            dependents[p]?.remove(addr)
            if dependents[p]?.isEmpty == true { dependents.removeValue(forKey: p) }
        }
        for (sheetID, range) in entry.ranges {
            rangeDependents[sheetID]?.removeAll { $0.range == range && $0.dependent == addr }
        }
    }

    // MARK: Recalculation

    /// Cells whose formulas directly depend on `addr`.
    private func directDependents(of addr: AbsoluteAddress) -> Set<AbsoluteAddress> {
        var result = dependents[addr] ?? []
        if let ranges = rangeDependents[addr.sheetID] {
            for (range, dependent) in ranges where range.contains(addr.address) {
                result.insert(dependent)
            }
        }
        return result
    }

    /// Recalculate everything affected by changes at `seeds`.
    @discardableResult
    public func recalculate(seeds: Set<AbsoluteAddress>) -> Set<AbsoluteAddress> {
        // Collect the transitive dependent closure.
        var dirty = Set<AbsoluteAddress>()
        var queue = Array(seeds)
        var enqueued = seeds
        // Volatile cells recalc on every edit.
        for v in volatiles where !enqueued.contains(v) {
            queue.append(v)
            enqueued.insert(v)
        }
        while let addr = queue.popLast() {
            if asts[addr] != nil { dirty.insert(addr) }
            for dep in directDependents(of: addr) where !enqueued.contains(dep) {
                enqueued.insert(dep)
                queue.append(dep)
            }
        }
        let evaluated = evaluate(dirty: dirty)
        return evaluated.union(seeds)
    }

    /// Evaluate a dirty set in dependency order with cycle detection.
    @discardableResult
    private func evaluate(dirty: Set<AbsoluteAddress>) -> Set<AbsoluteAddress> {
        var evaluated = Set<AbsoluteAddress>()
        var visiting = Set<AbsoluteAddress>()
        var changed = Set<AbsoluteAddress>()

        func dirtyPrecedents(of addr: AbsoluteAddress) -> [AbsoluteAddress] {
            guard let expr = asts[addr] else { return [] }
            var result: [AbsoluteAddress] = []
            for ref in expr.references {
                let sheetID: Int
                if let name = ref.sheetName {
                    guard let sheet = workbook.sheet(named: name) else { continue }
                    sheetID = sheet.id
                } else {
                    sheetID = addr.sheetID
                }
                guard let range = ref.concreteRange() else { continue }
                if range.cellCount <= cellEdgeLimit {
                    range.forEachAddress { cellAddr in
                        let p = AbsoluteAddress(sheetID: sheetID, address: cellAddr)
                        if dirty.contains(p) { result.append(p) }
                    }
                } else {
                    for d in dirty where d.sheetID == sheetID && range.contains(d.address) {
                        result.append(d)
                    }
                }
            }
            return result
        }

        func store(_ value: CellValue, at addr: AbsoluteAddress) {
            guard let sheet = workbook.sheet(withID: addr.sheetID) else { return }
            var cell = sheet.cell(at: addr.address)
            if cell.value != value {
                cell.value = value
                sheet.setCell(cell, at: addr.address)
                changed.insert(addr)
            }
        }

        func visit(_ addr: AbsoluteAddress) {
            if evaluated.contains(addr) { return }
            if visiting.contains(addr) {
                // Cycle: this cell gets the circular error; dependents will
                // propagate it naturally.
                store(.error(.circular), at: addr)
                evaluated.insert(addr)
                return
            }
            visiting.insert(addr)
            for p in dirtyPrecedents(of: addr) where p != addr {
                visit(p)
            }
            // Self-reference is immediately circular.
            if dirtyPrecedents(of: addr).contains(addr) {
                store(.error(.circular), at: addr)
                visiting.remove(addr)
                evaluated.insert(addr)
                return
            }
            if !evaluated.contains(addr), let expr = asts[addr] {
                let context = EvalContext(workbook: workbook, sheetID: addr.sheetID,
                                          address: addr.address, clock: clock)
                let value = FormulaEvaluator.evaluate(expr, context: context)
                store(value, at: addr)
            }
            visiting.remove(addr)
            evaluated.insert(addr)
        }

        for addr in dirty {
            visit(addr)
        }
        return changed.union(evaluated)
    }
}
