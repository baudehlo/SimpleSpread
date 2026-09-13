import Foundation
import SpreadsheetCore

public enum XLSXError: Error, Equatable {
    case invalidPackage(String)
    case invalidXML(String)
}

/// Reads XLSX (OOXML SpreadsheetML) files into a Workbook.
///
/// Robustness profile: parts located via relationships (never hard-coded
/// paths), row/cell r attributes inferred when omitted, rich-text shared
/// strings concatenated, shared formulas expanded, 1904 date system
/// normalized, unknown parts ignored.
public enum XLSXReader {
    public static func read(data: Data) throws -> Workbook {
        let zip = try ZipArchiveReader(data: data)

        // 1. Root rels -> workbook part.
        let rootRels = try parseRelationships(zipData(zip, "_rels/.rels"), baseDir: "")
        guard let workbookPath = rootRels.first(where: {
            $0.type.hasSuffix("/officeDocument")
        })?.target else {
            throw XLSXError.invalidPackage("no officeDocument relationship")
        }

        // 2. Workbook part + its rels.
        let workbookInfo = try parseWorkbook(zipData(zip, workbookPath))
        let workbookDir = directory(of: workbookPath)
        let relsPath = workbookDir.isEmpty
            ? "_rels/\(fileName(of: workbookPath)).rels"
            : "\(workbookDir)/_rels/\(fileName(of: workbookPath)).rels"
        let wbRels = try parseRelationships(zipData(zip, relsPath), baseDir: workbookDir)

        // 3. Shared strings & styles (optional parts).
        var sharedStrings: [String] = []
        if let ssRel = wbRels.first(where: { $0.type.hasSuffix("/sharedStrings") }),
           let ssData = try? zipData(zip, ssRel.target) {
            sharedStrings = try parseSharedStrings(ssData)
        }
        var styleInfos: [ReadStyle] = []
        var customFormats: [Int: String] = [:]
        if let stylesRel = wbRels.first(where: { $0.type.hasSuffix("/styles") }),
           let stylesData = try? zipData(zip, stylesRel.target) {
            (styleInfos, customFormats) = try parseStyles(stylesData)
        }

        // 4. Build workbook, one sheet per workbook.xml <sheet> in order.
        let workbook = Workbook()
        var styleIndexMap: [Int: Int] = [:]
        for (i, info) in styleInfos.enumerated() {
            styleIndexMap[i] = workbook.styles.index(for: info.toCellStyle(customFormats: customFormats))
        }

        for sheetMeta in workbookInfo.sheets {
            guard let rel = wbRels.first(where: { $0.id == sheetMeta.relID }) else { continue }
            let sheet = workbook.insertSheet(
                Sheet(id: max(1, sheetMeta.sheetID), name: sheetMeta.name),
                at: workbook.sheets.count)
            // Guard against duplicate ids from odd files.
            if workbook.sheets.filter({ $0.id == sheet.id }).count > 1 {
                workbook.removeSheet(withID: sheet.id)
                let replacement = workbook.addSheet(named: sheetMeta.name)
                try parseWorksheet(zipData(zip, rel.target), into: replacement,
                                   sharedStrings: sharedStrings, styleIndexMap: styleIndexMap)
                continue
            }
            try parseWorksheet(zipData(zip, rel.target), into: sheet,
                               sharedStrings: sharedStrings, styleIndexMap: styleIndexMap)
        }

        if workbook.sheets.isEmpty {
            workbook.addSheet()
        }

        // 5. 1904 date system: shift date-formatted numerics into 1900 serials.
        if workbookInfo.date1904 {
            for sheet in workbook.sheets {
                for (addr, cell) in sheet.cells {
                    guard case .number(let n) = cell.value else { continue }
                    let style = workbook.style(at: cell.styleIndex)
                    if style.numberFormat.isDateTime {
                        var updated = cell
                        updated.value = .number(n + ExcelDate.date1904Offset)
                        sheet.setCell(updated, at: addr)
                    }
                }
            }
        }
        return workbook
    }

    // MARK: Path helpers

    static func zipData(_ zip: ZipArchiveReader, _ path: String) throws -> Data {
        try zip.contents(named: path)
    }

