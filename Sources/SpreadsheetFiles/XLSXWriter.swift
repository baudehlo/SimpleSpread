import Foundation
import SpreadsheetCore

/// Serializes a Workbook to XLSX (OOXML SpreadsheetML, Transitional profile).
///
/// Interop profile (per ECMA-376 and Excel/Numbers/Sheets tolerance testing):
/// - all required parts present, [Content_Types].xml first in the archive
/// - worksheet/workbook/styleSheet children in schema sequence order
/// - fills[0]=none, fills[1]=gray125; cellXfs[0] default; Normal cell style
/// - shared strings for all text cells; formulas carry cached values
public enum XLSXWriter {
    static let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    static let mainNS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let relNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    public static func data(for workbook: Workbook) throws -> Data {
        var zip = ZipArchiveWriter()
        var sharedStrings = SharedStringBuilder()
        let styles = StyleParts(workbook: workbook, extraFormats: generatedPivotFormats(workbook))

        // Worksheets (collect shared strings while writing).
        var sheetXMLs: [Data] = []
        for sheet in workbook.sheets {
            sheetXMLs.append(worksheetXML(sheet: sheet, workbook: workbook,
                                          styles: styles, strings: &sharedStrings))
        }

        // Preserved pivot tables: workbook rel ids follow sheets, styles, sharedStrings.
        let pivots = try pivotPackage(for: workbook, firstWorkbookRelID: workbook.sheets.count + 3,
                                      formatID: styles.numberFormatID)

        zip.addEntry(name: "[Content_Types].xml",
                     data: Data(contentTypesXML(sheetCount: workbook.sheets.count, extra: pivots.contentTypes).utf8))
        zip.addEntry(name: "_rels/.rels", data: Data(rootRelsXML().utf8))
        zip.addEntry(name: "docProps/core.xml", data: Data(corePropsXML().utf8))
        zip.addEntry(name: "docProps/app.xml", data: Data(appPropsXML(workbook: workbook).utf8))
        zip.addEntry(name: "xl/workbook.xml",
                     data: Data(workbookXML(workbook: workbook, pivotCaches: pivots.workbookElement).utf8))
        zip.addEntry(name: "xl/_rels/workbook.xml.rels",
                     data: Data(workbookRelsXML(sheetCount: workbook.sheets.count,
                                                extra: pivots.workbookRelationships).utf8))
        zip.addEntry(name: "xl/styles.xml", data: Data(styles.xml().utf8))
        zip.addEntry(name: "xl/sharedStrings.xml", data: Data(sharedStrings.xml().utf8))
        for (i, xml) in sheetXMLs.enumerated() {
            zip.addEntry(name: "xl/worksheets/sheet\(i + 1).xml", data: xml)
            if let rels = pivots.sheetRelationships[i] {
                zip.addEntry(name: "xl/worksheets/_rels/sheet\(i + 1).xml.rels",
                             data: Data(relationshipsXML(rels).utf8))
            }
        }
        for entry in pivots.entries {
            zip.addEntry(name: entry.path, data: entry.data)
        }
        return try zip.finalize()
    }

    // MARK: Package parts

