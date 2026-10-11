import Foundation

// A typed model of a pivot table and its cache: what the pivot engine
// computes from and what the writer regenerates XML from. It mirrors the
// SpreadsheetML pivot schema closely (ECMA-376 §18.10) so values read from
// a file can be written back without loss for the parts it covers; anything
// it doesn't cover stays in the preserved XML (see PivotTables.swift).

/// One value in a pivot cache (a shared item or an inline record value).
public enum PivotValue: Hashable, Sendable {
    case missing
    case number(Double)
    case string(String)
    case bool(Bool)
    /// A date/time as a serial number (1900 system, as cells use).
    case date(Double)
    case error(CellError)

    /// The cell value this item shows as.
    public var cellValue: CellValue {
        switch self {
        case .missing: return .empty
        case .number(let n), .date(let n): return .number(n)
        case .string(let s): return .string(s)
        case .bool(let b): return .bool(b)
        case .error(let e): return .error(e)
        }
    }
}

/// Grouping on a cache field (Excel "Group": date parts, numeric ranges,
/// or hand-made groups of items).
public struct PivotFieldGroup: Equatable, Sendable {
    public enum GroupBy: String, Sendable {
        case range, seconds, minutes, hours, days, months, quarters, years
    }

    /// Range grouping (numbers or dates).
    public struct Range: Equatable, Sendable {
        public var groupBy: GroupBy
        public var autoStart: Bool
        public var autoEnd: Bool
        public var startNumber: Double?
        public var endNumber: Double?
        public var startDate: Double?
        public var endDate: Double?
        public var interval: Double

        public init(groupBy: GroupBy, autoStart: Bool = true, autoEnd: Bool = true,
                    startNumber: Double? = nil, endNumber: Double? = nil,
                    startDate: Double? = nil, endDate: Double? = nil, interval: Double = 1) {
            self.groupBy = groupBy
            self.autoStart = autoStart
            self.autoEnd = autoEnd
            self.startNumber = startNumber
            self.endNumber = endNumber
            self.startDate = startDate
            self.endDate = endDate
            self.interval = interval
        }
    }

    /// Index of the parent grouping field (a further level), if any.
    public var parent: Int?
    /// Index of the field whose values are grouped.
    public var base: Int?
    public var range: Range?
    /// Discrete grouping: for each item of the base field, the group it falls in.
    public var discreteMap: [Int]
    /// The group items (labels).
    public var items: [PivotValue]

    public init(parent: Int? = nil, base: Int? = nil, range: Range? = nil,
                discreteMap: [Int] = [], items: [PivotValue] = []) {
        self.parent = parent
        self.base = base
        self.range = range
        self.discreteMap = discreteMap
        self.items = items
    }
}

/// A field (column) of the cache.
public struct PivotCacheField: Equatable, Sendable {
    public var name: String
    public var numberFormat: NumberFormat
    /// Distinct values, when the cache lists them (records then index them).
    public var sharedItems: [PivotValue]
    /// Calculated field formula (over other fields' names), if calculated.
    public var formula: String?
    /// False for calculated and grouping-only fields (no source column).
    public var isDatabaseField: Bool
    public var group: PivotFieldGroup?

    /// The items a pivot field's `<item x>` indexes: the group items for a
    /// grouping field, else the shared items. (A field that is only the base
    /// of a grouping has a fieldGroup with a parent and no items of its own.)
    public var axisItems: [PivotValue] {
        if let items = group?.items, !items.isEmpty { return items }
        return sharedItems
    }

    public init(name: String, numberFormat: NumberFormat = .general, sharedItems: [PivotValue] = [],
                formula: String? = nil, isDatabaseField: Bool = true, group: PivotFieldGroup? = nil) {
        self.name = name
        self.numberFormat = numberFormat
        self.sharedItems = sharedItems
        self.formula = formula
        self.isDatabaseField = isDatabaseField
        self.group = group
    }
}

/// A record value: an index into the field's shared items, or inline.
public enum PivotRecordValue: Hashable, Sendable {
    case shared(Int)
    case value(PivotValue)
}

/// The cache's data: fields and records.
public struct PivotCacheData: Equatable, Sendable {
    public var fields: [PivotCacheField]
    /// One entry per source row; each holds one value per database field.
    public var records: [[PivotRecordValue]]

    public init(fields: [PivotCacheField], records: [[PivotRecordValue]]) {
        self.fields = fields
        self.records = records
    }

