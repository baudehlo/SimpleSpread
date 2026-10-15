import Foundation

/// The engine's large-range dependencies (ranges too big for per-cell edges),
/// indexed so "which ranges contain this cell?" costs O(log n + k), not a scan
/// of every range on the sheet.
///
/// Identical ranges share one entry (n formulas filled down over
/// `$A$2:$A$50000` are one entry with n dependents), and each entry has a
/// stable integer id the engine uses as a node in its dependency graph.
///
/// Per sheet, a range at most `narrowColumnLimit` columns wide is filed under
/// each of its columns; wider ones (whole rows, big blocks) share one bucket
/// and are filtered by column after the row lookup. Each bucket answers row
/// lookups with an interval tree, rebuilt lazily after its ranges change.
struct RangeDependencyIndex: Sendable {
    struct Entry: Sendable {
        let sheetID: Int
        let range: CellRange
        var dependents: Set<AbsoluteAddress>
    }

    private struct Key: Hashable, Sendable {
        let sheetID: Int
        let range: CellRange
    }

    private struct Bucket: Sendable {
        var members: Set<Int> = []
        var tree: IntervalTree?
    }

    private struct SheetIndex: Sendable {
        var columns: [Int: Bucket] = [:]
        var wide = Bucket()
    }

    static let narrowColumnLimit = 32

    private var entries: [Entry?] = []
    private var freeIDs: [Int] = []
    private var ids: [Key: Int] = [:]
    private var sheets: [Int: SheetIndex] = [:]

    mutating func removeAll() {
        entries.removeAll()
        freeIDs.removeAll()
        ids.removeAll()
        sheets.removeAll()
    }

    /// Record that `dependent` reads `range` on `sheetID`; returns the entry id.
    @discardableResult
    mutating func add(sheetID: Int, range: CellRange, dependent: AbsoluteAddress) -> Int {
        let key = Key(sheetID: sheetID, range: range)
        if let id = ids[key] {
            entries[id]!.dependents.insert(dependent)
            return id
        }
        let id: Int
        let entry = Entry(sheetID: sheetID, range: range, dependents: [dependent])
        if let reused = freeIDs.popLast() {
            id = reused
            entries[id] = entry
        } else {
            id = entries.count
            entries.append(entry)
        }
        ids[key] = id
        updateBuckets(sheetID: sheetID, range: range) { bucket in
            bucket.members.insert(id)
            bucket.tree = nil
        }
        return id
    }

    /// Forget that `dependent` reads entry `id`; drops the entry when unused.
    mutating func remove(id: Int, dependent: AbsoluteAddress) {
        guard id < entries.count, entries[id] != nil else { return }
        entries[id]!.dependents.remove(dependent)
        guard entries[id]!.dependents.isEmpty else { return }
        let entry = entries[id]!
        entries[id] = nil
        freeIDs.append(id)
        ids.removeValue(forKey: Key(sheetID: entry.sheetID, range: entry.range))
        updateBuckets(sheetID: entry.sheetID, range: entry.range) { bucket in
            bucket.members.remove(id)
            bucket.tree = nil
        }
    }

    func dependents(of id: Int) -> Set<AbsoluteAddress> {
        entries[id]?.dependents ?? []
    }

    /// Append the ids of every range on `sheetID` that contains `address`.
    mutating func ranges(containing address: CellAddress, sheetID: Int, into out: inout [Int]) {
        guard sheets[sheetID] != nil else { return }
        if sheets[sheetID]!.columns[address.column] != nil {
            Self.ensureTree(&sheets[sheetID]!.columns[address.column]!, entries: entries)
            sheets[sheetID]!.columns[address.column]!.tree!.stab(address.row, into: &out)
        }
        if !sheets[sheetID]!.wide.members.isEmpty {
            Self.ensureTree(&sheets[sheetID]!.wide, entries: entries)
            let start = out.count
            sheets[sheetID]!.wide.tree!.stab(address.row, into: &out)
            // The tree matched rows only; keep the ranges spanning the column.
            var kept = start
            for i in start..<out.count {
                let range = entries[out[i]]!.range
                if address.column >= range.start.column && address.column <= range.end.column {
                    out[kept] = out[i]
                    kept += 1
                }
            }
            out.removeSubrange(kept...)
        }
    }

    private mutating func updateBuckets(sheetID: Int, range: CellRange, _ change: (inout Bucket) -> Void) {
        var sheet = sheets.removeValue(forKey: sheetID) ?? SheetIndex()
        if range.columnCount <= Self.narrowColumnLimit {
            for column in range.start.column...range.end.column {
                var bucket = sheet.columns.removeValue(forKey: column) ?? Bucket()
                change(&bucket)
                if !bucket.members.isEmpty { sheet.columns[column] = bucket }
            }
        } else {
            change(&sheet.wide)
        }
        if !sheet.columns.isEmpty || !sheet.wide.members.isEmpty {
            sheets[sheetID] = sheet
        }
    }

    private static func ensureTree(_ bucket: inout Bucket, entries: [Entry?]) {
        guard bucket.tree == nil else { return }
        bucket.tree = IntervalTree(bucket.members.map { id in
            let range = entries[id]!.range
            return IntervalTree.Interval(low: range.start.row, high: range.end.row, id: id)
        })
    }
}

/// A static centred interval tree: built once from closed intervals, then
/// answers "which intervals contain x?" in O(log n + k). Depth is O(log n), so
/// the recursive build can't run deep.
struct IntervalTree: Sendable {
    struct Interval: Sendable {
        let low: Int
        let high: Int
        let id: Int
    }

    private struct Node: Sendable {
        let center: Int
        /// Intervals containing `center`, by ascending `low` ...
        let byLow: [Interval]
        /// ... and the same intervals by descending `high`.
        let byHigh: [Interval]
        var left: Int
        var right: Int
    }

    private var nodes: [Node] = []
    private var root = -1

    init(_ intervals: [Interval]) {
        root = build(intervals)
    }

    private mutating func build(_ intervals: [Interval]) -> Int {
        guard !intervals.isEmpty else { return -1 }
        // The median midpoint puts at most half the intervals on each side.
        var mids = intervals.map { ($0.low + $0.high) / 2 }
        let k = mids.count / 2
        mids.sort()
        let center = mids[k]
        var left: [Interval] = [], right: [Interval] = [], here: [Interval] = []
        for interval in intervals {
            if interval.high < center {
                left.append(interval)
            } else if interval.low > center {
                right.append(interval)
            } else {
                here.append(interval)
            }
        }
        let index = nodes.count
        nodes.append(Node(center: center,
                          byLow: here.sorted { $0.low < $1.low },
                          byHigh: here.sorted { $0.high > $1.high },
                          left: -1, right: -1))
        let l = build(left)
        let r = build(right)
        nodes[index].left = l
        nodes[index].right = r
        return index
    }

    /// Append the id of every interval containing `x`.
    func stab(_ x: Int, into out: inout [Int]) {
        var n = root
        while n >= 0 {
            let node = nodes[n]
            if x < node.center {
                for interval in node.byLow {
                    if interval.low > x { break }
                    out.append(interval.id)
                }
                n = node.left
            } else if x > node.center {
                for interval in node.byHigh {
                    if interval.high < x { break }
                    out.append(interval.id)
                }
                n = node.right
            } else {
                for interval in node.byLow { out.append(interval.id) }
                return
            }
        }
    }
}