    static func contentTypesXML(sheetCount: Int,
                                extra: [(partName: String, contentType: String)] = []) -> String {
        var s = xmlHeader
        s += "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        s += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        s += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        s += "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        for i in 1...max(1, sheetCount) {
            s += "<Override PartName=\"/xl/worksheets/sheet\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        s += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        s += "<Override PartName=\"/xl/sharedStrings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml\"/>"
        s += "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
        s += "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"
        for (partName, contentType) in extra {
            s += "<Override PartName=\"\(XML.escapeAttribute(partName))\" ContentType=\"\(contentType)\"/>"
        }
        s += "</Types>"
        return s
    }

    static func rootRelsXML() -> String {
        xmlHeader
        + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
        + "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>"
        + "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/>"
        + "</Relationships>"
    }

    static func corePropsXML() -> String {
        xmlHeader
        + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
        + "<dc:creator>SimpleSpread</dc:creator>"
        + "<cp:lastModifiedBy>SimpleSpread</cp:lastModifiedBy>"
        + "</cp:coreProperties>"
    }

    static func appPropsXML(workbook: Workbook) -> String {
        xmlHeader
        + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\">"
        + "<Application>SimpleSpread</Application>"
        + "</Properties>"
    }

    static func workbookXML(workbook: Workbook, pivotCaches: String = "") -> String {
        var s = xmlHeader
        s += "<workbook xmlns=\"\(mainNS)\" xmlns:r=\"\(relNS)\">"
        s += "<workbookPr date1904=\"0\"/>"
        let shown = firstVisibleSheetIndex(workbook)
        s += "<bookViews><workbookView activeTab=\"\(shown)\"/></bookViews>"
        s += "<sheets>"
        for (i, sheet) in workbook.sheets.enumerated() {
            let state = sheet.isHidden && i != shown ? " state=\"hidden\"" : ""
            s += "<sheet name=\"\(XML.escapeAttribute(sheet.name))\" sheetId=\"\(sheet.id)\"\(state) r:id=\"rId\(i + 1)\"/>"
        }
        s += "</sheets>"
        // Excel names every AutoFilter's range (hidden, sheet-scoped) and
        // writes the name itself on save; we do the same.
        var definedNames = ""
        for (i, sheet) in workbook.sheets.enumerated() {
            guard let filter = sheet.autoFilter else { continue }
            definedNames += "<definedName name=\"_xlnm._FilterDatabase\" localSheetId=\"\(i)\" hidden=\"1\">"
            definedNames += XML.escapeText(ReferenceExpr.quoteSheetNameIfNeeded(sheet.name) + "!"
                                           + absoluteA1(filter.range))
            definedNames += "</definedName>"
        }
        if !definedNames.isEmpty {
            s += "<definedNames>" + definedNames + "</definedNames>"
        }
        s += pivotCaches // CT_Workbook: after sheets/definedNames/calcPr, before extLst
        s += "</workbook>"
        return s
    }

    /// The sheet Excel opens on: the first one not hidden. A workbook needs
    /// one visible sheet, so if all are hidden the first is shown.
    static func firstVisibleSheetIndex(_ workbook: Workbook) -> Int {
        workbook.sheets.firstIndex { !$0.isHidden } ?? 0
    }

    /// "$A$1:$D$20" ("$A$1" for a single cell).
    static func absoluteA1(_ range: CellRange) -> String {
        func absolute(_ a: CellAddress) -> String { "$\(CellAddress.columnName(a.column))$\(a.row + 1)" }
        return range.isSingleCell ? absolute(range.start) : absolute(range.start) + ":" + absolute(range.end)
    }

    static func workbookRelsXML(sheetCount: Int, extra: [PackageRelationship] = []) -> String {
        var s = xmlHeader
        s += "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for i in 1...max(1, sheetCount) {
            s += "<Relationship Id=\"rId\(i)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i).xml\"/>"
        }
        s += "<Relationship Id=\"rId\(sheetCount + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        s += "<Relationship Id=\"rId\(sheetCount + 2)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/>"
        for rel in extra {
            s += "<Relationship Id=\"\(rel.id)\" Type=\"\(rel.type)\" Target=\"\(XML.escapeAttribute(rel.target))\"/>"
        }
        s += "</Relationships>"
        return s
    }

    // MARK: Worksheet

    /// `fastSheetData: false` builds the cells as Strings, the reference
    /// the byte writer is tested against.
    static func worksheetXML(sheet: Sheet, workbook: Workbook,
                             styles: StyleParts, strings: inout SharedStringBuilder,
                             fastSheetData: Bool = true) -> Data {
        var s = xmlHeader
        s += "<worksheet xmlns=\"\(mainNS)\" xmlns:r=\"\(relNS)\">"

        let used = sheet.usedRange
        s += "<dimension ref=\"\(used?.a1 ?? "A1")\"/>"

        // sheetViews (+ frozen panes)
        let shown = firstVisibleSheetIndex(workbook)
        let isFirst = workbook.sheets.indices.contains(shown) && workbook.sheets[shown].id == sheet.id
        s += "<sheetViews><sheetView\(isFirst ? " tabSelected=\"1\"" : "") workbookViewId=\"0\">"
        if sheet.frozenRows > 0 || sheet.frozenColumns > 0 {
            let topLeft = CellAddress(row: sheet.frozenRows, column: sheet.frozenColumns).a1
            let activePane: String
            if sheet.frozenRows > 0 && sheet.frozenColumns > 0 { activePane = "bottomRight" }
            else if sheet.frozenRows > 0 { activePane = "bottomLeft" }
            else { activePane = "topRight" }
            s += "<pane"
            if sheet.frozenColumns > 0 { s += " xSplit=\"\(sheet.frozenColumns)\"" }
            if sheet.frozenRows > 0 { s += " ySplit=\"\(sheet.frozenRows)\"" }
            s += " topLeftCell=\"\(topLeft)\" activePane=\"\(activePane)\" state=\"frozen\"/>"
        }
        s += "</sheetView></sheetViews>"