    /// The value of database field `field` in record `record`.
    public func value(record: Int, field: Int) -> PivotValue {
        guard record < records.count, field < records[record].count else { return .missing }
        switch records[record][field] {
        case .value(let v): return v
        case .shared(let i):
            let items = fields[field].sharedItems
            return i >= 0 && i < items.count ? items[i] : .missing
        }
    }
}

/// How a data field summarizes (Excel's "Summarize Values By").
public enum PivotSubtotal: String, CaseIterable, Sendable {
    case sum, count, average, max, min, product, countNums, stdDev, stdDevp, `var`, varp

    /// Display name as in Excel's captions ("Sum of Sales").
    public var caption: String {
        switch self {
        case .sum: return "Sum"
        case .count: return "Count"
        case .average: return "Average"
        case .max: return "Max"
        case .min: return "Min"
        case .product: return "Product"
        case .countNums: return "Count"
        case .stdDev: return "StdDev"
        case .stdDevp: return "StdDevp"
        case .var: return "Var"
        case .varp: return "Varp"
        }
    }
}

/// Excel's "Show Values As".
public enum PivotShowDataAs: String, CaseIterable, Sendable {
    case normal, difference, percent, percentDiff, runTotal, percentOfRow, percentOfCol,
         percentOfTotal, index, percentOfParentRow, percentOfParentCol, percentOfParent,
         percentOfRunningTotal, rankAscending, rankDescending
}

/// An item of a pivot field as listed in the pivot table definition.
public struct PivotItem: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case data, `default`, sum, countA, avg, max, min, product, count, stdDev, stdDevP, `var`, varP,
             grand, blank
    }
    public var kind: Kind
    /// For data items: index into the field's shared (or group) items.
    public var index: Int?
    public var hidden: Bool
    /// Show details (expanded); false collapses the item.
    public var showDetails: Bool
    /// Custom caption.
    public var name: String?

    public init(kind: Kind = .data, index: Int? = nil, hidden: Bool = false,
                showDetails: Bool = true, name: String? = nil) {
        self.kind = kind
        self.index = index
        self.hidden = hidden
        self.showDetails = showDetails
        self.name = name
    }
}

/// A pivot field's settings in the table (one per cache field).
public struct PivotFieldSettings: Equatable, Sendable {
    public enum Axis: String, Sendable { case row = "axisRow", column = "axisCol", page = "axisPage", values = "axisValues" }
    public enum Sort: String, Sendable { case manual, ascending, descending }

    public var axis: Axis?
    public var isDataField: Bool
    public var items: [PivotItem]
    public var sort: Sort
    /// Subtotal functions shown for this field (empty = none).
    public var subtotals: [PivotItem.Kind]
    public var compact: Bool
    public var outline: Bool
    public var subtotalTop: Bool
    public var insertBlankRow: Bool
    public var showAll: Bool
    /// Custom field caption.
    public var name: String?
    public var numberFormat: NumberFormat?
    public var multipleItemSelectionAllowed: Bool

    public init(axis: Axis? = nil, isDataField: Bool = false, items: [PivotItem] = [],
                sort: Sort = .manual, subtotals: [PivotItem.Kind] = [.default],
                compact: Bool = true, outline: Bool = true, subtotalTop: Bool = true,
                insertBlankRow: Bool = false, showAll: Bool = false, name: String? = nil,
                numberFormat: NumberFormat? = nil, multipleItemSelectionAllowed: Bool = false) {
        self.axis = axis
        self.isDataField = isDataField
        self.items = items
        self.sort = sort
        self.subtotals = subtotals
        self.compact = compact
        self.outline = outline
        self.subtotalTop = subtotalTop
        self.insertBlankRow = insertBlankRow
        self.showAll = showAll
        self.name = name
        self.numberFormat = numberFormat
        self.multipleItemSelectionAllowed = multipleItemSelectionAllowed
    }
}

/// A value field (Excel's "Values" area).
public struct PivotDataField: Equatable, Sendable {
    public var name: String
    public var field: Int
    public var subtotal: PivotSubtotal
    public var showDataAs: PivotShowDataAs
    public var baseField: Int
    public var baseItem: Int
    public var numberFormat: NumberFormat?

    public init(name: String, field: Int, subtotal: PivotSubtotal = .sum,
                showDataAs: PivotShowDataAs = .normal, baseField: Int = 0, baseItem: Int = 0,
                numberFormat: NumberFormat? = nil) {
        self.name = name
        self.field = field
        self.subtotal = subtotal
        self.showDataAs = showDataAs
        self.baseField = baseField
        self.baseItem = baseItem
        self.numberFormat = numberFormat
    }
}

/// A report filter.
public struct PivotPageField: Equatable, Sendable {
    public var field: Int
    /// Index into the field's items of the single selected item; nil = all
    /// (or several, when items are hidden).
    public var selectedItem: Int?

