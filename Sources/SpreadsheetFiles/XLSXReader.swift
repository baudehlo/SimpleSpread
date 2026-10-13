import Foundation
import SpreadsheetCore

public enum XLSXError: Error, Equatable {
    case invalidPackage(String)
    case invalidXML(String)
    /// The progress callback asked to stop.
    case cancelled
}

/// Reads XLSX (OOXML SpreadsheetML) files into a Workbook.
///
/// Robustness profile: parts located via relationships (never hard-coded
/// paths), row/cell r attributes inferred when omitted, rich-text shared
/// strings concatenated, shared formulas expanded, 1904 date system
/// normalized, unknown parts ignored.
public enum XLSXReader {
    public static func read(data: Data) throws -> Workbook {
        var report = XLSXReadReport()
        return try read(data: data, report: &report)
    }

    /// Read with progress: `progress` gets the fraction of sheet data read
    /// so far; returning false stops the read with `XLSXError.cancelled`.
    public static func read(data: Data, progress: @escaping (Double) -> Bool) throws -> Workbook {
        var report = XLSXReadReport()
        return try read(data: data, report: &report, progress: progress)
    }

    /// Read with progress (as above), also listing what the file holds that
    /// saving will not write back ("3 charts", "comments", …; empty when
    /// nothing is lost).
    public static func read(data: Data, unsupportedContent: inout [String],
                            progress: ((Double) -> Bool)?) throws -> Workbook {
        var report = XLSXReadReport()
        let workbook = try read(data: data, report: &report, progress: progress)
        unsupportedContent = report.unsupportedContent
        return workbook
    }

    /// Read, also reporting what couldn't be carried over (for tests and
    /// diagnostics). `fastSheetData: false` reads cells with XMLParser, the
    /// reference the fast scanner is tested against.
    static func read(data: Data, report: inout XLSXReadReport,
                     progress: ((Double) -> Bool)? = nil, fastSheetData: Bool = true) throws -> Workbook {
        let zip = try ZipArchiveReader(data: data)
        var unsupported = UnsupportedContent.scanPackage(zip)

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
            var richText = false
            sharedStrings = try parseSharedStrings(ssData, richText: &richText)
            if richText { unsupported.add(.richText) }
        }
        var styleInfos: [ReadStyle] = []
        var customFormats: [Int: String] = [:]
        var stylesData: Data?
        if let stylesRel = wbRels.first(where: { $0.type.hasSuffix("/styles") }),
           let data = try? zipData(zip, stylesRel.target) {
            stylesData = data
            (styleInfos, customFormats) = try parseStyles(data)
        }

        // 4. Build workbook, one sheet per workbook.xml <sheet> in order.
        let workbook = Workbook()
        var styleIndexMap: [Int: Int] = [:]
        for (i, info) in styleInfos.enumerated() {
            styleIndexMap[i] = workbook.styles.index(for: info.toCellStyle(customFormats: customFormats))
        }

        // Progress is the share of worksheet bytes read, weighted by size.
        let sheetSizes = workbookInfo.sheets.map { meta -> Int in
            guard let rel = wbRels.first(where: { $0.id == meta.relID }) else { return 0 }
            return zip.entry(named: rel.target)?.uncompressedSize ?? 0
        }
        let totalSize = max(1, sheetSizes.reduce(0, +))
        var doneSize = 0
        var sheetParts: [SheetPart] = []
        for (sheetIndex, sheetMeta) in workbookInfo.sheets.enumerated() {
            let size = sheetSizes[sheetIndex]
            let sheetProgress: ((Double) -> Bool)? = progress.map { report in
                { fraction in report((Double(doneSize) + fraction * Double(size)) / Double(totalSize)) }
            }
            defer { doneSize += size }
            guard let rel = wbRels.first(where: { $0.id == sheetMeta.relID }) else { continue }
            var sheet = workbook.insertSheet(
                Sheet(id: max(1, sheetMeta.sheetID), name: sheetMeta.name),
                at: workbook.sheets.count)
            // Guard against duplicate ids from odd files.
            if workbook.sheets.filter({ $0.id == sheet.id }).count > 1 {
                workbook.removeSheet(withID: sheet.id)
                sheet = workbook.addSheet(named: sheetMeta.name)
            }
            sheet.isHidden = sheetMeta.state == "hidden" || sheetMeta.state == "veryHidden"
            if sheetMeta.state == "veryHidden" { unsupported.add(.veryHiddenSheets) }
            let found = try parseWorksheet(zipData(zip, rel.target), into: sheet,
                                           sharedStrings: sharedStrings, styleIndexMap: styleIndexMap,
                                           progress: sheetProgress, fastSheetData: fastSheetData)
            unsupported.formUnion(found)
            sheetParts.append(SheetPart(sheetID: sheet.id, sheetIndex: sheetIndex, path: rel.target))
        }

        if workbook.sheets.isEmpty {
            workbook.addSheet()
        }