        // The reader scales Excel's 15pt default to our 22pt; scale back.
        s += "<sheetFormatPr defaultRowHeight=\"\(trimNumber(Double(sheet.defaultRowHeight) * 15.0 / 22.0))\"/>"

        // cols (character-width units; px = width*7 + 5, pt = px * 0.75)
        if !sheet.columnWidths.isEmpty {
            s += "<cols>"
            for (col, points) in sheet.columnWidths.sorted(by: { $0.key < $1.key }) {
                let px = Double(points) / 0.75
                let width = max(0, (px - 5) / 7)
                s += "<col min=\"\(col + 1)\" max=\"\(col + 1)\" width=\"\(trimNumber(width))\" customWidth=\"1\"/>"
            }
            s += "</cols>"
        }

        // sheetData (rows carrying only a custom height or hidden still get written)
        var head = Data()
        var sheetData: [UInt8] = []
        if fastSheetData {
            head = Data(s.utf8)
            s = ""
            sheetData.reserveCapacity(sheet.cells.count * 40)
            appendSheetData(of: sheet, to: &sheetData, strings: &strings)
        } else {
        s += "<sheetData>"
        do {
            var rows: [Int: [(Int, Cell)]] = [:]
            for (addr, cell) in sheet.cells {
                rows[addr.row, default: []].append((addr.column, cell))
            }
            for row in sheet.rowHeights.keys where rows[row] == nil {
                rows[row] = []
            }
            for row in sheet.hiddenRows where rows[row] == nil && row >= 0 && row < CellAddress.maxRows {
                rows[row] = []
            }
            for row in rows.keys.sorted() {
                var rowAttrs = " r=\"\(row + 1)\""
                if let height = sheet.rowHeights[row] {
                    rowAttrs += " ht=\"\(trimNumber(height))\" customHeight=\"1\""
                }
                if sheet.hiddenRows.contains(row) {
                    rowAttrs += " hidden=\"1\""
                }
                s += "<row\(rowAttrs)>"
                for (col, cell) in rows[row]!.sorted(by: { $0.0 < $1.0 }) {
                    s += cellXML(cell, at: CellAddress(row: row, column: col),
                                 styles: styles, strings: &strings)
                }
                s += "</row>"
            }
        }
        s += "</sheetData>"
        }

        // CT_Worksheet: sheetData, sheetCalcPr, sheetProtection,
        // protectedRanges, scenarios, autoFilter, sortState, ..., mergeCells.
        if let filter = sheet.autoFilter {
            s += autoFilterXML(filter)
        }

        // mergeCells
        if !sheet.mergedRanges.isEmpty {
            s += "<mergeCells count=\"\(sheet.mergedRanges.count)\">"
            for range in sheet.mergedRanges {
                s += "<mergeCell ref=\"\(range.a1)\"/>"
            }
            s += "</mergeCells>"
        }

