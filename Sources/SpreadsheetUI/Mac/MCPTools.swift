#if os(macOS)
import Foundation
import SpreadsheetCore
import SpreadsheetFiles

/// The tools an AI agent calls over MCP to read and edit the spreadsheets
/// open in SimpleSpread. Every edit goes through SpreadsheetDocument, as the
/// user's own do: the window shows it as it lands, it is one undo step
/// ("Undo Agent Edit"), and pivot tables are protected the same way. An
/// edit switches the window to the sheet it changes, so the user sees it
/// happen; it leaves the selection alone (select_range moves it).
@MainActor
public final class MCPTools {
    /// A document open in a window, with the id agents name it by.
    public struct OpenDocument {
        public let id: Int
        public let document: SpreadsheetDocument

        public init(id: Int, document: SpreadsheetDocument) {
            self.id = id
            self.document = document
        }
    }

    /// LocalizedError: thrown through the document (a pivot's `configure`),
    /// it comes back as the notice's detail.
    struct ToolError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// What a tool returns: JSON (most tools), or MCP content items as
    /// they are (CSV text, an image).
    enum Output {
        case json(JSONValue)
        case content([JSONValue])
    }

    struct Tool {
        let name: String
        let description: String
        let properties: [String: JSONValue]
        let required: [String]
        /// MainActor: an async function type without it would run the tool
        /// off the main thread, against documents the UI is drawing.
        let run: @MainActor (MCPTools, Arguments) async throws -> Output
    }

    /// What the tools need from the windows (the Mac app's AgentAccess
    /// fills these in; tests leave the defaults).
    struct WindowActions {
        /// The window showing a document: a save's progress shows on it.
        var window: @MainActor (SpreadsheetDocument) -> HostWindow? = { _ in nil }
        /// After a save (Open Recent).
        var didSave: @MainActor (URL) -> Void = { _ in }
        /// Close the window showing a document; false when there is none.
        var close: @MainActor (SpreadsheetDocument) -> Bool = { _ in false }
        /// A PNG of the window showing a document; nil when there is none.
        var snapshot: @MainActor (SpreadsheetDocument) -> Data? = { _ in nil }
    }

    /// The most cells one call reads or writes.
    static let cellLimit = 10_000
    /// CSV is far smaller than JSON per cell, so it reads more.
    static let csvCellLimit = 100_000

    /// The open documents, front-most first.
    let openDocuments: @MainActor () -> [OpenDocument]
    var windows = WindowActions()

    public init(openDocuments: @escaping @MainActor () -> [OpenDocument]) {
        self.openDocuments = openDocuments
    }

    static let instructions = """
        SimpleSpread is a spreadsheet app; these tools read and edit the workbooks open in its windows, \
        live: the user sees each edit as it happens and can undo it (each tool call is one undo step). \
        Start with list_documents. Tools act on the front-most document and its active sheet unless \
        you pass `document` (an id from list_documents) or `sheet` (a sheet name). Ranges are A1 \
        style: "B2", "A1:D20", whole columns "A:C", whole rows "3:5", "Sheet2!A1:B4", or "selection" \
        for the user's selected cells. Text written to a cell is read as if typed: "=SUM(B2:B9)" is a \
        formula, "12%", "$4.50" and "1/15/2026" become numbers with that format, and a leading \
        apostrophe keeps text as text ("'00123"). Charts and pivot tables have tools of their own; a pivot \
        table's cells can't be written, and it doesn't follow its source data until refresh_pivot_tables. \
        An edit that would overwrite cells is refused unless you pass `replace: true`, so ask the user \
        first when their data is in the way. Edits stay unsaved until save_document (or the user) \
        saves them. These tools can't open files; with a shell, `open -a SimpleSpread <file>` opens one \
        (it then appears in list_documents once loaded).
        """

    // MARK: - Tool list

    static let documentProperty: (String, JSONValue) = ("document", [
        "type": ["integer", "string"],
        "description": "The document's id from list_documents, or its name. Default: the front-most document.",
    ])
    static let sheetProperty: (String, JSONValue) = ("sheet", [
        "type": "string",
        "description": "Sheet name. Default: the sheet showing in the window (a sheet named in `range` wins).",
    ])

    static func properties(_ extra: [(String, JSONValue)], sheet: Bool = true) -> [String: JSONValue] {
        var all = [documentProperty]
        if sheet { all.append(sheetProperty) }
        return Dictionary(all + extra, uniquingKeysWith: { _, last in last })
    }

    static let all: [Tool] = cellTools + chartTools + pivotTools

