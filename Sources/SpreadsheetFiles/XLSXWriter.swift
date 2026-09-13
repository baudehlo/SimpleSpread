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
        let styles = StyleParts(workbook: workbook)

        // Worksheets (collect shared strings while writing).
        var sheetXMLs: [String] = []
        for sheet in workbook.sheets {
            sheetXMLs.append(worksheetXML(sheet: sheet, workbook: workbook,
                                          styles: styles, strings: &sharedStrings))
        }

        zip.addEntry(name: "[Content_Types].xml", data: Data(contentTypesXML(sheetCount: workbook.sheets.count).utf8))
        zip.addEntry(name: "_rels/.rels", data: Data(rootRelsXML().utf8))
        zip.addEntry(name: "docProps/core.xml", data: Data(corePropsXML().utf8))
        zip.addEntry(name: "docProps/app.xml", data: Data(appPropsXML(workbook: workbook).utf8))
        zip.addEntry(name: "xl/workbook.xml", data: Data(workbookXML(workbook: workbook).utf8))
        zip.addEntry(name: "xl/_rels/workbook.xml.rels", data: Data(workbookRelsXML(sheetCount: workbook.sheets.count).utf8))
        zip.addEntry(name: "xl/styles.xml", data: Data(styles.xml().utf8))
        zip.addEntry(name: "xl/sharedStrings.xml", data: Data(sharedStrings.xml().utf8))
        for (i, xml) in sheetXMLs.enumerated() {
            zip.addEntry(name: "xl/worksheets/sheet\(i + 1).xml", data: Data(xml.utf8))
        }
        return zip.finalize()
    }

    // MARK: Package parts

    static func contentTypesXML(sheetCount: Int) -> String {
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

    static func workbookXML(workbook: Workbook) -> String {
        var s = xmlHeader
        s += "<workbook xmlns=\"\(mainNS)\" xmlns:r=\"\(relNS)\">"
        s += "<workbookPr date1904=\"0\"/>"
        s += "<bookViews><workbookView activeTab=\"0\"/></bookViews>"
        s += "<sheets>"
        for (i, sheet) in workbook.sheets.enumerated() {
            s += "<sheet name=\"\(XML.escapeAttribute(sheet.name))\" sheetId=\"\(sheet.id)\" r:id=\"rId\(i + 1)\"/>"
        }
        s += "</sheets>"
        s += "</workbook>"
        return s
    }

    static func workbookRelsXML(sheetCount: Int) -> String {
        var s = xmlHeader
        s += "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for i in 1...max(1, sheetCount) {
            s += "<Relationship Id=\"rId\(i)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i).xml\"/>"
        }
        s += "<Relationship Id=\"rId\(sheetCount + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        s += "<Relationship Id=\"rId\(sheetCount + 2)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/>"
        s += "</Relationships>"
        return s
    }

    // MARK: Worksheet

    static func worksheetXML(sheet: Sheet, workbook: Workbook,
                             styles: StyleParts, strings: inout SharedStringBuilder) -> String {
        var s = xmlHeader
        s += "<worksheet xmlns=\"\(mainNS)\" xmlns:r=\"\(relNS)\">"

        let used = sheet.usedRange
        s += "<dimension ref=\"\(used?.a1 ?? "A1")\"/>"

        // sheetViews (+ frozen panes)
        let isFirst = workbook.sheets.first?.id == sheet.id
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

        s += "<sheetFormatPr defaultRowHeight=\"\(trimNumber(sheet.defaultRowHeight))\"/>"

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

        // sheetData (rows carrying only a custom height still get written)
        s += "<sheetData>"
        do {
            var rows: [Int: [(Int, Cell)]] = [:]
            for (addr, cell) in sheet.cells {
                rows[addr.row, default: []].append((addr.column, cell))
            }
            for row in sheet.rowHeights.keys where rows[row] == nil {
                rows[row] = []
            }
            for row in rows.keys.sorted() {
                var rowAttrs = " r=\"\(row + 1)\""
                if let height = sheet.rowHeights[row] {
                    rowAttrs += " ht=\"\(trimNumber(height))\" customHeight=\"1\""
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
        return s
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
    private var customFormats: [(id: Int, code: String)] = []
    private var xfs: [String] = []

    init(workbook: Workbook) {
        styles = workbook.styles.styles
        var fontIndex: [String: Int] = [:]
        var fillIndex: [String: Int] = [:]
        var formatIDs: [String: Int] = [:]
        var nextCustomFormat = 164

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
            var xf = "<xf numFmtId=\"\(numFmtID)\" fontId=\"\(fontID)\" fillId=\"\(fillID)\" borderId=\"0\" xfId=\"0\""
            if numFmtID != 0 { xf += " applyNumberFormat=\"1\"" }
            if fontID != 0 { xf += " applyFont=\"1\"" }
            if fillID != 0 { xf += " applyFill=\"1\"" }
            let hasAlignment = style.horizontalAlignment != .automatic
                || style.verticalAlignment != .bottom || style.wrapText
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
                xf += "/></xf>"
            } else {
                xf += "/>"
            }
            xfs.append(xf)
        }
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
        s += "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
        s += "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
        s += "<cellXfs count=\"\(xfs.count)\">" + xfs.joined() + "</cellXfs>"
        s += "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
        s += "</styleSheet>"
        return s
    }
}