        s += "<pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/>"
        s += "</worksheet>"
        guard fastSheetData else { return Data(s.utf8) }
        var data = head
        data.append(contentsOf: sheetData)
        data.append(Data(s.utf8))
        return data
    }

    /// `<autoFilter>` with a `<filterColumn>` per active column. A column
    /// holds one criterion in XLSX: preserved XML wins, then values, then
    /// conditions.
    static func autoFilterXML(_ filter: AutoFilter) -> String {
        var columns = ""
        for (colID, criteria) in filter.columns.sorted(by: { $0.key < $1.key })
        where criteria.isActive && colID >= 0 && colID < filter.range.columnCount {
            columns += "<filterColumn colId=\"\(colID)\">"
            if let preserved = criteria.preservedXML {
                columns += preserved
            } else if let values = criteria.values {
                let filters = values.sorted().map { "<filter val=\"\(XML.escapeAttribute(XML.encodeIllegalCharacters($0)))\"/>" }
                let blank = criteria.includeBlanks ? " blank=\"1\"" : ""
                columns += filters.isEmpty ? "<filters\(blank)/>" : "<filters\(blank)>" + filters.joined() + "</filters>"
            } else {
                columns += "<customFilters\(criteria.matchAll ? " and=\"1\"" : "")>"
                for condition in criteria.conditions.prefix(2) {
                    let op = condition.op == .equal ? "" : " operator=\"\(condition.op.rawValue)\""
                    columns += "<customFilter\(op) val=\"\(XML.escapeAttribute(condition.value))\"/>"
                }
                columns += "</customFilters>"
            }
            columns += "</filterColumn>"
        }
        let ref = filter.range.a1
        return columns.isEmpty ? "<autoFilter ref=\"\(ref)\"/>" : "<autoFilter ref=\"\(ref)\">" + columns + "</autoFilter>"
    }

    static func cellXML(_ cell: Cell, at addr: CellAddress,
                        styles: StyleParts, strings: inout SharedStringBuilder) -> String {
        let styleAttr = cell.styleIndex > 0 ? " s=\"\(cell.styleIndex)\"" : ""
        var typeAttr = ""
        var body = ""

        func valueBody(for value: CellValue, hasFormula: Bool) {
            switch value {
            case .empty:
                break
            case .number(let n):
                body += "<v>\(serialNumberString(n))</v>"
            case .bool(let b):
                typeAttr = " t=\"b\""
                body += "<v>\(b ? 1 : 0)</v>"
            case .error(let e):
                typeAttr = " t=\"e\""
                body += "<v>\(e.xlsxRepresentation)</v>"
            case .string(let text):
                if hasFormula {
                    typeAttr = " t=\"str\""
                    body += "<v>\(XML.escapeText(XML.encodeIllegalCharacters(text)))</v>"
                } else {
                    typeAttr = " t=\"s\""
                    body += "<v>\(strings.index(for: text))</v>"
                }
            }
        }

        if let formula = cell.formula {
            let f = "<f>\(XML.escapeText(formula))</f>"
            var valuePart = ""
            let saved = body
            _ = saved
            valueBody(for: cell.value, hasFormula: true)
            valuePart = body
            body = f + valuePart
        } else {
            valueBody(for: cell.value, hasFormula: false)
        }

        if body.isEmpty && styleAttr.isEmpty {
            return ""
        }
        return "<c r=\"\(addr.a1)\"\(styleAttr)\(typeAttr)>\(body)</c>"
    }

    /// Full-precision invariant serialization of a double for <v>.
    static func serialNumberString(_ n: Double) -> String {
        if n == n.rounded(), abs(n) < 1e15 {
            return String(Int64(n))
        }
        return "\(n)" // Swift shortest round-trip, '.' decimal separator
    }

    static func trimNumber(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        return String(format: "%.6g", v)
    }

    static func trimNumber(_ v: CGFloat) -> String {
        trimNumber(Double(v))
    }
}

// MARK: - Shared strings

struct SharedStringBuilder {
    private(set) var strings: [String] = []
    private var indexByString: [String: Int] = [:]
    private var totalReferences = 0

    mutating func index(for s: String) -> Int {
        totalReferences += 1
        if let existing = indexByString[s] { return existing }
        strings.append(s)
        indexByString[s] = strings.count - 1
        return strings.count - 1
    }

    func xml() -> String {
        var out = XLSXWriter.xmlHeader
        out += "<sst xmlns=\"\(XLSXWriter.mainNS)\" count=\"\(totalReferences)\" uniqueCount=\"\(strings.count)\">"
        for s in strings {
            let escaped = XML.escapeText(XML.encodeIllegalCharacters(s))
            let needsPreserve = s.hasPrefix(" ") || s.hasSuffix(" ") || s.contains("\n")
                || s.hasPrefix("\t") || s.hasSuffix("\t")
            out += needsPreserve
                ? "<si><t xml:space=\"preserve\">\(escaped)</t></si>"
                : "<si><t>\(escaped)</t></si>"
        }
        out += "</sst>"
        return out
    }
}