        // 4b. Defined names (the AutoFilter's own name is rebuilt on save).
        workbook.definedNames = definedNames(workbookInfo.definedNames, sheetParts: sheetParts)

        // 5. Pivot tables (definitions only; their cells are already loaded).
        report.droppedPivots = readPivotTables(PivotReadContext(
            zip: zip, workbookInfo: workbookInfo, workbookRels: wbRels, sheetParts: sheetParts,
            stylesData: stylesData, customFormats: customFormats), into: workbook)
        workbook.clearStrayPivotButtons() // buttons of pivots not kept
        unsupported.add(.pivotTables, count: report.droppedPivots.filter { $0.tableName != nil }.count)
        unsupported.formUnion(workbookInfo.unsupported)
        report.unsupportedContent = unsupported.descriptions

        // 6. 1904 date system: shift date-formatted numerics into 1900 serials.
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

    /// The model's defined names: sheet scopes by sheet id, formulas
    /// without '=' or `_xlfn.` prefixes. Names scoped to a sheet that wasn't
    /// loaded are dropped.
    static func definedNames(_ names: [WorkbookInfo.DefinedName], sheetParts: [SheetPart]) -> [DefinedName] {
        names.compactMap { defined in
            guard defined.name.caseInsensitiveCompare("_xlnm._FilterDatabase") != .orderedSame else { return nil }
            var scope: Int?
            if let local = defined.localSheetIndex {
                guard let part = sheetParts.first(where: { $0.sheetIndex == local }) else { return nil }
                scope = part.sheetID
            }
            var formula = defined.formula.trimmingCharacters(in: .whitespacesAndNewlines)
            if formula.hasPrefix("=") { formula.removeFirst() }
            return DefinedName(name: defined.name, scopeSheetID: scope,
                               formula: FormulaFunctionPrefixes.stripped(formula), hidden: defined.hidden)
        }
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
        /// Package path for internal targets; the URI as written for external.
        let target: String
        var isExternal = false
    }