    static let cellTools: [Tool] = [
        Tool(name: "list_documents",
             description: "List the spreadsheets open in SimpleSpread, front-most first: id, name, file path, "
                + "unsaved changes, sheets with the range each uses and their charts and pivot tables, the sheet "
                + "showing and the user's selection.",
             properties: [:], required: [], run: { tools, _ in .json(try tools.listDocuments()) }),
        Tool(name: "read_range",
             description: "Read cells. JSON (the default) gives values, any formulas and optionally the text the grid "
                + "shows; dates and times come as \"2026-01-15\", \"2026-01-15 13:30:00\" or \"13:30:00\", which "
                + "write_cells reads back as dates. CSV gives just the values, compactly, for reading a whole table. "
                + "Without `range`, reads the sheet's used range. At most \(cellLimit) cells per call as JSON, "
                + "\(csvCellLimit) as CSV.",
             properties: properties([
                ("range", ["type": "string", "description": "Cells to read, e.g. \"A1:D20\", \"B:B\" or \"selection\"."]),
                ("format", ["type": "string", "enum": ["json", "csv"], "description": "json (default) or csv."]),
                ("include_formatted", ["type": "boolean", "description": .string(
                    "JSON: also return each cell's text as formatted in the grid (\"$4.50\", \"1/15/2026\"). "
                    + "CSV: write that text instead of the values.")]),
             ]),
             required: [], run: { tools, args in try tools.readRange(args) }),
        Tool(name: "write_cells",
             description: "Write a block of cells starting at `start`, row by row. Strings are read as typed "
                + "(formulas start with \"=\"; a leading apostrophe forces text; \"\" clears the cell); numbers "
                + "and booleans are written as they are; null leaves a cell as it was. Formatting is kept. "
                + "Returns the cells' values after recalculation.",
             properties: properties([
                ("start", ["type": "string", "description": "Top-left cell, e.g. \"B2\" or \"Sheet2!B2\"."]),
                ("values", ["type": "array", "description": "Rows of cell values.",
                            "items": ["type": "array", "items": ["type": ["string", "number", "boolean", "null"]]]]),
             ]),
             required: ["start", "values"], run: { tools, args in .json(try tools.writeCells(args)) }),
        Tool(name: "clear_range",
             description: "Clear the values and formulas in a range, keeping its formatting.",
             properties: properties([("range", ["type": "string", "description": "Cells to clear."])]),
             required: ["range"], run: { tools, args in .json(try tools.clearRange(args)) }),
        Tool(name: "format_range",
             description: "Format a range. Pass only what should change.",
             properties: properties([
                ("range", ["type": "string", "description": "Cells to format."]),
                ("bold", ["type": "boolean"]),
                ("italic", ["type": "boolean"]),
                ("underline", ["type": "boolean"]),
                ("strikethrough", ["type": "boolean"]),
                ("number_format", ["type": "string", "description": .string(
                    "A preset (general, number, integer, thousands, percent, percent_integer, currency, date, time, "
                    + "datetime, scientific, text) or an Excel format code such as \"#,##0.0\" or \"yyyy-mm-dd\".")]),
                ("font_name", ["type": "string"]),
                ("font_size", ["type": "number"]),
                ("text_color", ["type": "string", "description": "\"#RRGGBB\", or \"none\" for the default."]),
                ("fill_color", ["type": "string", "description": "\"#RRGGBB\", or \"none\" for no fill."]),
                ("horizontal_alignment", ["type": "string", "enum": ["general", "left", "center", "right"]]),
                ("vertical_alignment", ["type": "string", "enum": ["top", "middle", "bottom"]]),
                ("wrap_text", ["type": "boolean"]),
             ]),
             required: ["range"], run: { tools, args in .json(try tools.formatRange(args)) }),
        Tool(name: "insert_rows",
             description: "Insert blank rows above a row. Formulas, charts and pivot tables below move down.",
             properties: properties([
                ("row", ["type": "integer", "description": "The 1-based row the new rows go above."]),
                ("count", ["type": "integer", "description": "How many rows (default 1)."]),
             ]),
             required: ["row"], run: { tools, args in .json(try tools.structural(args, rows: true, insert: true)) }),
        Tool(name: "delete_rows",
             description: "Delete rows, starting at a row. Formulas that referred to them become #REF!.",
             properties: properties([
                ("row", ["type": "integer", "description": "The first 1-based row to delete."]),
                ("count", ["type": "integer", "description": "How many rows (default 1)."]),
             ]),
             required: ["row"], run: { tools, args in .json(try tools.structural(args, rows: true, insert: false)) }),
        Tool(name: "insert_columns",
             description: "Insert blank columns to the left of a column.",
             properties: properties([
                ("column", ["type": "string", "description": "The column letter the new columns go before, e.g. \"C\"."]),
                ("count", ["type": "integer", "description": "How many columns (default 1)."]),
             ]),
             required: ["column"], run: { tools, args in .json(try tools.structural(args, rows: false, insert: true)) }),
        Tool(name: "delete_columns",
             description: "Delete columns, starting at a column. Formulas that referred to them become #REF!.",
             properties: properties([
                ("column", ["type": "string", "description": "The first column letter to delete, e.g. \"C\"."]),
                ("count", ["type": "integer", "description": "How many columns (default 1)."]),
             ]),
             required: ["column"], run: { tools, args in .json(try tools.structural(args, rows: false, insert: false)) }),
        Tool(name: "set_column_width",
             description: "Set the width of one or more columns, in points (the default is 100).",
             properties: properties([
                ("columns", ["type": "string", "description": "A column (\"B\") or columns (\"B:D\")."]),
                ("width", ["type": "number", "description": "Width in points, 12 to 2000."]),
             ]),
             required: ["columns", "width"], run: { tools, args in .json(try tools.setColumnWidth(args)) }),
        Tool(name: "add_sheet",
             description: "Add a sheet at the end of the workbook and show it.",
             properties: properties([("name", ["type": "string", "description": "Its name (default Sheet<n>)."])],
                                    sheet: false),
             required: [], run: { tools, args in .json(try tools.addSheet(args)) }),
        Tool(name: "rename_sheet",
             description: "Rename a sheet. Formulas that refer to it are updated. Returns the name given, "
                + "which differs when the name was taken or had characters sheet names can't hold.",
             properties: properties([("name", ["type": "string", "description": "The new name."])]),
             required: ["sheet", "name"], run: { tools, args in .json(try tools.renameSheet(args)) }),
        Tool(name: "delete_sheet",
             description: "Delete a sheet. Formulas that referred to it become #REF!. A workbook keeps at least one sheet.",
             properties: properties([]),
             required: ["sheet"], run: { tools, args in .json(try tools.deleteSheet(args)) }),
        Tool(name: "save_document",
             description: "Save a document to its .xlsx file. Only a document that already has one, and that "
                + "saving won't lose anything from, can be saved this way; otherwise the error says what to ask "
                + "the user to do (Save As, or decide about content SimpleSpread can't write back).",
             properties: properties([], sheet: false),
             required: [], run: { tools, args in .json(try await tools.saveDocument(args)) }),
        Tool(name: "close_document",
             description: "Close a document's window. Refused while it has unsaved changes (save it first, or "
                + "leave it to the user): this never discards work. Closing the last window quits SimpleSpread, "
                + "which ends this connection.",
             properties: properties([], sheet: false),
             required: ["document"], run: { tools, args in .json(try tools.closeDocument(args)) }),
        Tool(name: "screenshot",
             description: "A picture of the document's window as the user sees it: cells with their formatting, "
                + "charts, the row and column headers, the selection. Use it to check how something looks. With "
                + "`range`, first selects those cells and scrolls to them (this moves the user's view, as "
                + "select_range does).",
             properties: properties([("range", ["type": "string", "description": "Cells to show first (optional)."])]),
             required: [], run: { tools, args in try await tools.screenshot(args) }),
        Tool(name: "select_range",
             description: "Select cells in the window and scroll them into view, to show the user something.",
             properties: properties([("range", ["type": "string", "description": "Cells to select."])]),
             required: ["range"], run: { tools, args in .json(try tools.selectRange(args)) }),
    ]