// MARK: - Styles part

/// Builds styles.xml with cellXfs indices ALIGNED to the workbook's StyleTable
/// indices (cell s attributes are written straight from Cell.styleIndex).
struct StyleParts {
    private let styles: [CellStyle]
    private var fonts: [String] = []
    private var fills: [String] = []
    private var borders = [StyleParts.borderXML(CellBorders())]
    private var customFormats: [(id: Int, code: String)] = []
    private var xfs: [String] = []
    private let preserved: PreservedStyles?
    /// Format code -> numFmtId for everything written (cells and pivots).
    private(set) var formatIDs: [String: Int] = [:]

    /// The numFmtId a format was written under (0 for General / unknown).
    func numberFormatID(_ format: NumberFormat) -> Int {
        if format.isGeneral { return 0 }
        if let builtin = NumberFormat.builtinID(for: format.code) { return builtin }
        return formatIDs[format.code] ?? 0
    }

    /// `extraFormats`: formats generated pivot parts refer to.
    init(workbook: Workbook, extraFormats: [NumberFormat] = []) {
        styles = workbook.styles.styles
        preserved = workbook.preservedStyles
        var fontIndex: [String: Int] = [:]
        var fillIndex: [String: Int] = [:]
        var borderIndex: [String: Int] = [:]
        // Formats preserved parts refer to keep their ids; ours go above them.
        var nextCustomFormat = 164
        for (id, code) in (preserved?.numberFormats ?? [:]).sorted(by: { $0.key < $1.key }) {
            customFormats.append((id, code))
            if formatIDs[code] == nil { formatIDs[code] = id }
            nextCustomFormat = max(nextCustomFormat, id + 1)
        }
        for id in preserved?.reservedNumberFormatIDs ?? [] {
            nextCustomFormat = max(nextCustomFormat, id + 1)
        }

        // Formats generated pivot parts use (cells reuse the same ids).
        for format in extraFormats where !format.isGeneral && NumberFormat.builtinID(for: format.code) == nil {
            if formatIDs[format.code] == nil {
                formatIDs[format.code] = nextCustomFormat
                customFormats.append((nextCustomFormat, format.code))
                nextCustomFormat += 1
            }
        }

        // Required default fills.
        fills = ["<fill><patternFill patternType=\"none\"/></fill>",
                 "<fill><patternFill patternType=\"gray125\"/></fill>"]

        for style in styles {
            // Font
            var font = "<font>"
            if style.bold { font += "<b/>" }
            if style.italic { font += "<i/>" }
            if style.strikethrough { font += "<strike/>" }
            if style.underline { font += "<u/>" }
            font += "<sz val=\"\(XLSXWriter.trimNumber(style.fontSize ?? 12))\"/>"
            if let color = style.textColor {
                font += "<color rgb=\"\(color.argbHex)\"/>"
            } else {
                font += "<color rgb=\"FF000000\"/>"
            }
            font += "<name val=\"\(XML.escapeAttribute(style.fontName ?? "Calibri"))\"/>"
            font += "</font>"
            let fontID: Int
            if let existing = fontIndex[font] {
                fontID = existing
            } else {
                fonts.append(font)
                fontID = fonts.count - 1
                fontIndex[font] = fontID
            }

            // Fill
            let fillID: Int
            if let fillColor = style.fillColor {
                let fill = "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"\(fillColor.argbHex)\"/><bgColor indexed=\"64\"/></patternFill></fill>"
                if let existing = fillIndex[fill] {
                    fillID = existing
                } else {
                    fills.append(fill)
                    fillID = fills.count - 1
                    fillIndex[fill] = fillID
                }
            } else {
                fillID = 0
            }

            // Border (index 0 is the empty border every xf defaults to)
            let borderID: Int
            if style.borders.isEmpty {
                borderID = 0
            } else {
                let border = Self.borderXML(style.borders)
                if let existing = borderIndex[border] {
                    borderID = existing
                } else {
                    borders.append(border)
                    borderID = borders.count - 1
                    borderIndex[border] = borderID
                }
            }

            // Number format
            let numFmtID: Int
            let code = style.numberFormat.code
            if style.numberFormat.isGeneral {
                numFmtID = 0
            } else if let builtin = NumberFormat.builtinID(for: code) {
                numFmtID = builtin
            } else if let existing = formatIDs[code] {
                numFmtID = existing
            } else {
                numFmtID = nextCustomFormat
                formatIDs[code] = numFmtID
                customFormats.append((numFmtID, code))
                nextCustomFormat += 1
            }

            // xf
            var xf = "<xf numFmtId=\"\(numFmtID)\" fontId=\"\(fontID)\" fillId=\"\(fillID)\" borderId=\"\(borderID)\" xfId=\"0\""
            if numFmtID != 0 { xf += " applyNumberFormat=\"1\"" }
            if fontID != 0 { xf += " applyFont=\"1\"" }
            if fillID != 0 { xf += " applyFill=\"1\"" }
            if borderID != 0 { xf += " applyBorder=\"1\"" }
            if style.pivotButton { xf += " pivotButton=\"1\"" }
            let hasAlignment = style.horizontalAlignment != .automatic
                || style.verticalAlignment != .bottom || style.wrapText || style.indent > 0
            if hasAlignment {
                xf += " applyAlignment=\"1\"><alignment"
                switch style.horizontalAlignment {
                case .automatic: break
                case .left: xf += " horizontal=\"left\""
                case .center: xf += " horizontal=\"center\""
                case .right: xf += " horizontal=\"right\""
                }
                switch style.verticalAlignment {
                case .top: xf += " vertical=\"top\""
                case .middle: xf += " vertical=\"center\""
                case .bottom: break
                }
                if style.wrapText { xf += " wrapText=\"1\"" }
                if style.indent > 0 { xf += " indent=\"\(style.indent)\"" }
                xf += "/></xf>"
            } else {
                xf += "/>"
            }
            xfs.append(xf)
        }
    }