    static func parseRelationships(_ data: Data, baseDir: String) throws -> [Relationship] {
        final class Delegate: NSObject, XMLParserDelegate {
            var rels: [(String, String, String, Bool)] = []
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                if localName(name) == "Relationship",
                   let id = attributes["Id"], let type = attributes["Type"],
                   let target = attributes["Target"] {
                    rels.append((id, type, target, attributes["TargetMode"] == "External"))
                }
            }
        }
        let delegate = Delegate()
        try runParser(data, delegate: delegate)
        return delegate.rels.map {
            Relationship(id: $0.0, type: $0.1,
                         target: $0.3 ? $0.2 : resolveTarget($0.2, baseDir: baseDir),
                         isExternal: $0.3)
        }
    }

    /// The rels part belonging to `partPath` ("xl/a/b.xml" -> "xl/a/_rels/b.xml.rels").
    static func relsPath(for partPath: String) -> String {
        let dir = directory(of: partPath)
        let file = fileName(of: partPath)
        return dir.isEmpty ? "_rels/\(file).rels" : "\(dir)/_rels/\(file).rels"
    }

    /// A part's relationships; empty when it has no rels part.
    static func relationships(of partPath: String, in zip: ZipArchiveReader) throws -> [Relationship] {
        guard zip.entry(named: relsPath(for: partPath)) != nil else { return [] }
        return try parseRelationships(zipData(zip, relsPath(for: partPath)), baseDir: directory(of: partPath))
    }

    // MARK: Workbook part

    struct WorkbookInfo {
        struct SheetMeta {
            let name: String
            let sheetID: Int
            let relID: String
            /// "visible", "hidden" or "veryHidden".
            var state = "visible"
        }
        struct PivotCacheMeta {
            let cacheID: Int
            let relID: String
        }
        struct DefinedName {
            let name: String
            /// Index into `sheets` for a sheet-scoped name; nil = workbook scope.
            let localSheetIndex: Int?
            let formula: String
            var hidden = false
        }
        var sheets: [SheetMeta] = []
        var date1904 = false
        var pivotCaches: [PivotCacheMeta] = []
        var definedNames: [DefinedName] = []
        /// Workbook-level settings that are not written back.
        var unsupported: Set<UnsupportedContent.Kind> = []
    }

    static func parseWorkbook(_ data: Data) throws -> WorkbookInfo {
        final class Delegate: NSObject, XMLParserDelegate {
            var info = WorkbookInfo()
            var depth = 0
            var inPivotCaches = false
            var definedName: (name: String, local: Int?, hidden: Bool)?
            var definedNameText = ""
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                depth += 1
                // Only the main list (workbook/pivotCaches); extLst lists
                // (x14/x15 slicer, timeline, data model caches) are separate.
                if depth == 2 && localName(name) == "pivotCaches" { inPivotCaches = true }
                switch localName(name) {
                case "pivotCache" where inPivotCaches && depth == 3:
                    let relID = attributes["r:id"] ?? attributes.first { $0.key.hasSuffix(":id") }?.value
                    if let id = Int(attributes["cacheId"] ?? ""), let relID {
                        info.pivotCaches.append(.init(cacheID: id, relID: relID))
                    }
                case "definedName":
                    if let n = attributes["name"] {
                        let hidden = attributes["hidden"].map { $0 == "1" || $0.lowercased() == "true" } ?? false
                        definedName = (n, Int(attributes["localSheetId"] ?? ""), hidden)
                        definedNameText = ""
                    }
                case "workbookPr":
                    let v = attributes["date1904"]?.lowercased()
                    info.date1904 = v == "1" || v == "true"
                case "sheet":
                    guard let sheetName = attributes["name"] else { return }
                    let relID = attributes["r:id"] ?? attributes.first { $0.key.hasSuffix(":id") }?.value ?? ""
                    // CT_Sheet@sheetId is an unsignedInt; anything else gets a fresh id.
                    let given = Int(attributes["sheetId"] ?? "").flatMap { (1...Int(UInt32.max)).contains($0) ? $0 : nil }
                    let sheetID = given ?? (info.sheets.count + 1)
                    info.sheets.append(.init(name: sheetName, sheetID: sheetID, relID: relID,
                                             state: attributes["state"] ?? "visible"))
                case "workbookProtection" where depth == 2:
                    let locks = ["lockStructure", "lockWindows", "lockRevision"]
                    if locks.contains(where: { boolAttr(attributes[$0], default: false) }) {
                        info.unsupported.insert(.workbookProtection)
                    }
                case "customWorkbookViews" where depth == 2:
                    info.unsupported.insert(.customViews)
                default:
                    break
                }
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if definedName != nil { definedNameText += string }
            }

            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                        qualifiedName: String?) {
                if depth == 2 && localName(name) == "pivotCaches" { inPivotCaches = false }
                depth -= 1
                if localName(name) == "definedName", let (n, local, hidden) = definedName {
                    info.definedNames.append(.init(name: n, localSheetIndex: local, formula: definedNameText,
                                                   hidden: hidden))
                    definedName = nil
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
        var richText = false
        return try parseSharedStrings(data, richText: &richText)
    }

    /// `richText`: set when a string has formatted runs (only the text is kept).
    static func parseSharedStrings(_ data: Data, richText: inout Bool) throws -> [String] {
        final class Delegate: NSObject, XMLParserDelegate {
            var richText = false
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
                case "rPr": if inSI && !inPhonetic { richText = true }
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
        richText = richText || delegate.richText
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
        var pivotButton = false
        var indent = 0
        var borderID = 0
        var borders = CellBorders()

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
            style.pivotButton = pivotButton
            style.indent = min(max(0, indent), 250) // Excel's limit
            style.borders = borders
            if numFmtID != 0 {
                if let custom = customFormats[numFmtID] {
                    // A custom "General" is General (the writer maps both to id 0).
                    let format = NumberFormat(code: custom)
                    style.numberFormat = format.isGeneral ? .general : format
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
            var borders: [CellBorders] = []
            var xfs: [ReadStyle] = []

            var inNumFmts = false, inFonts = false, inFills = false, inCellXfs = false
            var inBorders = false
            var currentBorder: CellBorders?
            /// The edge being read: its side and line (nil = no line).
            var currentEdge: (side: String, line: BorderLine?)?
            var currentFont: ReadFont?
            var currentFillIsSolid = false
            var currentFillColor: String?
            var currentXf: ReadStyle?

            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                switch localName(name) {
                case "numFmts": inNumFmts = true
                case "numFmt":
                    // Only the stylesheet's table: a <dxf> carries its own
                    // numFmt whose id may collide with a real one.
                    if inNumFmts, let id = Int(attributes["numFmtId"] ?? ""), let code = attributes["formatCode"] {
                        customFormats[id] = code
                    }
                case "fonts": inFonts = true
                case "fills": inFills = true
                case "cellXfs": inCellXfs = true
                case "borders": inBorders = true
                case "border": if inBorders { currentBorder = CellBorders() }
                case "left", "right", "top", "bottom", "start", "end":
                    // Only the stylesheet's table: a <dxf> has its own <border>.
                    if currentBorder != nil {
                        let style = attributes["style"].flatMap(BorderLineStyle.init(rawValue:))
                        currentEdge = (localName(name), style.map { BorderLine($0) })
                    }
                case "font": if inFonts { currentFont = ReadFont() }
                case "b": if currentFont != nil, boolAttr(attributes["val"], default: true) { currentFont?.bold = true }
                case "i": if currentFont != nil, boolAttr(attributes["val"], default: true) { currentFont?.italic = true }
                case "u":
                    if currentFont != nil {
                        let v = attributes["val"] ?? "single"
                        if v != "none" { currentFont?.underline = true }
                    }
                case "strike": if currentFont != nil, boolAttr(attributes["val"], default: true) { currentFont?.strike = true }
                case "sz":
                    // Excel's sizes run 1-409 points.
                    if currentFont != nil, let size = Double(attributes["val"] ?? ""), size.isFinite {
                        currentFont?.size = min(max(size, 1), 409)
                    }
                case "name": if inFonts { currentFont?.name = attributes["val"] }
                case "color":
                    if currentFont != nil, let rgb = attributes["rgb"] { currentFont?.colorARGB = rgb }
                    // Theme, indexed and auto colors read as automatic.
                    if currentEdge?.line != nil, let rgb = attributes["rgb"] {
                        currentEdge?.line?.color = RGBAColor(argbHex: rgb)
                    }
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
                        xf.pivotButton = boolAttr(attributes["pivotButton"], default: false)
                        // Excel applies a cellXfs borderId whatever applyBorder says.
                        xf.borderID = Int(attributes["borderId"] ?? "") ?? 0
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
                        if let indent = Int(attributes["indent"] ?? "") { currentXf?.indent = indent }
                    }
                default:
                    break
                }
            }

            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                        qualifiedName: String?) {
                switch localName(name) {
                case "numFmts": inNumFmts = false
                case "fonts": inFonts = false
                case "fills": inFills = false
                case "cellXfs": inCellXfs = false
                case "borders": inBorders = false
                case "border":
                    if inBorders, let border = currentBorder { borders.append(border); currentBorder = nil }
                case "left", "right", "top", "bottom", "start", "end":
                    // Never let an empty edge clear one set by its start/end twin.
                    if let edge = currentEdge, currentBorder != nil, edge.line != nil {
                        switch edge.side {
                        case "left", "start": currentBorder?.left = edge.line
                        case "right", "end": currentBorder?.right = edge.line
                        case "top": currentBorder?.top = edge.line
                        default: currentBorder?.bottom = edge.line
                        }
                        currentEdge = nil
                    }
                case "font":
                    if inFonts, let f = currentFont { fonts.append(f); currentFont = nil }
                case "fill":
                    if inFills { fills.append(currentFillIsSolid ? currentFillColor : nil) }
                case "xf":
                    if inCellXfs, var xf = currentXf {
                        if xf.fontID >= 0 && xf.fontID < fonts.count { xf.font = fonts[xf.fontID] }
                        if xf.fillID >= 2 && xf.fillID < fills.count { xf.fillARGB = fills[xf.fillID] }
                        if xf.borderID >= 0 && xf.borderID < borders.count { xf.borders = borders[xf.borderID] }
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

    /// Read one worksheet into `sheet`. Returns what the sheet holds that is
    /// not kept (conditional formatting, print settings, …).
    @discardableResult
    static func parseWorksheet(_ data: Data, into sheet: Sheet,
                               sharedStrings: [String], styleIndexMap: [Int: Int],
                               progress: ((Double) -> Bool)? = nil,
                               fastSheetData: Bool = true) throws -> Set<UnsupportedContent.Kind> {
        // Rows and cells (`<sheetData>`) go to the byte scanner; the rest of
        // the sheet, small by comparison, to XMLParser below. If the scanner
        // meets anything it doesn't expect, the whole sheet goes to XMLParser.
        // The scanner reads UTF-8 only; other encodings are XMLParser's.
        var rest = data
        var found: Set<UnsupportedContent.Kind> = []
        var cellsRead = false
        if fastSheetData, isUTF8(data), let span = sheetDataSpan(in: data) {
            var scanner = SheetDataScanner(sheet: sheet, sharedStrings: sharedStrings,
                                           styleIndexMap: styleIndexMap)
            do {
                let finished = try data.withUnsafeBytes { raw -> Bool in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    return try scanner.scan(UnsafeBufferPointer(rebasing: bytes[span.inner]),
                                            shouldContinue: { progress?($0) ?? true })
                }
                guard finished else { throw XLSXError.cancelled }
                rest = data.subdata(in: 0..<span.outer.lowerBound)
                rest.append(data.subdata(in: span.outer.upperBound..<data.count))
                cellsRead = true
                if scanner.builder.sawRowFormatting { found.insert(.rowFormatting) }
                if scanner.builder.sawOutline { found.insert(.outlines) }
            } catch XLSXError.invalidXML {
                sheet.removeAllCells()
                sheet.rowHeights = [:]
                sheet.hiddenRows = []
            }
        }
        if !cellsRead, let progress, !progress(0) {
            throw XLSXError.cancelled
        }
        found.formUnion(try parseWorksheetWithXMLParser(rest, into: sheet, sharedStrings: sharedStrings,
                                                        styleIndexMap: styleIndexMap,
                                                        progress: cellsRead ? nil : progress))
        return found
    }

    /// False when the part declares an encoding other than UTF-8 (or has a
    /// UTF-16 byte order mark). No declaration means UTF-8.
    static func isUTF8(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            let b = raw.bindMemory(to: UInt8.self)
            if b.count >= 2, (b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF) { return false }
            var start = 0
            if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { start = 3 }
            let head = Array(b[start..<min(b.count, start + 256)])
            guard head.starts(with: Array("<?xml".utf8)) else { return true }
            let end = (0..<max(0, head.count - 1)).first { head[$0] == 0x3F && head[$0 + 1] == 0x3E } ?? head.count
            let declaration = String(decoding: head[0..<end], as: UTF8.self)
            guard let range = declaration.range(of: "encoding") else { return true }
            let afterName = declaration[range.upperBound...].drop { $0 == " " || $0 == "=" || $0 == "\t" }
            guard let quote = afterName.first, quote == "\"" || quote == "'" else { return true }
            let value = afterName.dropFirst().prefix { $0 != quote }.lowercased()
            return value == "utf-8" || value == "utf8"
        }
    }

    /// Where `<sheetData>` is: `outer` covers the element, `inner` its
    /// content. Nil when there is none (or it is empty).
    static func sheetDataSpan(in data: Data) -> (outer: Range<Int>, inner: Range<Int>)? {
        data.withUnsafeBytes { raw -> (outer: Range<Int>, inner: Range<Int>)? in
            let b = raw.bindMemory(to: UInt8.self)
            let name = Array("sheetData".utf8)
            let n = b.count
            func isName(at k: Int) -> Bool {
                guard k >= 0, k + name.count <= n else { return false }
                for m in 0..<name.count where b[k + m] != name[m] { return false }
                return true
            }
            // The start tag: "<sheetData" or "<prefix:sheetData", then a
            // space, ">" or "/".
            var k = 0
            var tagStart = -1
            while k < n {
                if b[k] == 0x3C, k + 1 < n, b[k + 1] != 0x2F, b[k + 1] != 0x3F, b[k + 1] != 0x21 {
                    var j = k + 1
                    while j < n, b[j] != 0x3E, b[j] != 0x20, b[j] != 0x2F, b[j] != 0x3A { j += 1 }
                    let local = (j < n && b[j] == 0x3A) ? j + 1 : k + 1
                    if isName(at: local), local + name.count < n {
                        let after = b[local + name.count]
                        if after == 0x3E || after == 0x2F || after == 0x20 || after == 0x0A || after == 0x0D || after == 0x09 {
                            tagStart = k
                            break
                        }
                    }
                }
                k += 1
            }
            guard tagStart >= 0 else { return nil }
            var gt = tagStart
            while gt < n, b[gt] != 0x3E { gt += 1 }
            guard gt < n, b[gt - 1] != 0x2F else { return nil } // <sheetData/>: nothing to scan
            let innerStart = gt + 1
            // The end tag: the last "</sheetData>" or "</prefix:sheetData>".
            var e = n - name.count - 1
            while e > innerStart {
                if b[e + name.count] == 0x3E, isName(at: e) {
                    var open = e - 1
                    while open > innerStart, b[open] != 0x3C, b[open] != 0x3E { open -= 1 }
                    if b[open] == 0x3C, open + 1 < n, b[open + 1] == 0x2F, open >= innerStart {
                        return (tagStart..<(e + name.count + 1), innerStart..<open)
                    }
                }
                e -= 1
            }
            return nil
        }
    }

    /// The XMLParser reader: everything outside `<sheetData>` always, and
    /// the cells too when the fast scanner is off or gave up. `progress` is
    /// asked as the parse goes; false stops it with `XLSXError.cancelled`.
    @discardableResult
    static func parseWorksheetWithXMLParser(_ data: Data, into sheet: Sheet,
                                            sharedStrings: [String], styleIndexMap: [Int: Int],
                                            progress: ((Double) -> Bool)? = nil) throws -> Set<UnsupportedContent.Kind> {
        final class Delegate: NSObject, XMLParserDelegate {
            let sheet: Sheet
            let styleIndexMap: [Int: Int]
            var cells: SheetCellBuilder

            var valueText = ""
            var formulaText: String?
            var resolvedFormula: String?
            var inV = false, inF = false, inIS = false, inIST = false
            var inlineText = ""
            var currentSharedSI: String?
            var currentFormulaIsShared = false
            var depth = 0
            /// Local names of the open elements (path[1] is a worksheet child).
            var path: [String] = []
            var found: Set<UnsupportedContent.Kind> = []
            // AutoFilter (worksheet level only, not customSheetView copies).
            var autoFilter: AutoFilter?
            var filterColumnID: Int?
            var filterColumn = ColumnFilter()
            var filterColumnPreserve = false
            var filterCriterion: String?
            /// colId of each filterColumn child in document order, and the
            /// child of each column that may need keeping verbatim.
            var criterionOwners: [Int] = []
            var preservedCriteria: [Int: Int] = [:] // colId -> child index

            // Progress: asked every few thousand elements.
            let progress: ((Double) -> Bool)?
            let position: ParsePosition?
            var elementCount = 0
            var lastFraction = 0.0
            var cancelled = false

            init(sheet: Sheet, sharedStrings: [String], styleIndexMap: [Int: Int],
                 progress: ((Double) -> Bool)?, data: Data) {
                self.sheet = sheet
                self.styleIndexMap = styleIndexMap
                self.cells = SheetCellBuilder(sheet: sheet, sharedStrings: sharedStrings, styleIndexMap: styleIndexMap)
                self.progress = progress
                self.position = progress == nil ? nil : ParsePosition(data)
            }

            func checkProgress(_ parser: XMLParser) {
                guard let progress, let position, !cancelled else { return }
                elementCount += 1
                guard elementCount & 4095 == 0 else { return }
                lastFraction = max(lastFraction, position.fraction(line: parser.lineNumber, column: parser.columnNumber))
                if !progress(lastFraction) {
                    cancelled = true
                    parser.abortParsing()
                }
            }

            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                depth += 1
                let local = localName(name)
                path.append(local)
                checkProgress(parser)
                noteUnsupported(local, attributes: attributes)
                switch local {
                case "autoFilter" where depth == 2:
                    if let ref = attributes["ref"], let range = CellRange(a1: ref),
                       range.start.isValid, range.end.isValid {
                        autoFilter = AutoFilter(range: range)
                    }
                case "filterColumn" where depth == 3 && autoFilter != nil:
                    // hiddenButton/showButton are ignored: buttons always show.
                    filterColumnID = Int(attributes["colId"] ?? "") ?? -1
                    filterColumn = ColumnFilter()
                    filterColumnPreserve = false
                    filterCriterion = nil
                case _ where depth == 4 && filterColumnID != nil:
                    let colID = filterColumnID!
                    criterionOwners.append(colID)
                    let element = local
                    guard element != "extLst", filterCriterion == nil else { break }
                    filterCriterion = element
                    switch element {
                    case "filters":
                        filterColumn.values = []
                        filterColumn.includeBlanks = boolAttr(attributes["blank"], default: false)
                    case "customFilters":
                        filterColumn.matchAll = boolAttr(attributes["and"], default: false)
                    default:
                        // top10, dynamicFilter, colorFilter, iconFilter.
                        filterColumnPreserve = true
                    }
                    // Even filters/customFilters may turn out to need it.
                    preservedCriteria[colID] = criterionOwners.count - 1
                case _ where depth == 5 && filterColumnID != nil && !filterColumnPreserve:
                    switch (filterCriterion, local) {
                    case ("filters", "filter"):
                        filterColumn.values?.insert(XML.decodeIllegalCharacters(attributes["val"] ?? ""))
                    case ("customFilters", "customFilter"):
                        if let op = FilterCondition.Operator(rawValue: attributes["operator"] ?? "equal"),
                           filterColumn.conditions.count < 2 {
                            filterColumn.conditions.append(FilterCondition(op, attributes["val"] ?? ""))
                        } else {
                            filterColumnPreserve = true
                        }
                    default:
                        // dateGroupItem and anything else we can't evaluate.
                        filterColumnPreserve = true
                    }
                case "row":
                    cells.startRow(r: Int(attributes["r"] ?? ""), height: Double(attributes["ht"] ?? ""),
                                   hidden: boolAttr(attributes["hidden"], default: false),
                                   customFormat: boolAttr(attributes["customFormat"], default: false),
                                   style: Int(attributes["s"] ?? ""),
                                   outlineLevel: Int(attributes["outlineLevel"] ?? ""))
                case "c":
                    cells.startCell(address: attributes["r"].flatMap { CellAddress(a1: $0) },
                                    type: SheetCellBuilder.CellType(attributes["t"]),
                                    style: Int(attributes["s"] ?? ""))
                    valueText = ""
                    formulaText = nil
                    resolvedFormula = nil
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
                       let width = Double(attributes["width"] ?? ""), width.isFinite, width >= 0 {
                        // width chars -> px -> points (Excel's limit is 255 characters)
                        let px = min(width, 255) * 7 + 5
                        let points = CGFloat(px * 0.75)
                        let first = min(max(1, minCol), CellAddress.maxColumns + 1)
                        let last = min(maxCol, first + 4096, CellAddress.maxColumns)
                        if first <= last {
                            for col in first...last {
                                sheet.columnWidths[col - 1] = points
                            }
                        }
                    }
                case "mergeCell":
                    if let ref = attributes["ref"], let range = CellRange(a1: ref), !range.isSingleCell,
                       range.start.isValid, range.end.isValid {
                        sheet.mergedRanges.append(range)
                    }
                case "pane":
                    if attributes["state"] == "frozen" || attributes["state"] == "frozenSplit" {
                        let x = Int(attributes["xSplit"] ?? "") ?? 0
                        let y = Int(attributes["ySplit"] ?? "") ?? 0
                        sheet.frozenColumns = min(max(0, x), CellAddress.maxColumns - 1)
                        sheet.frozenRows = min(max(0, y), CellAddress.maxRows - 1)
                    }
                case "sheetFormatPr":
                    if let h = Double(attributes["defaultRowHeight"] ?? ""), h.isFinite {
                        let scaled = min(h, SheetCellBuilder.maxRowHeight) * (22.0 / 15.0)
                        sheet.defaultRowHeight = CGFloat(max(12, scaled))
                    }
                default:
                    break
                }
            }

            /// Worksheet content SimpleSpread reads past (it will not be saved).
            func noteUnsupported(_ local: String, attributes: [String: String]) {
                if depth == 2 {
                    switch local {
                    case "conditionalFormatting": found.insert(.conditionalFormatting)
                    case "dataValidations": found.insert(.dataValidation)
                    case "hyperlinks": found.insert(.hyperlinks)
                    case "sheetProtection":
                        // Present but off (LibreOffice writes sheet="false").
                        if boolAttr(attributes["sheet"], default: false) { found.insert(.sheetProtection) }
                    case "scenarios": found.insert(.scenarios)
                    case "customSheetViews": found.insert(.customViews)
                    case "oleObjects": found.insert(.embeddedObjects)
                    case "controls": found.insert(.formControls)
                    case "rowBreaks", "colBreaks", "legacyDrawingHF": found.insert(.printSettings)
                    case "printOptions":
                        // gridLinesSet defaults to true and means nothing alone.
                        if attributes.contains(where: { $0.key != "gridLinesSet" && boolAttr($0.value, default: false) }) {
                            found.insert(.printSettings)
                        }
                    case "pageSetup":
                        if Self.pageSetupIsCustom(attributes) { found.insert(.printSettings) }
                    default: break
                    }
                } else if depth == 3 {
                    switch (path[1], local) {
                    case ("sheetPr", "pageSetUpPr"):
                        if boolAttr(attributes["fitToPage"], default: false) { found.insert(.printSettings) }
                    case ("cols", "col"):
                        if boolAttr(attributes["hidden"], default: false) { found.insert(.hiddenColumns) }
                        if let style = Int(attributes["style"] ?? ""), (styleIndexMap[style] ?? 0) != 0 {
                            found.insert(.columnFormatting)
                        }
                        if let level = Int(attributes["outlineLevel"] ?? ""), level > 0 { found.insert(.outlines) }
                    default: break
                    }
                } else if depth == 4, path[1] == "extLst" {
                    switch local {
                    case "conditionalFormattings": found.insert(.conditionalFormatting)
                    case "dataValidations": found.insert(.dataValidation)
                    case "sparklineGroups": found.insert(.sparklines)
                    case "slicerList": found.insert(.slicers)
                    case "timelineRefs": found.insert(.timelines)
                    default: break
                    }
                }
            }

            /// Anything beyond paper size, portrait orientation and printer
            /// resolution (what Excel writes once a sheet has been printed).
            static func pageSetupIsCustom(_ attributes: [String: String]) -> Bool {
                for (key, value) in attributes {
                    switch localName(key) {
                    case "paperSize", "horizontalDpi", "verticalDpi", "id", "copies", "usePrinterDefaults":
                        continue
                    case "orientation" where value == "portrait" || value == "default": continue
                    case "scale" where value == "100": continue
                    case "fitToWidth", "fitToHeight": continue // only with sheetPr/pageSetUpPr@fitToPage
                    case "firstPageNumber": continue // only with useFirstPageNumber
                    case "pageOrder" where value == "downThenOver": continue
                    case "cellComments" where value == "none": continue
                    case "errors" where value == "displayed": continue
                    case "useFirstPageNumber", "blackAndWhite", "draft":
                        if !boolAttr(value, default: false) { continue }
                        return true
                    default:
                        return true
                    }
                }
                return false
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if inV { valueText += string }
                else if inF { formulaText = (formulaText ?? "") + string }
                else if inIST { inlineText += string }
                else if depth >= 3, path[1] == "headerFooter",
                        string.contains(where: { !$0.isWhitespace }) {
                    found.insert(.printSettings) // a header or footer with text
                }
            }

            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                        qualifiedName: String?) {
                defer { depth -= 1; path.removeLast() }
                if depth == 3, localName(name) == "filterColumn", let colID = filterColumnID {
                    if filterColumnPreserve {
                        filterColumn = ColumnFilter(preservedXML: "") // filled in after the parse
                    } else {
                        preservedCriteria[colID] = nil
                    }
                    if colID >= 0, filterColumn.isActive { autoFilter?.columns[colID] = filterColumn }
                    filterColumnID = nil
                    return
                }
                switch localName(name) {
                case "v": inV = false
                case "f":
                    inF = false
                    resolvedFormula = cells.formula(text: formulaText, shared: currentFormulaIsShared,
                                                    si: currentSharedSI)
                case "t": inIST = false
                case "is": inIS = false
                case "c":
                    cells.commitCell(value: valueText, inlineText: inlineText, formula: resolvedFormula)
                    resolvedFormula = nil
                default:
                    break
                }
            }
        }

        let delegate = Delegate(sheet: sheet, sharedStrings: sharedStrings, styleIndexMap: styleIndexMap,
                                progress: progress, data: data)
        do {
            try runParser(data, delegate: delegate)
        } catch {
            if delegate.cancelled { throw XLSXError.cancelled }
            throw error
        }
        var found = delegate.found
        if delegate.cells.sawRowFormatting { found.insert(.rowFormatting) }
        if delegate.cells.sawOutline { found.insert(.outlines) }

        guard var filter = delegate.autoFilter else { return found }
        // Criteria we can't evaluate are kept as XML and written back verbatim.
        let owners = delegate.criterionOwners
        let preserved = delegate.preservedCriteria.filter { filter.columns[$0.key]?.preservedXML != nil }
        if !preserved.isEmpty {
            let fragments = try XMLRewriter.fragments(of: data) {
                $0.path.count == 4 && $0.path[1] == "autoFilter" && $0.path[2] == "filterColumn"
            }
            for (colID, index) in preserved {
                guard index < fragments.count, index < owners.count, owners[index] == colID else {
                    filter.columns[colID] = nil
                    continue
                }
                filter.columns[colID]?.preservedXML = prunedNamespaces(fragments[index])
            }
        }
        sheet.autoFilter = filter
        return found
    }

    /// Turns XMLParser's line and column into a fraction of the part read.
    final class ParsePosition {
        private let count: Int
        /// Byte offset of each line's start, when there are few lines (Excel
        /// writes a sheet on one or two); otherwise the line count is used.
        private let lineStarts: [Int]?
        private let lines: Int

        init(_ data: Data) {
            count = max(1, data.count)
            var starts = [0]
            var lineCount = 1
            data.withUnsafeBytes { raw in
                let b = raw.bindMemory(to: UInt8.self)
                for k in 0..<b.count where b[k] == 0x0A {
                    lineCount += 1
                    if starts.count <= 4096 { starts.append(k + 1) }
                }
            }
            lines = lineCount
            lineStarts = starts.count <= 4096 ? starts : nil
        }

        func fraction(line: Int, column: Int) -> Double {
            let f: Double
            if let lineStarts {
                let start = lineStarts[min(max(0, line - 1), lineStarts.count - 1)]
                f = Double(start + max(0, column)) / Double(count)
            } else {
                f = Double(max(0, line - 1)) / Double(lines)
            }
            return min(1, max(0, f))
        }
    }

    /// A fragment carries every namespace declaration in scope where it was
    /// cut out; keep only those it uses. The main namespace is dropped: it
    /// is the default namespace wherever the fragment is written back.
    static func prunedNamespaces(_ fragment: String) -> String {
        // XMLRewriter escapes ">" in attribute values, so the first one ends the start tag.
        guard let tagEnd = fragment.firstIndex(of: ">"),
              let regex = try? NSRegularExpression(pattern: #" xmlns(?::([A-Za-z_][\w.-]*))?="([^"]*)""#)
        else { return fragment }
        let startTag = String(fragment[..<tagEnd])
        let rest = String(fragment[tagEnd...])
        let ns = startTag as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let bare = regex.stringByReplacingMatches(in: startTag, range: whole, withTemplate: "")
        let body = bare + rest
        var kept = ""
        for match in regex.matches(in: startTag, range: whole) {
            let decl = ns.substring(with: match.range)
            if match.range(at: 1).location == NSNotFound {
                if ns.substring(with: match.range(at: 2)) != XLSXWriter.mainNS { kept += decl }
            } else {
                let prefix = ns.substring(with: match.range(at: 1))
                if body.contains("<\(prefix):") || body.contains(" \(prefix):") { kept += decl }
            }
        }
        guard let nameEnd = bare.firstIndex(of: " ") else { return bare + kept + rest }
        return String(bare[..<nameEnd]) + kept + String(bare[nameEnd...]) + rest
    }

    /// Translate a shared-formula master by a row/column offset.
    static func translateFormula(_ text: String, byRows rows: Int, columns: Int) -> String {
        WorkbookOperations.translatedFormula(text, byRows: rows, columns: columns)
    }

    /// An ISO 8601 date or date-time (`t="d"` cells) as a serial; nil for
    /// anything else, including empty text and dates outside years 0–9999.
    static func isoDateToSerial(_ s: String) -> Double? {
        let parts = s.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false)
        guard let datePart = parts.first else { return nil }
        let dateParts = datePart.split(separator: "-", omittingEmptySubsequences: false)
        guard dateParts.count == 3, dateParts.allSatisfy({ !$0.isEmpty && $0.count <= 4 }),
              let y = Int(dateParts[0]), let m = Int(dateParts[1]), let d = Int(dateParts[2]),
              (0...9999).contains(y), (1...12).contains(m), (1...31).contains(d) else {
            return nil
        }
        var serial = ExcelDate.serial(year: y, month: m, day: d)
        if parts.count > 1 {
            let timeParts = parts[1].split(separator: ":")
            if timeParts.count >= 2 {
                let h = Int(timeParts[0].prefix(6)) ?? 0
                let min = Int(timeParts[1].prefix(6)) ?? 0
                let sec = timeParts.count > 2 ? (Double(timeParts[2].prefix(while: { $0.isNumber || $0 == "." }).prefix(20)) ?? 0) : 0
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