    public init(field: Int, selectedItem: Int? = nil) {
        self.field = field
        self.selectedItem = selectedItem
    }
}

/// One line of a pivot axis as Excel encodes it (rowItems/colItems `<i>`).
public struct PivotAxisLine: Equatable, Sendable {
    /// `<i t>`: data (a normal line), a subtotal kind, `grand` or `blank`.
    public var kind: PivotItem.Kind
    /// `<i r>`: leading members repeated from the previous line.
    public var repeated: Int
    /// `<i i>`: data field index (with several values fields).
    public var dataFieldIndex: Int
    /// `<x v>` values: positions in each axis field's item list (after the
    /// repeated ones).
    public var members: [Int]

    public init(kind: PivotItem.Kind = .data, repeated: Int = 0, dataFieldIndex: Int = 0, members: [Int] = []) {
        self.kind = kind
        self.repeated = repeated
        self.dataFieldIndex = dataFieldIndex
        self.members = members
    }
}

/// Table-level layout and caption settings.
public struct PivotLayout: Equatable, Sendable {
    public var compact: Bool
    public var compactData: Bool
    public var outline: Bool
    public var outlineData: Bool
    public var gridDropZones: Bool
    public var rowGrandTotals: Bool
    public var colGrandTotals: Bool
    public var dataOnRows: Bool
    /// Position of the Values field among the axis fields, if set.
    public var dataPosition: Int?
    public var showHeaders: Bool
    public var dataCaption: String
    public var grandTotalCaption: String?
    public var rowHeaderCaption: String?
    public var colHeaderCaption: String?
    public var errorCaption: String?
    public var showError: Bool
    public var missingCaption: String?
    public var showMissing: Bool
    public var indent: Int
    public var mergeItem: Bool

    public init(compact: Bool = true, compactData: Bool = true, outline: Bool = false,
                outlineData: Bool = false, gridDropZones: Bool = false, rowGrandTotals: Bool = true,
                colGrandTotals: Bool = true, dataOnRows: Bool = false, dataPosition: Int? = nil,
                showHeaders: Bool = true, dataCaption: String = "Values", grandTotalCaption: String? = nil,
                rowHeaderCaption: String? = nil, colHeaderCaption: String? = nil,
                errorCaption: String? = nil, showError: Bool = false, missingCaption: String? = nil,
                showMissing: Bool = true, indent: Int = 1, mergeItem: Bool = false) {
        self.compact = compact
        self.compactData = compactData
        self.outline = outline
        self.outlineData = outlineData
        self.gridDropZones = gridDropZones
        self.rowGrandTotals = rowGrandTotals
        self.colGrandTotals = colGrandTotals
        self.dataOnRows = dataOnRows
        self.dataPosition = dataPosition
        self.showHeaders = showHeaders
        self.dataCaption = dataCaption
        self.grandTotalCaption = grandTotalCaption
        self.rowHeaderCaption = rowHeaderCaption
        self.colHeaderCaption = colHeaderCaption
        self.errorCaption = errorCaption
        self.showError = showError
        self.missingCaption = missingCaption
        self.showMissing = showMissing
        self.indent = indent
        self.mergeItem = mergeItem
    }
}

/// The index Excel uses for the Values pseudo-field in row/column fields.
public let pivotValuesFieldIndex = -2

/// A pivot table's definition, typed.
public struct PivotDefinition: Equatable, Sendable {
    public var name: String
    public var fields: [PivotFieldSettings]
    public var rowFields: [Int]
    public var columnFields: [Int]
    public var pageFields: [PivotPageField]
    public var dataFields: [PivotDataField]
    public var layout: PivotLayout
    /// Axis lines as last laid out (what the file says; the engine recomputes).
    public var rowLines: [PivotAxisLine]
    public var columnLines: [PivotAxisLine]
    public var styleName: String?

    public init(name: String, fields: [PivotFieldSettings], rowFields: [Int] = [], columnFields: [Int] = [],
                pageFields: [PivotPageField] = [], dataFields: [PivotDataField] = [],
                layout: PivotLayout = PivotLayout(), rowLines: [PivotAxisLine] = [],
                columnLines: [PivotAxisLine] = [], styleName: String? = "PivotStyleLight16") {
        self.name = name
        self.fields = fields
        self.rowFields = rowFields
        self.columnFields = columnFields
        self.pageFields = pageFields
        self.dataFields = dataFields
        self.layout = layout
        self.rowLines = rowLines
        self.columnLines = columnLines
        self.styleName = styleName
    }
}