    /// CT_Border: left, right, top, bottom, diagonal in schema order. An
    /// edge with no color is automatic.
    static func borderXML(_ borders: CellBorders) -> String {
        func edge(_ name: String, _ line: BorderLine?) -> String {
            guard let line else { return "<\(name)/>" }
            guard let color = line.color else { return "<\(name) style=\"\(line.style.rawValue)\"/>" }
            return "<\(name) style=\"\(line.style.rawValue)\"><color rgb=\"\(color.argbHex)\"/></\(name)>"
        }
        return "<border>" + edge("left", borders.left) + edge("right", borders.right)
            + edge("top", borders.top) + edge("bottom", borders.bottom) + "<diagonal/></border>"
    }

    func xml() -> String {
        var s = XLSXWriter.xmlHeader
        s += "<styleSheet xmlns=\"\(XLSXWriter.mainNS)\">"
        if !customFormats.isEmpty {
            s += "<numFmts count=\"\(customFormats.count)\">"
            for (id, code) in customFormats {
                s += "<numFmt numFmtId=\"\(id)\" formatCode=\"\(XML.escapeAttribute(code))\"/>"
            }
            s += "</numFmts>"
        }
        s += "<fonts count=\"\(fonts.count)\">" + fonts.joined() + "</fonts>"
        s += "<fills count=\"\(fills.count)\">" + fills.joined() + "</fills>"
        s += "<borders count=\"\(borders.count)\">" + borders.joined() + "</borders>"
        s += "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
        s += "<cellXfs count=\"\(xfs.count)\">" + xfs.joined() + "</cellXfs>"
        s += "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
        // Preserved differential formats keep their positions (pivot dxfIds
        // index into them), then the preserved table styles that use them.
        if let preserved, !preserved.differentialFormats.isEmpty {
            s += "<dxfs count=\"\(preserved.differentialFormats.count)\">"
            s += preserved.differentialFormats.joined()
            s += "</dxfs>"
        }
        if let tableStyles = preserved?.tableStyles {
            s += tableStyles
        }
        s += "</styleSheet>"
        return s
    }
}