    var definitions: [JSONValue] {
        Self.all.map { tool in
            var schema: [String: JSONValue] = ["type": "object", "properties": .object(tool.properties)]
            if !tool.required.isEmpty { schema["required"] = .array(tool.required.map { .string($0) }) }
            return ["name": .string(tool.name), "description": .string(tool.description), "inputSchema": .object(schema)]
        }
    }

    /// The tools that work in reader mode: they read, select or close.
    static let readerTools: Set<String> = [
        "list_documents", "read_range", "screenshot", "select_range", "close_document",
        "list_charts", "list_pivot_tables",
    ]

    func has(_ name: String) -> Bool {
        Self.all.contains { $0.name == name }
    }

    /// A `tools/call` result: the tool's output as JSON text, or the reason
    /// it failed (`isError`, so the agent can correct itself).
    func call(_ name: String, arguments: JSONValue) async -> JSONValue {
        guard let tool = Self.all.first(where: { $0.name == name }) else {
            return Self.toolResult("Unknown tool: \(name)", isError: true)
        }
        // Reader mode (the App Store trial is over): only the tools that
        // look, not the ones that change or save documents.
        if !AppLicense.shared.allowsEditing, !Self.readerTools.contains(name) {
            return Self.toolResult("SimpleSpread is in reader mode: its free trial has ended, so documents can be "
                + "read but not changed or saved. Ask the user to unlock SimpleSpread (SimpleSpread menu ▸ "
                + "Unlock SimpleSpread…). These tools still work: "
                + Self.readerTools.sorted().joined(separator: ", ") + ".", isError: true)
        }
        do {
            guard case .object = arguments else { throw ToolError("Arguments must be an object.") }
            switch try await tool.run(self, Arguments(arguments)) {
            case .json(let value):
                return Self.toolResult(value.encodedString, isError: false)
            case .content(let items):
                return ["content": .array(items), "isError": false]
            }
        } catch let error as ToolError {
            return Self.toolResult(error.message, isError: true)
        } catch {
            return Self.toolResult(error.localizedDescription, isError: true)
        }
    }