    static func directory(of path: String) -> String {
        guard let idx = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<idx])
    }

    static func fileName(of path: String) -> String {
        guard let idx = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: idx)...])
    }

    /// Resolve a rels target against a base directory, handling absolute
    /// targets ("/xl/...") and ".." segments.
    static func resolveTarget(_ target: String, baseDir: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = baseDir.isEmpty ? [] : baseDir.split(separator: "/").map(String.init)
        for component in target.split(separator: "/") {
            if component == ".." { if !parts.isEmpty { parts.removeLast() } }
            else if component != "." { parts.append(String(component)) }
        }
        return parts.joined(separator: "/")
    }

    // MARK: Relationships

    struct Relationship {
        let id: String
        let type: String
        let target: String
    }

    static func parseRelationships(_ data: Data, baseDir: String) throws -> [Relationship] {
        final class Delegate: NSObject, XMLParserDelegate {
            var rels: [(String, String, String)] = []
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                if localName(name) == "Relationship",
                   let id = attributes["Id"], let type = attributes["Type"],
                   let target = attributes["Target"] {
                    rels.append((id, type, target))
                }
            }
        }
        let delegate = Delegate()
        try runParser(data, delegate: delegate)
        return delegate.rels.map {
            Relationship(id: $0.0, type: $0.1, target: resolveTarget($0.2, baseDir: baseDir))
        }
    }

    // MARK: Workbook part

    struct WorkbookInfo {
        struct SheetMeta {
            let name: String
            let sheetID: Int
            let relID: String
        }
        var sheets: [SheetMeta] = []
        var date1904 = false
    }

    static func parseWorkbook(_ data: Data) throws -> WorkbookInfo {
        final class Delegate: NSObject, XMLParserDelegate {
            var info = WorkbookInfo()
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                switch localName(name) {
                case "workbookPr":
                    let v = attributes["date1904"]?.lowercased()
                    info.date1904 = v == "1" || v == "true"
                case "sheet":
                    guard let sheetName = attributes["name"] else { return }
                    let relID = attributes["r:id"] ?? attributes.first { $0.key.hasSuffix(":id") }?.value ?? ""
                    let sheetID = Int(attributes["sheetId"] ?? "") ?? (info.sheets.count + 1)
                    let state = attributes["state"] ?? "visible"
                    _ = state // hidden sheets still loaded
                    info.sheets.append(.init(name: sheetName, sheetID: sheetID, relID: relID))
                default:
                    break
                }
            }
        }
        let delegate = Delegate()
        try runParser(data, delegate: delegate)
        guard !delegate.info.sheets.isEmpty else {
            throw XLSXError.invalidPackage("workbook has no sheets")
        }
        return delegate.info
    }

    // MARK: Shared strings

    static func parseSharedStrings(_ data: Data) throws -> [String] {
        final class Delegate: NSObject, XMLParserDelegate {
            var strings: [String] = []
            var current = ""
            var inSI = false
            var inT = false
            var inPhonetic = false
            var text = ""

            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                switch localName(name) {
                case "si": inSI = true; current = ""
                case "rPh": inPhonetic = true
                case "t": if inSI && !inPhonetic { inT = true; text = "" }
                default: break
                }
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if inT { text += string }
            }

            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                        qualifiedName: String?) {
                switch localName(name) {
                case "t":
                    if inT { current += text; inT = false }
                case "rPh":
                    inPhonetic = false
                case "si":
                    strings.append(XML.decodeIllegalCharacters(current))
                    inSI = false
                default:
                    break
                }
            }
        }
        let delegate = Delegate()
        try runParser(data, delegate: delegate)
        return delegate.strings
    }

    // MARK: Styles

    struct ReadFont {
        var bold = false, italic = false, underline = false, strike = false
        var size: Double?
        var name: String?
        var colorARGB: String?
    }

    struct ReadStyle {
        var numFmtID = 0
        var fontID = 0
        var fillID = 0
        var horizontal: TextAlignmentH = .automatic
        var vertical: TextAlignmentV = .bottom
        var wrapText = false
        var font: ReadFont?
        var fillARGB: String?

        func toCellStyle(customFormats: [Int: String]) -> CellStyle {
            var style = CellStyle()
            if let f = font {
                style.bold = f.bold
                style.italic = f.italic
                style.underline = f.underline
                style.strikethrough = f.strike
                style.fontSize = f.size
                style.fontName = f.name
                if let argb = f.colorARGB, argb.uppercased() != "FF000000" {
                    style.textColor = RGBAColor(argbHex: argb)
                }
            }
            if let fill = fillARGB {
                style.fillColor = RGBAColor(argbHex: fill)
            }
            style.horizontalAlignment = horizontal
            style.verticalAlignment = vertical
            style.wrapText = wrapText
            if numFmtID != 0 {
                if let custom = customFormats[numFmtID] {
                    style.numberFormat = NumberFormat(code: custom)
                } else if let builtin = NumberFormat.builtin(numFmtID) {
                    style.numberFormat = builtin
                } else if numFmtID >= 27 && numFmtID <= 36 {
                    style.numberFormat = .date // East Asian date ids: treat as date
                }
            }
            // Normalize defaults: Calibri 11/12 with no attributes == default.
            if style.fontName == "Calibri" { style.fontName = nil }
            if style.fontSize == 11 || style.fontSize == 12 { style.fontSize = nil }
            return style
        }
    }

    static func parseStyles(_ data: Data) throws -> ([ReadStyle], [Int: String]) {
        final class Delegate: NSObject, XMLParserDelegate {
            var customFormats: [Int: String] = [:]
            var fonts: [ReadFont] = []
            var fills: [String?] = []
            var xfs: [ReadStyle] = []

            var inFonts = false, inFills = false, inCellXfs = false
            var currentFont: ReadFont?
            var currentFillIsSolid = false
            var currentFillColor: String?
            var currentXf: ReadStyle?

            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                switch localName(name) {
                case "numFmt":
                    if let id = Int(attributes["numFmtId"] ?? ""), let code = attributes["formatCode"] {
                        customFormats[id] = code
                    }
                case "fonts": inFonts = true
                case "fills": inFills = true
                case "cellXfs": inCellXfs = true
                case "font": if inFonts { currentFont = ReadFont() }
                case "b": if currentFont != nil, boolAttr(attributes["val"], default: true) { currentFont?.bold = true }
                case "i": if currentFont != nil, boolAttr(attributes["val"], default: true) { currentFont?.italic = true }
                case "u":
                    if currentFont != nil {
                        let v = attributes["val"] ?? "single"
                        if v != "none" { currentFont?.underline = true }
                    }
                case "strike": if currentFont != nil, boolAttr(attributes["val"], default: true) { currentFont?.strike = true }
                case "sz": if currentFont != nil { currentFont?.size = Double(attributes["val"] ?? "") }
                case "name": if inFonts { currentFont?.name = attributes["val"] }
                case "color":
                    if currentFont != nil, let rgb = attributes["rgb"] { currentFont?.colorARGB = rgb }
                case "fill": if inFills { currentFillIsSolid = false; currentFillColor = nil }
                case "patternFill":
                    if inFills { currentFillIsSolid = (attributes["patternType"] == "solid") }
                case "fgColor":
                    if inFills, currentFillIsSolid, let rgb = attributes["rgb"] { currentFillColor = rgb }
                case "xf":
                    if inCellXfs {
                        var xf = ReadStyle()
                        xf.numFmtID = Int(attributes["numFmtId"] ?? "") ?? 0
                        xf.fontID = Int(attributes["fontId"] ?? "") ?? 0
                        xf.fillID = Int(attributes["fillId"] ?? "") ?? 0
                        currentXf = xf
                    }
                case "alignment":
                    if currentXf != nil {
                        switch attributes["horizontal"] {
                        case "left": currentXf?.horizontal = .left
                        case "center", "centerContinuous": currentXf?.horizontal = .center
                        case "right": currentXf?.horizontal = .right
                        default: break
                        }
                        switch attributes["vertical"] {
                        case "top": currentXf?.vertical = .top
                        case "center": currentXf?.vertical = .middle
                        default: break
                        }
                        if boolAttr(attributes["wrapText"], default: false) { currentXf?.wrapText = true }
                    }
                default:
                    break
                }
            }

            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                        qualifiedName: String?) {
                switch localName(name) {
                case "fonts": inFonts = false
                case "fills": inFills = false
                case "cellXfs": inCellXfs = false
                case "font":
                    if inFonts, let f = currentFont { fonts.append(f); currentFont = nil }
                case "fill":
                    if inFills { fills.append(currentFillIsSolid ? currentFillColor : nil) }
                case "xf":
                    if inCellXfs, var xf = currentXf {
                        if xf.fontID >= 0 && xf.fontID < fonts.count { xf.font = fonts[xf.fontID] }
                        if xf.fillID >= 2 && xf.fillID < fills.count { xf.fillARGB = fills[xf.fillID] }
                        xfs.append(xf)
                        currentXf = nil
                    }
                default:
                    break
                }
            }
        }
        let delegate = Delegate()
        try runParser(data, delegate: delegate)
        return (delegate.xfs, delegate.customFormats)
    }

    // MARK: Worksheet

    static func parseWorksheet(_ data: Data, into sheet: Sheet,
                               sharedStrings: [String], styleIndexMap: [Int: Int]) throws {
        final class Delegate: NSObject, XMLParserDelegate {
            let sheet: Sheet
            let sharedStrings: [String]
            let styleIndexMap: [Int: Int]

            var currentRow = -1        // 0-based row of the <row> being parsed
            var nextColumn = 0         // inferred column for r-less cells
            var cellAddress: CellAddress?
            var cellType = ""
            var cellStyleIndex = 0
            var valueText = ""
            var formulaText: String?
            var inV = false, inF = false, inIS = false, inIST = false
            var inlineText = ""
            // Shared formulas: si -> (master address, formula text)
            var sharedFormulas: [String: (CellAddress, String)] = [:]
            var currentSharedSI: String?
            var currentFormulaIsShared = false

            init(sheet: Sheet, sharedStrings: [String], styleIndexMap: [Int: Int]) {
                self.sheet = sheet
                self.sharedStrings = sharedStrings
                self.styleIndexMap = styleIndexMap
            }

            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                switch localName(name) {
                case "row":
                    if let r = Int(attributes["r"] ?? ""), r >= 1 {
                        currentRow = r - 1
                    } else {
                        currentRow += 1
                    }
                    nextColumn = 0
                    if let ht = Double(attributes["ht"] ?? ""),
                       boolAttr(attributes["customHeight"], default: false) || attributes["ht"] != nil {
                        sheet.rowHeights[currentRow] = CGFloat(ht)
                    }
                case "c":
                    if let a1 = attributes["r"], let addr = CellAddress(a1: a1) {
                        cellAddress = addr
                        nextColumn = addr.column + 1
                        if currentRow < 0 { currentRow = addr.row }
                    } else {
                        cellAddress = CellAddress(row: max(0, currentRow), column: nextColumn)
                        nextColumn += 1
                    }
                    cellType = attributes["t"] ?? "n"
                    cellStyleIndex = Int(attributes["s"] ?? "") ?? 0
                    valueText = ""
                    formulaText = nil
                    inlineText = ""
                    currentSharedSI = nil
                    currentFormulaIsShared = false
                case "v":
                    inV = true
                    valueText = ""
                case "f":
                    inF = true
                    formulaText = ""
                    currentFormulaIsShared = (attributes["t"] == "shared")
                    currentSharedSI = attributes["si"]
                case "is":
                    inIS = true
                case "t":
                    if inIS { inIST = true }
                case "col":
                    if let minCol = Int(attributes["min"] ?? ""), let maxCol = Int(attributes["max"] ?? ""),
                       let width = Double(attributes["width"] ?? "") {
                        // width chars -> px -> points
                        let px = width * 7 + 5
                        let points = CGFloat(px * 0.75)
                        for col in minCol...min(maxCol, minCol + 4096) {
                            sheet.columnWidths[col - 1] = points
                        }
                    }
                case "mergeCell":
                    if let ref = attributes["ref"], let range = CellRange(a1: ref), !range.isSingleCell {
                        sheet.mergedRanges.append(range)
                    }
                case "pane":
                    if attributes["state"] == "frozen" || attributes["state"] == "frozenSplit" {
                        sheet.frozenColumns = Int(attributes["xSplit"] ?? "") ?? 0
                        sheet.frozenRows = Int(attributes["ySplit"] ?? "") ?? 0
                    }
                case "sheetFormatPr":
                    if let h = Double(attributes["defaultRowHeight"] ?? "") {
                        sheet.defaultRowHeight = CGFloat(max(12, h * (22.0 / 15.0)))
                    }
                default:
                    break
                }
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if inV { valueText += string }
                else if inF { formulaText = (formulaText ?? "") + string }
                else if inIST { inlineText += string }
            }

            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                        qualifiedName: String?) {
                switch localName(name) {
                case "v": inV = false
                case "f":
                    inF = false
                    if currentFormulaIsShared, let si = currentSharedSI, let addr = cellAddress {
                        if let text = formulaText, !text.isEmpty {
                            sharedFormulas[si] = (addr, text)
                        } else if let (masterAddr, masterText) = sharedFormulas[si] {
                            // Follower: translate the master formula by the offset.
                            formulaText = XLSXReader.translateFormula(
                                masterText,
                                byRows: addr.row - masterAddr.row,
                                columns: addr.column - masterAddr.column)
                        }
                    }
                case "t": inIST = false
                case "is": inIS = false
                case "c":
                    commitCell()
                default:
                    break
                }
            }

            func commitCell() {
                guard let addr = cellAddress, addr.isValid else { return }
                var value = CellValue.empty
                switch cellType {
                case "n":
                    if let n = Double(valueText) { value = .number(n) }
                case "s":
                    if let idx = Int(valueText), idx >= 0, idx < sharedStrings.count {
                        value = .string(sharedStrings[idx])
                    }
                case "str":
                    value = .string(XML.decodeIllegalCharacters(valueText))
                case "b":
                    value = .bool(valueText == "1" || valueText.lowercased() == "true")
                case "e":
                    value = .error(CellError.parse(valueText) ?? .value)
                case "inlineStr":
                    value = .string(XML.decodeIllegalCharacters(inlineText))
                case "d":
                    if let serial = XLSXReader.isoDateToSerial(valueText) { value = .number(serial) }
                default:
                    if let n = Double(valueText) { value = .number(n) }
                }
                let mappedStyle = styleIndexMap[cellStyleIndex] ?? 0
                let cell = Cell(value: value, formula: formulaText.flatMap { $0.isEmpty ? nil : $0 },
                                styleIndex: mappedStyle)
                if !cell.isDefault {
                    sheet.setCell(cell, at: addr)
                }
                cellAddress = nil
            }
        }

        let delegate = Delegate(sheet: sheet, sharedStrings: sharedStrings, styleIndexMap: styleIndexMap)
        try runParser(data, delegate: delegate)
    }

    /// Translate a shared-formula master by a row/column offset.
    static func translateFormula(_ text: String, byRows rows: Int, columns: Int) -> String {
        WorkbookOperations.translatedFormula(text, byRows: rows, columns: columns)
    }

    static func isoDateToSerial(_ s: String) -> Double? {
        let parts = s.split(separator: "T", maxSplits: 1)
        let dateParts = parts[0].split(separator: "-")
        guard dateParts.count == 3,
              let y = Int(dateParts[0]), let m = Int(dateParts[1]), let d = Int(dateParts[2]) else {
            return nil
        }
        var serial = ExcelDate.serial(year: y, month: m, day: d)
        if parts.count > 1 {
            let timeParts = parts[1].split(separator: ":")
            if timeParts.count >= 2 {
                let h = Int(timeParts[0]) ?? 0
                let min = Int(timeParts[1]) ?? 0
                let sec = timeParts.count > 2 ? (Double(timeParts[2].prefix(while: { $0.isNumber || $0 == "." })) ?? 0) : 0
                serial += ExcelDate.timeFraction(hour: h, minute: min, second: sec)
            }
        }
        return serial
    }

    // MARK: Parse helpers

    static func runParser(_ data: Data, delegate: XMLParserDelegate) throws {
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else {
            let line = parser.parserError.map { " (\($0.localizedDescription))" } ?? ""
            throw XLSXError.invalidXML("XML parse failure\(line)")
        }
    }
}

/// Strip any namespace prefix ("x:worksheet" -> "worksheet").
private func localName(_ elementName: String) -> String {
    if let idx = elementName.lastIndex(of: ":") {
        return String(elementName[elementName.index(after: idx)...])
    }
    return elementName
}

private func boolAttr(_ value: String?, default def: Bool) -> Bool {
    guard let v = value?.lowercased() else { return def }
    return v == "1" || v == "true"
}