    static func toolResult(_ text: String, isError: Bool) -> JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }

    // MARK: - Arguments

    struct Arguments {
        let value: JSONValue
        init(_ value: JSONValue) { self.value = value }

        private func present(_ key: String) -> JSONValue? {
            guard let v = value[key], !v.isNull else { return nil }
            return v
        }

        func string(_ key: String) throws -> String? {
            guard let v = present(key) else { return nil }
            guard let s = v.stringValue else { throw ToolError("`\(key)` must be a string.") }
            return s
        }

        func requiredString(_ key: String) throws -> String {
            guard let s = try string(key), !s.isEmpty else { throw ToolError("`\(key)` is required.") }
            return s
        }

        func int(_ key: String) throws -> Int? {
            guard let v = present(key) else { return nil }
            guard let n = v.numberValue, n == n.rounded(), abs(n) < 1e9 else {
                throw ToolError("`\(key)` must be a whole number.")
            }
            return Int(n)
        }

        func number(_ key: String) throws -> Double? {
            guard let v = present(key) else { return nil }
            guard let n = v.numberValue else { throw ToolError("`\(key)` must be a number.") }
            return n
        }

        func bool(_ key: String) throws -> Bool? {
            guard let v = present(key) else { return nil }
            guard let b = v.boolValue else { throw ToolError("`\(key)` must be true or false.") }
            return b
        }

        func raw(_ key: String) -> JSONValue? { present(key) }
    }

    // MARK: - Finding documents, sheets and ranges

    func document(_ args: Arguments) throws -> OpenDocument {
        let open = openDocuments()
        guard let front = open.first else { throw ToolError("No spreadsheets are open in SimpleSpread.") }
        guard let wanted = args.raw("document") else { return front }
        if let n = wanted.numberValue, let match = open.first(where: { Double($0.id) == n }) {
            return match
        }
        if let s = wanted.stringValue {
            if let id = Int(s), let match = open.first(where: { $0.id == id }) { return match }
            if let match = open.first(where: {
                $0.document.displayName.caseInsensitiveCompare(s) == .orderedSame
                    || $0.document.saveFileName.caseInsensitiveCompare(s) == .orderedSame
                    || $0.document.fileURL?.path == s
            }) { return match }
        }
        let names = open.map { "\($0.id) (\($0.document.displayName))" }.joined(separator: ", ")
        throw ToolError("No open document matches \(wanted.encodedString). Open documents: \(names).")
    }

    func sheet(named name: String?, in doc: SpreadsheetDocument) throws -> Sheet {
        guard let name else { return doc.activeSheet }
        if let sheet = doc.workbook.sheets.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return sheet
        }
        let names = doc.workbook.sheets.map { "\"\($0.name)\"" }.joined(separator: ", ")
        throw ToolError("No sheet named \"\(name)\". Sheets: \(names).")
    }

    /// The sheet and cells `text` names ("Sheet2!A1:B3", "A:C", "3:5",
    /// "selection"). A sheet prefix wins over `sheetName`.
    func range(_ text: String, sheetName: String?, in doc: SpreadsheetDocument) throws -> (Sheet, CellRange) {
        var reference = text.trimmingCharacters(in: .whitespaces)
        var sheetName = sheetName
        if let bang = reference.lastIndex(of: "!") {
            var prefix = String(reference[..<bang])
            if prefix.count >= 2, prefix.hasPrefix("'"), prefix.hasSuffix("'") {
                prefix = String(prefix.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            sheetName = prefix
            reference = String(reference[reference.index(after: bang)...])
        }
        let sheet = try self.sheet(named: sheetName, in: doc)
        if reference.caseInsensitiveCompare("selection") == .orderedSame {
            guard sheet.id == doc.activeSheetID else {
                throw ToolError("The selection is on \"\(doc.activeSheet.name)\", not \"\(sheet.name)\".")
            }
            return (sheet, doc.selection.range)
        }
        guard let range = Self.parseRange(reference.replacingOccurrences(of: "$", with: "")) else {
            throw ToolError("\"\(text)\" isn't a range. Use A1 style: \"B2\", \"A1:D20\", \"A:C\" or \"3:5\".")
        }
        return (sheet, range)
    }

    static func parseRange(_ text: String) -> CellRange? {
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else {
            guard let address = CellAddress(a1: text), address.isValid else { return nil }
            return CellRange(address)
        }
        let lastRow = CellAddress.maxRows - 1, lastColumn = CellAddress.maxColumns - 1
        if let first = CellAddress.columnIndex(parts[0]), let last = CellAddress.columnIndex(parts[1]),
           first <= lastColumn, last <= lastColumn {
            return CellRange(start: CellAddress(row: 0, column: first), end: CellAddress(row: lastRow, column: last))
        }
        if let first = Int(parts[0]), let last = Int(parts[1]),
           (1...CellAddress.maxRows).contains(first), (1...CellAddress.maxRows).contains(last) {
            return CellRange(start: CellAddress(row: first - 1, column: 0),
                             end: CellAddress(row: last - 1, column: lastColumn))
        }
        guard let start = CellAddress(a1: parts[0]), let end = CellAddress(a1: parts[1]),
              start.isValid, end.isValid else { return nil }
        return CellRange(start: start, end: end)
    }

    /// Show `sheet` in the window, as the user would to edit it.
    func activate(_ sheet: Sheet, in doc: SpreadsheetDocument) {
        if doc.activeSheetID != sheet.id { doc.selectSheet(withID: sheet.id) }
    }

    /// Run an edit. With `actionName` it is one undo step of that name;
    /// pass one only once the edit is sure to change something (UndoManager
    /// keeps an empty group, which would be an Undo that does nothing).
    /// Without, the document's own command names its step. An edit the
    /// document refuses anyway raises a notice for the window to show; here
    /// it becomes the tool's error instead, and the user sees no alert.
    /// A question the edit would ask the user (replace these cells?) is
    /// answered with `replace` instead; refused, the error says to pass it.
    func edit(_ doc: SpreadsheetDocument, _ actionName: String? = nil, replace: Bool = false,
              _ body: () -> Void) throws {
        let notice = doc.notice
        let confirm = doc.confirm, confirmLater = doc.confirmLater
        var question: String?
        doc.confirm = { message, detail, _ in
            question = [message, detail].filter { !$0.isEmpty }.joined(separator: " ")
            return replace
        }
        doc.confirmLater = nil
        defer {
            doc.confirm = confirm
            doc.confirmLater = confirmLater
        }
        if let actionName {
            doc.undoManager.beginUndoGrouping()
            body()
            doc.undoManager.setActionName(actionName)
            doc.undoManager.endUndoGrouping()
        } else {
            body()
        }
        if let raised = doc.notice, raised != notice {
            doc.notice = notice
            throw ToolError([raised.message, raised.detail].filter { !$0.isEmpty }.joined(separator: " "))
        }
        if let question, !replace {
            throw ToolError("Nothing changed: \(question) Pass `replace: true` to go ahead.")
        }
    }

    func refuseIfPivot(_ range: CellRange, on sheet: Sheet, in doc: SpreadsheetDocument) throws {
        if let table = doc.workbook.pivotTables(intersecting: range, onSheet: sheet.id).first {
            throw ToolError("\(range.a1) is part of the pivot table “\(table.name)”, whose cells can't be edited.")
        }
    }

    /// Dates and times as text that reads back as the same date when typed.
    static let dateOptions = CSV.ExportOptions(dateTimeSeparator: " ")

    static func json(_ value: CellValue, style: CellStyle) -> JSONValue {
        switch value {
        case .empty: return .null
        case .number(let n):
            if style.numberFormat.isDateTime {
                return .string(CSV.exportField(value: value, style: style, options: dateOptions))
            }
            return .number(n)
        case .string(let s): return .string(s)
        case .bool(let b): return .bool(b)
        case .error(let e): return .string(e.rawValue)
        }
    }

    static func values(of range: CellRange, in sheet: Sheet, workbook: Workbook) -> JSONValue {
        .array((range.start.row...range.end.row).map { row in
            .array((range.start.column...range.end.column).map { column in
                let address = CellAddress(row: row, column: column)
                return json(sheet.value(at: address), style: workbook.style(at: sheet.styleIndex(at: address)))
            })
        })
    }

    static func checkSize(_ range: CellRange, limit: Int = cellLimit) throws {
        guard range.cellCount <= limit else {
            throw ToolError("\(range.a1) has \(range.cellCount) cells; read or write at most \(limit) per call.")
        }
    }

    // MARK: - Tools

    func listDocuments() throws -> JSONValue {
        .array(openDocuments().map { open in
            let doc = open.document
            var entry: [String: JSONValue] = [
                "id": .number(Double(open.id)),
                "name": .string(doc.displayName),
                "unsaved_changes": .bool(doc.isModified),
                "active_sheet": .string(doc.activeSheet.name),
                "selection": .string(doc.selection.range.a1),
                "sheets": .array(doc.workbook.sheets.map { sheet in
                    var info: [String: JSONValue] = ["name": .string(sheet.name),
                                                     "used_range": sheet.usedRange.map { .string($0.a1) } ?? .null]
                    if sheet.isHidden { info["hidden"] = true }
                    let charts = self.charts(on: sheet, in: doc)
                    if !charts.isEmpty { info["charts"] = .array(charts.map { .string($0.name) }) }
                    let pivots = doc.workbook.pivotTables.filter { $0.sheetID == sheet.id }
                    if !pivots.isEmpty { info["pivot_tables"] = .array(pivots.map { .string($0.name) }) }
                    return .object(info)
                }),
            ]
            if doc.isReadOnly { entry["reader_mode"] = true }
            if let url = doc.fileURL { entry["path"] = .string(url.path) }
            return .object(entry)
        })
    }

    func readRange(_ args: Arguments) throws -> Output {
        let open = try document(args)
        let doc = open.document
        let format = try args.string("format")?.lowercased() ?? "json"
        guard format == "json" || format == "csv" else { throw ToolError("`format` must be json or csv.") }
        let limit = format == "csv" ? Self.csvCellLimit : Self.cellLimit
        let formatted = try args.bool("include_formatted") == true
        let sheet: Sheet
        var range: CellRange?
        if let text = try args.string("range") {
            let (found, requested) = try self.range(text, sheetName: try args.string("sheet"), in: doc)
            sheet = found
            // Whole columns or rows: the part that holds anything.
            if requested.cellCount > limit, let used = sheet.usedRange {
                range = SpreadsheetDocument.intersection(requested, used)
            } else if requested.cellCount > limit {
                range = nil
            } else {
                range = requested
            }
        } else {
            sheet = try self.sheet(named: try args.string("sheet"), in: doc)
            range = sheet.usedRange
        }
        var result: [String: JSONValue] = ["document": .number(Double(open.id)), "sheet": .string(sheet.name)]
        if let range { try Self.checkSize(range, limit: limit) }
        if format == "csv" {
            // The CSV as a text item of its own, not escaped inside JSON.
            result["range"] = range.map { .string($0.a1) } ?? .null
            result["format"] = "csv"
            let options = CSV.ExportOptions(lineEnding: "\n", includeBOM: false, machineReadable: !formatted,
                                            dateTimeSeparator: " ")
            let csv = range.map { CSV.text(of: $0, in: sheet, workbook: doc.workbook, options: options) } ?? ""
            return .content([["type": "text", "text": .string(JSONValue.object(result).encodedString)],
                             ["type": "text", "text": .string(csv)]])
        }
        guard let range else {
            result["range"] = .null
            result["values"] = []
            return .json(.object(result))
        }
        result["range"] = .string(range.a1)
        result["values"] = Self.values(of: range, in: sheet, workbook: doc.workbook)
        let rows = range.start.row...range.end.row, columns = range.start.column...range.end.column
        let formulas: [JSONValue] = rows.map { row in
            .array(columns.map { column in
                sheet.cell(at: CellAddress(row: row, column: column)).formula.map { .string("=" + $0) } ?? .null
            })
        }
        if formulas.contains(where: { $0.arrayValue?.contains { !$0.isNull } ?? false }) {
            result["formulas"] = .array(formulas)
        }
        if formatted {
            result["formatted"] = .array(rows.map { row in
                .array(columns.map { column in
                    let address = CellAddress(row: row, column: column)
                    let style = doc.workbook.style(at: sheet.styleIndex(at: address))
                    return .string(NumberFormatEngine.displayString(for: sheet.value(at: address),
                                                                    format: style.numberFormat))
                })
            })
        }
        return .json(.object(result))
    }

    func writeCells(_ args: Arguments) throws -> JSONValue {
        let doc = try document(args).document
        let (sheet, origin) = try range(try args.requiredString("start"), sheetName: try args.string("sheet"), in: doc)
        guard let rows = args.raw("values")?.arrayValue, !rows.isEmpty else {
            throw ToolError("`values` must be a non-empty array of rows.")
        }
        var inputs: [(CellAddress, String)] = []
        var width = 1
        for (r, row) in rows.enumerated() {
            guard let cells = row.arrayValue else {
                throw ToolError("Row \(r + 1) of `values` must be an array.")
            }
            width = max(width, cells.count)
            for (c, value) in cells.enumerated() {
                let address = origin.start.offset(rows: r, columns: c)
                guard address.isValid else { throw ToolError("The values run past the edge of the sheet.") }
                switch value {
                case .null: continue
                case .string(let s): inputs.append((address, s))
                case .number(let n): inputs.append((address, NumberFormatEngine.roundTripString(for: n)))
                case .bool(let b): inputs.append((address, b ? "TRUE" : "FALSE"))
                default: throw ToolError("Cell values must be strings, numbers, booleans or null.")
                }
            }
        }
        let target = CellRange(start: origin.start, end: origin.start.offset(rows: rows.count - 1, columns: width - 1))
        try Self.checkSize(target)
        try refuseIfPivot(target, on: sheet, in: doc)
        activate(sheet, in: doc)
        var written = 0
        try edit(doc) {
            written = doc.commitInputs(inputs, sheetID: sheet.id, actionName: "Agent Edit")
        }
        return ["sheet": .string(sheet.name), "range": .string(target.a1), "cells_changed": .number(Double(written)),
                "values": Self.values(of: target, in: sheet, workbook: doc.workbook)]
    }

    func clearRange(_ args: Arguments) throws -> JSONValue {
        let doc = try document(args).document
        let (sheet, range) = try range(try args.requiredString("range"), sheetName: try args.string("sheet"), in: doc)
        try refuseIfPivot(range, on: sheet, in: doc)
        let addresses = doc.storedAddresses(in: range, sheet: sheet).filter {
            let cell = sheet.cell(at: $0)
            return !cell.value.isEmpty || cell.formula != nil
        }
        activate(sheet, in: doc)
        try edit(doc) {
            doc.commitInputs(addresses.map { ($0, "") }, sheetID: sheet.id, actionName: "Agent Clear")
        }
        return ["sheet": .string(sheet.name), "range": .string(range.a1), "cells_cleared": .number(Double(addresses.count))]
    }

    static let numberFormatPresets: [String: NumberFormat] = [
        "general": .general, "number": .thousandsDecimal2, "integer": .integer, "thousands": .thousands,
        "percent": .percent, "percent_integer": .percentInteger, "currency": .currency, "date": .date,
        "time": .time, "datetime": .dateTime, "scientific": .scientific, "text": .text,
    ]

    /// "#RRGGBB" → a colour; "none" → nil (the default).
    static func color(_ text: String, key: String) throws -> RGBAColor? {
        if text.caseInsensitiveCompare("none") == .orderedSame { return nil }
        let hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else {
            throw ToolError("`\(key)` must be \"#RRGGBB\" or \"none\".")
        }
        return RGBAColor(red: UInt8(rgb >> 16 & 0xFF), green: UInt8(rgb >> 8 & 0xFF), blue: UInt8(rgb & 0xFF))
    }

    func formatRange(_ args: Arguments) throws -> JSONValue {
        let doc = try document(args).document
        let (sheet, range) = try range(try args.requiredString("range"), sheetName: try args.string("sheet"), in: doc)
        // Read every argument before changing anything.
        var changes: [(inout CellStyle) -> Void] = []
        for (key, path) in [("bold", \CellStyle.bold), ("italic", \.italic), ("underline", \.underline),
                            ("strikethrough", \.strikethrough), ("wrap_text", \.wrapText)] {
            if let on = try args.bool(key) { changes.append { $0[keyPath: path] = on } }
        }
        if let code = try args.string("number_format") {
            let format = Self.numberFormatPresets[code.lowercased()] ?? NumberFormat(code: code)
            changes.append { $0.numberFormat = format }
        }
        if let name = try args.string("font_name") {
            changes.append { $0.fontName = name.isEmpty ? nil : name }
        }
        if let size = try args.number("font_size") {
            guard (1...409).contains(size) else { throw ToolError("`font_size` must be 1 to 409.") }
            changes.append { $0.fontSize = size }
        }
        if let text = try args.string("text_color") {
            let color = try Self.color(text, key: "text_color")
            changes.append { $0.textColor = color }
        }
        if let text = try args.string("fill_color") {
            let color = try Self.color(text, key: "fill_color")
            changes.append { $0.fillColor = color }
        }
        if let text = try args.string("horizontal_alignment") {
            guard let alignment = text == "general" ? .automatic : TextAlignmentH(rawValue: text) else {
                throw ToolError("`horizontal_alignment` must be general, left, center or right.")
            }
            changes.append { $0.horizontalAlignment = alignment }
        }
        if let text = try args.string("vertical_alignment") {
            guard let alignment = TextAlignmentV(rawValue: text) else {
                throw ToolError("`vertical_alignment` must be top, middle or bottom.")
            }
            changes.append { $0.verticalAlignment = alignment }
        }
        guard !changes.isEmpty else { throw ToolError("Nothing to change: pass at least one format.") }
        activate(sheet, in: doc)
        try edit(doc) {
            doc.applyStyle(to: range, actionName: "Agent Format", addressDependent: false) { _, style in
                for change in changes { change(&style) }
            }
        }
        return ["sheet": .string(sheet.name), "range": .string(range.a1)]
    }

    func structural(_ args: Arguments, rows: Bool, insert: Bool) throws -> JSONValue {
        let doc = try document(args).document
        let sheet = try self.sheet(named: try args.string("sheet"), in: doc)
        let count = try args.int("count") ?? 1
        let index: Int
        if rows {
            guard let row = try args.int("row"), (1...CellAddress.maxRows).contains(row) else {
                throw ToolError("`row` must be a row number from 1 to \(CellAddress.maxRows).")
            }
            index = row - 1
        } else {
            guard let column = CellAddress.columnIndex(try args.requiredString("column")),
                  column < CellAddress.maxColumns else {
                throw ToolError("`column` must be a column letter, e.g. \"C\".")
            }
            index = column
        }
        let limit = rows ? CellAddress.maxRows : CellAddress.maxColumns
        guard count >= 1, index + count <= limit else {
            throw ToolError("`count` must be at least 1 and stay inside the sheet.")
        }
        if let table = WorkbookOperations.pivotTableSplit(in: doc.workbook, sheetID: sheet.id, axisIsRow: rows,
                                                          index: index, count: insert ? count : -count) {
            throw ToolError("This would cut through the pivot table “\(table.name)”. Insert or delete "
                + (rows ? "rows" : "columns") + " entirely outside it, or delete all of its own to remove it.")
        }
        activate(sheet, in: doc)
        let name = (insert ? "Agent Insert " : "Agent Delete ") + (rows ? "Rows" : "Columns")
        try edit(doc, name) {
            switch (rows, insert) {
            case (true, true): doc.insertRows(at: index, count: count)
            case (true, false): doc.deleteRows(at: index, count: count)
            case (false, true): doc.insertColumns(at: index, count: count)
            case (false, false): doc.deleteColumns(at: index, count: count)
            }
        }
        let first = rows ? String(index + 1) : CellAddress.columnName(index)
        let last = rows ? String(index + count) : CellAddress.columnName(index + count - 1)
        return ["sheet": .string(sheet.name), insert ? "inserted" : "deleted": .string("\(first):\(last)")]
    }

    func setColumnWidth(_ args: Arguments) throws -> JSONValue {
        let doc = try document(args).document
        let sheet = try self.sheet(named: try args.string("sheet"), in: doc)
        let text = try args.requiredString("columns")
        let parts = text.split(separator: ":", maxSplits: 1).map { CellAddress.columnIndex(String($0)) }
        guard let first = parts.first ?? nil, let last = parts.last ?? nil,
              max(first, last) < CellAddress.maxColumns else {
            throw ToolError("`columns` must be a column letter (\"B\") or letters (\"B:D\").")
        }
        guard let width = try args.number("width"), (12...2000).contains(width) else {
            throw ToolError("`width` must be 12 to 2000 points.")
        }
        let columns = (min(first, last)...max(first, last)).filter { sheet.columnWidth($0) != width }
        activate(sheet, in: doc)
        if !columns.isEmpty {
            try edit(doc, "Agent Column Width") {
                for column in columns { doc.setColumnWidth(column, width: width) }
            }
        }
        return ["sheet": .string(sheet.name), "columns": .string(text), "width": .number(width)]
    }

    func addSheet(_ args: Arguments) throws -> JSONValue {
        let doc = try document(args).document
        let name = try args.string("name")
        if let name, Workbook.sanitizeSheetName(name).isEmpty {
            throw ToolError("\"\(name)\" can't be a sheet name.")
        }
        try edit(doc, "Agent Add Sheet") {
            doc.addSheet()
            if let name { doc.renameActiveSheet(to: name) }
        }
        return ["sheet": .string(doc.activeSheet.name)]
    }

    func renameSheet(_ args: Arguments) throws -> JSONValue {
        let doc = try document(args).document
        let sheet = try self.sheet(named: try args.requiredString("sheet"), in: doc)
        let name = try args.requiredString("name")
        guard !Workbook.sanitizeSheetName(name).isEmpty else { throw ToolError("\"\(name)\" can't be a sheet name.") }
        let old = sheet.name
        activate(sheet, in: doc)
        try edit(doc, "Agent Rename Sheet") { doc.renameActiveSheet(to: name) }
        return ["old_name": .string(old), "sheet": .string(sheet.name)]
    }

    func deleteSheet(_ args: Arguments) throws -> JSONValue {
        let doc = try document(args).document
        let sheet = try self.sheet(named: try args.requiredString("sheet"), in: doc)
        guard doc.workbook.sheets.count > 1 else { throw ToolError("A workbook keeps at least one sheet.") }
        let name = sheet.name
        activate(sheet, in: doc)
        try edit(doc, "Agent Delete Sheet") { doc.deleteActiveSheet() }
        return ["deleted": .string(name), "active_sheet": .string(doc.activeSheet.name)]
    }

    /// A save's outcome, as the tool reports it.
    enum SaveResult: Sendable {
        case saved
        case cancelled
        case failed(String)
    }

    func saveDocument(_ args: Arguments) async throws -> JSONValue {
        let doc = try document(args).document
        // Commit nothing behind the user's back: their typing is theirs to finish.
        guard !doc.hasPendingEdit else { throw ToolError("The user is typing in a cell. Try again in a moment.") }
        if BackgroundSaver.isSaving(doc) {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                BackgroundSaver.whenIdle(doc) { done.resume() }
            }
        }
        switch DocumentSaving.plan(for: doc) {
        case .choose:
            throw ToolError("“\(doc.displayName)” has no .xlsx file to save to (it is new, or was opened from a "
                + "CSV or Excel 97–2003 file). Ask the user to save it with File ▸ Save As…; after that it can be "
                + "saved with this tool.")
        case .confirmLoss(_, let items):
            throw ToolError("Saving over “\(doc.saveFileName)” would remove its \(DocumentSaving.list(items)), which "
                + "SimpleSpread can't write back. Ask the user to save it (File ▸ Save) and choose whether to save a "
                + "copy or save anyway.")
        case .write(let url):
            guard doc.isModified else {
                return ["saved": false, "path": .string(url.path), "reason": "No unsaved changes."]
            }
            let result = await withCheckedContinuation { (done: CheckedContinuation<SaveResult, Never>) in
                BackgroundSaver.save(doc, to: url, in: windows.window(doc)) { outcome in
                    switch outcome {
                    case .saved: done.resume(returning: .saved)
                    case .cancelled: done.resume(returning: .cancelled)
                    case .failed(let error): done.resume(returning: .failed(error.localizedDescription))
                    }
                }
            }
            switch result {
            case .saved:
                windows.didSave(url)
                return ["saved": true, "path": .string(url.path)]
            case .cancelled:
                throw ToolError("The user cancelled the save.")
            case .failed(let message):
                throw ToolError("Couldn't save “\(doc.saveFileName)”: \(message)")
            }
        }
    }

    func closeDocument(_ args: Arguments) throws -> JSONValue {
        guard args.raw("document") != nil else {
            throw ToolError("Pass `document` (an id or name from list_documents) to say which window to close.")
        }
        let open = try document(args)
        let doc = open.document
        guard !doc.hasPendingEdit else { throw ToolError("The user is typing in a cell. Try again in a moment.") }
        guard !BackgroundSaver.isSaving(doc) else { throw ToolError("“\(doc.displayName)” is still saving.") }
        guard !doc.isModified else {
            throw ToolError("“\(doc.displayName)” has unsaved changes. Save it with save_document first, or leave "
                + "closing it to the user.")
        }
        let quits = openDocuments().count == 1
        guard windows.close(doc) else { throw ToolError("Couldn't find the window showing “\(doc.displayName)”.") }
        var result: [String: JSONValue] = ["closed": .string(doc.displayName), "id": .number(Double(open.id))]
        if quits { result["note"] = "That was the last window, so SimpleSpread quits." }
        return .object(result)
    }

    func screenshot(_ args: Arguments) async throws -> Output {
        let doc = try document(args).document
        if try args.string("range") != nil {
            _ = try selectRange(args)
        } else if let name = try args.string("sheet") {
            activate(try sheet(named: name, in: doc), in: doc)
        }
        // Let the window catch up first: the scroll, a sheet switch, the
        // last edit all draw on a later turn of the run loop.
        try? await Task.sleep(for: .milliseconds(250))
        guard let png = windows.snapshot(doc) else {
            throw ToolError("Couldn't capture the window showing “\(doc.displayName)”.")
        }
        let info: JSONValue = ["sheet": .string(doc.activeSheet.name), "selection": .string(doc.selection.range.a1)]
        return .content([["type": "text", "text": .string(info.encodedString)],
                         ["type": "image", "data": .string(png.base64EncodedString()), "mimeType": "image/png"]])
    }

    func selectRange(_ args: Arguments) throws -> JSONValue {
        let doc = try document(args).document
        let (sheet, range) = try range(try args.requiredString("range"), sheetName: try args.string("sheet"), in: doc)
        activate(sheet, in: doc)
        doc.selection.select(range: range)
        doc.requestScrollToActiveCell()
        return ["sheet": .string(sheet.name), "selection": .string(range.a1)]
    }
}
#endif
