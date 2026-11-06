import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles
@testable import SpreadsheetUI

/// The MCP server agents edit open documents through: the JSON-RPC layer,
/// each tool against a real document (undo, sheets, pivot protection), the
/// HTTP checks, and a request over a live socket.
@MainActor
@Suite("MCP server for agents")
struct MCPServerTests {
    func a(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }

    func tools(_ docs: SpreadsheetDocument...) -> MCPTools {
        MCPTools(openDocuments: { docs.enumerated().map { MCPTools.OpenDocument(id: $0.offset + 1, document: $0.element) } })
    }

    /// Call a tool; the parsed JSON it returned, and whether it failed.
    func call(_ tools: MCPTools, _ name: String, _ arguments: JSONValue = [:]) async throws -> (JSONValue, Bool) {
        let result = await tools.call(name, arguments: arguments)
        let text = try #require(result["content"]?.arrayValue?.first?["text"]?.stringValue)
        let isError = result["isError"]?.boolValue ?? false
        return (isError ? .string(text) : try JSONValue.parse(Data(text.utf8)), isError)
    }

    // MARK: - JSON-RPC

    @Test func jsonKeepsWholeNumbersAndBooleansApart() async throws {
        let value = try JSONValue.parse(Data(#"{"id":1,"on":true,"n":1.5,"s":"x","z":null}"#.utf8))
        #expect(value["id"] == .number(1))
        #expect(value["on"] == .bool(true))
        #expect(value.encodedString == #"{"id":1,"n":1.5,"on":true,"s":"x","z":null}"#)
    }

    @Test func initializeListAndUnknownMethods() async throws {
        let endpoint = MCPEndpoint(tools: tools(SpreadsheetDocument()))
        func send(_ text: String) async throws -> JSONValue? {
            try await endpoint.handle(Data(text.utf8)).map(JSONValue.parse)
        }
        let initialized = try #require(try await send(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#))
        #expect(initialized["id"] == 1)
        #expect(initialized["result"]?["protocolVersion"] == "2025-03-26")
        #expect(initialized["result"]?["capabilities"]?["tools"] != nil)
        #expect(initialized["result"]?["serverInfo"]?["name"] == "SimpleSpread")

        let future = try #require(try await send(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#))
        #expect(future["result"]?["protocolVersion"] == .string(MCPEndpoint.protocolVersions[0]))

        #expect(try await send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)

        let list = try #require(try await send(#"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#))
        let names = try #require(list["result"]?["tools"]?.arrayValue).compactMap { $0["name"]?.stringValue }
        #expect(names.contains("write_cells") && names.contains("read_range") && names.contains("list_documents"))
        #expect(list["id"] == "a")

        #expect(try await send(#"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#)?["error"]?["code"] == -32601)
        #expect(try await send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"nope"}}"#)?["error"]?["code"] == -32602)
        #expect(try await send("not json")?["error"]?["code"] == -32700)

        let batch = try #require(try await send(#"[{"jsonrpc":"2.0","id":5,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]"#))
        #expect(batch.arrayValue?.count == 1)
    }

    // MARK: - Tools

    @Test func writeCellsTypesFormulasAndIsOneUndoStep() async throws {
        let doc = SpreadsheetDocument()
        doc.commitInput("keep", at: a("C1"))
        let tools = tools(doc)
        let (result, failed) = try await call(tools, "write_cells", [
            "start": "A1",
            "values": [["Item", "Qty", nil], ["Widgets", 12, "=B2*2"], ["Total", "=SUM(B2:B2)", true]],
        ])
        #expect(!failed)
        #expect(result["range"] == "A1:C3")
        #expect(result["values"] == [["Item", "Qty", "keep"], ["Widgets", 12, 24], ["Total", 12, true]])
        #expect(doc.editString(at: a("C2")) == "=B2*2")
        #expect(doc.isModified)
        #expect(doc.undoManager.undoActionName == "Agent Edit")

        doc.undoManager.undo()
        #expect(doc.activeSheet.value(at: a("A1")) == .empty)
        #expect(doc.activeSheet.value(at: a("C1")) == .string("keep"))
        #expect(doc.undoManager.undoActionName == "Typing")
    }

    @Test func writtenTextIsReadAsTyped() async throws {
        let doc = SpreadsheetDocument()
        _ = try await call(tools(doc), "write_cells", ["start": "A1", "values": [["12%", "$4.50", "'00123", 0.1]]])
        #expect(doc.activeSheet.value(at: a("A1")) == .number(0.12))
        #expect(doc.displayString(at: a("B1")) == "$4.50")
        #expect(doc.activeSheet.value(at: a("C1")) == .string("00123"))
        #expect(doc.activeSheet.value(at: a("D1")) == .number(0.1))
    }

    @Test func editsShowTheSheetTheyChange() async throws {
        let doc = SpreadsheetDocument()
        doc.addSheet()
        doc.renameActiveSheet(to: "My Sheet")
        doc.selectSheet(withID: doc.workbook.sheets[0].id)
        let tools = tools(doc)
        _ = try await call(tools, "write_cells", ["start": "'My Sheet'!B2", "values": [["x"]]])
        #expect(doc.activeSheet.name == "My Sheet")
        #expect(doc.activeSheet.value(at: a("B2")) == .string("x"))

        _ = try await call(tools, "write_cells", ["sheet": "sheet1", "start": "A1", "values": [["y"]]])
        #expect(doc.activeSheet.name == "Sheet1")

        let (missing, failed) = try await call(tools, "write_cells", ["sheet": "Nope", "start": "A1", "values": [["z"]]])
        #expect(failed)
        #expect(missing.stringValue?.contains("\"My Sheet\"") == true)
    }

    @Test func readRangeReturnsValuesFormulasAndFormattedText() async throws {
        let doc = SpreadsheetDocument()
        doc.commitInput("Price", at: a("A1"))
        doc.commitInput("$2.50", at: a("A2"))
        doc.commitInput("=A2*2", at: a("B2"))
        let tools = tools(doc)
        let (used, _) = try await call(tools, "read_range", ["include_formatted": true])
        #expect(used["range"] == "A1:B2")
        #expect(used["values"] == [["Price", nil], [2.5, 5]])
        #expect(used["formulas"] == [[nil, nil], [nil, "=A2*2"]])
        #expect(used["formatted"]?.arrayValue?[1].arrayValue?[0] == "$2.50")

        let (column, _) = try await call(tools, "read_range", ["range": "A:A"])
        #expect(column["range"] == "A1:A2")
        #expect(column["formulas"] == nil)

        doc.selection.select(range: CellRange(a1: "B2")!)
        let (selected, _) = try await call(tools, "read_range", ["range": "selection"])
        #expect(selected["values"] == [[5]])

        let (empty, _) = try await call(tools, "read_range", ["sheet": "Sheet1", "range": "Z100:Z101"])
        #expect(empty["values"] == [[nil], [nil]])

        // Past the limit, a range is cut down to the part that holds anything.
        let (big, _) = try await call(tools, "read_range", ["range": "A1:Z1000"])
        #expect(big["range"] == "A1:B2")
        let block: JSONValue = .array(Array(repeating: .array(Array(repeating: 1, count: 101)), count: 100))
        let (tooBig, failed) = try await call(tools, "write_cells", ["start": "A1", "values": block])
        #expect(failed)
        #expect(tooBig.stringValue?.contains("at most") == true)
    }

    @Test func rangesInEveryForm() {
        #expect(MCPTools.parseRange("B2") == CellRange(a1: "B2"))
        #expect(MCPTools.parseRange("D4:B2") == CellRange(a1: "B2:D4"))
        #expect(MCPTools.parseRange("B:C")?.end == CellAddress(row: CellAddress.maxRows - 1, column: 2))
        #expect(MCPTools.parseRange("3:5")?.start == CellAddress(row: 2, column: 0))
        #expect(MCPTools.parseRange("A0") == nil)
        #expect(MCPTools.parseRange("hello") == nil)
        #expect(MCPTools.parseRange("A1:") == nil)
    }

    @Test func formatAndClearKeepEachOtherApart() async throws {
        let doc = SpreadsheetDocument()
        let tools = tools(doc)
        _ = try await call(tools, "write_cells", ["start": "A1", "values": [[1234.5, "text"]]])
        let (_, failed) = try await call(tools, "format_range", [
            "range": "A1:B1", "bold": true, "number_format": "currency", "fill_color": "#FFF4CC",
            "horizontal_alignment": "center",
        ])
        #expect(!failed)
        #expect(doc.style(at: a("B1")).bold)
        #expect(doc.style(at: a("A1")).fillColor == RGBAColor(red: 0xFF, green: 0xF4, blue: 0xCC))
        #expect(doc.displayString(at: a("A1")) == "$1,234.50")
        #expect(doc.undoManager.undoActionName == "Agent Format")

        let (_, clearFailed) = try await call(tools, "clear_range", ["range": "A1:B1"])
        #expect(!clearFailed)
        #expect(doc.activeSheet.value(at: a("A1")) == .empty)
        #expect(doc.style(at: a("A1")).bold)
        doc.undoManager.undo()
        #expect(doc.activeSheet.value(at: a("A1")) == .number(1234.5))

        let (bad, badFailed) = try await call(tools, "format_range", ["range": "A1", "fill_color": "yellow"])
        #expect(badFailed)
        #expect(bad.stringValue?.contains("#RRGGBB") == true)
        let (_, nothing) = try await call(tools, "format_range", ["range": "A1"])
        #expect(nothing)
    }

    @Test func pivotTablesAreProtectedWithoutAnAlert() async throws {
        let doc = makePivotDocument()
        let tools = tools(doc)
        let (write, writeFailed) = try await call(tools, "write_cells", ["start": "C6", "values": [[99]]])
        #expect(writeFailed)
        #expect(write.stringValue?.contains("Sales") == true)
        let (_, clearFailed) = try await call(tools, "clear_range", ["range": "B1:D10"])
        #expect(clearFailed)
        // The document refuses this one itself; the agent hears why, the
        // window shows nothing.
        let (insert, insertFailed) = try await call(tools, "insert_rows", ["row": 6])
        #expect(insertFailed)
        #expect(insert.stringValue?.contains("pivot table") == true)
        #expect(doc.notice == nil)
        let (_, rowsAbove) = try await call(tools, "insert_rows", ["row": 1])
        #expect(!rowsAbove)
        #expect(doc.undoManager.undoActionName == "Agent Insert Rows")
        doc.undoManager.undo()
        #expect(!doc.undoManager.canUndo) // the refusals left no empty steps behind
        #expect(doc.activeSheet.value(at: a("C6")) == .number(4))
    }

    @Test func rowsColumnsAndSheets() async throws {
        let doc = SpreadsheetDocument()
        let tools = tools(doc)
        _ = try await call(tools, "write_cells", ["start": "A1", "values": [["a", "=A1&\"!\""], ["b", nil]]])
        _ = try await call(tools, "insert_rows", ["row": 1, "count": 2])
        #expect(doc.activeSheet.value(at: a("A3")) == .string("a"))
        #expect(doc.editString(at: a("B3")) == "=A3&\"!\"")
        #expect(doc.undoManager.undoActionName == "Agent Insert Rows")
        _ = try await call(tools, "delete_columns", ["column": "A"])
        #expect(doc.editString(at: a("A3")) == "=#REF!&\"!\"")
        _ = try await call(tools, "set_column_width", ["columns": "B:C", "width": 150])
        #expect(doc.activeSheet.columnWidth(2) == 150)
        doc.undoManager.undo()
        #expect(doc.activeSheet.columnWidth(1) == doc.activeSheet.defaultColumnWidth)
        #expect(doc.activeSheet.columnWidth(2) == doc.activeSheet.defaultColumnWidth)
        let steps = doc.undoManager.undoActionName
        _ = try await call(tools, "set_column_width", ["columns": "D", "width": 100]) // already 100
        #expect(doc.undoManager.undoActionName == steps)

        let (added, _) = try await call(tools, "add_sheet", ["name": "Summary"])
        #expect(added["sheet"] == "Summary")
        #expect(doc.activeSheet.name == "Summary")
        #expect(doc.undoManager.undoActionName == "Agent Add Sheet")
        let (renamed, _) = try await call(tools, "rename_sheet", ["sheet": "Summary", "name": "Sheet1"])
        #expect(renamed["sheet"] == "Sheet1 2") // taken: a unique name instead
        _ = try await call(tools, "delete_sheet", ["sheet": "Sheet1 2"])
        #expect(doc.workbook.sheets.count == 1)
        let (_, lastFailed) = try await call(tools, "delete_sheet", ["sheet": "Sheet1"])
        #expect(lastFailed)

        doc.undoManager.undo() // the delete
        #expect(doc.workbook.sheets.map(\.name) == ["Sheet1", "Sheet1 2"])
        doc.undoManager.undo() // the rename
        doc.undoManager.undo() // the add (add + name as one step)
        #expect(doc.workbook.sheets.map(\.name) == ["Sheet1"])
    }

    @Test func documentsByIDOrNameAndSelecting() async throws {
        let first = SpreadsheetDocument()
        let second = SpreadsheetDocument()
        second.suggestedFileName = "budget.csv"
        let tools = tools(first, second)
        let (list, _) = try await call(tools, "list_documents")
        #expect(list.arrayValue?.map { $0["name"] } == ["Untitled", "budget"])
        #expect(list.arrayValue?.first?["sheets"]?.arrayValue?.first?["used_range"] == .null)

        _ = try await call(tools, "write_cells", ["document": "budget", "start": "A1", "values": [["x"]]])
        _ = try await call(tools, "write_cells", ["document": 1, "start": "A1", "values": [["y"]]])
        #expect(second.activeSheet.value(at: a("A1")) == .string("x"))
        #expect(first.activeSheet.value(at: a("A1")) == .string("y"))
        let (_, failed) = try await call(tools, "read_range", ["document": 7])
        #expect(failed)

        _ = try await call(tools, "select_range", ["range": "B2:C4"])
        #expect(first.selection.range == CellRange(a1: "B2:C4"))
        #expect(!first.undoManager.undoActionName.contains("Select"))

        let (_, none) = try await call(MCPTools(openDocuments: { [] }), "list_documents")
        #expect(!none)
        let (_, noDocument) = try await call(MCPTools(openDocuments: { [] }), "read_range")
        #expect(noDocument)
    }

    @Test func savingOnlyWhatLosesNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("simplespread-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Budget.xlsx")
        let doc = SpreadsheetDocument()
        try doc.save(to: url)
        let tools = tools(doc)
        var saved: [URL] = []
        tools.windows.didSave = { saved.append($0) }

        let (unchanged, _) = try await call(tools, "save_document")
        #expect(unchanged["saved"] == false)

        _ = try await call(tools, "write_cells", ["start": "A1", "values": [["=6*7"]]])
        #expect(doc.isModified)
        let (result, failed) = try await call(tools, "save_document", ["document": "Budget"])
        #expect(!failed)
        #expect(result["saved"] == true)
        #expect(!doc.isModified)
        #expect(saved == [url])
        #expect(try XLSXReader.read(data: Data(contentsOf: url)).sheets[0].value(at: a("A1")) == .number(42))

        // As if just opened from a file with charts it can't write back.
        doc.unsupportedContent = ["3 charts"]
        doc.unsupportedContentAccepted = false
        doc.commitInput("x", at: a("B1"))
        let (loss, lossFailed) = try await call(tools, "save_document")
        #expect(lossFailed)
        #expect(loss.stringValue?.contains("3 charts") == true)
        #expect(doc.isModified)

        let untitled = SpreadsheetDocument()
        untitled.commitInput("x", at: a("A1"))
        let (new, newFailed) = try await call(self.tools(untitled), "save_document")
        #expect(newFailed)
        #expect(new.stringValue?.contains("Save As") == true)
    }

    @Test func closingNeverDiscardsWork() async throws {
        let first = SpreadsheetDocument()
        let second = SpreadsheetDocument()
        let tools = tools(first, second)
        var closed: [ObjectIdentifier] = []
        tools.windows.close = { closed.append(ObjectIdentifier($0)); return true }

        let (_, unnamed) = try await call(tools, "close_document")
        #expect(unnamed)
        second.commitInput("unsaved", at: a("A1"))
        let (refusal, refused) = try await call(tools, "close_document", ["document": 2])
        #expect(refused)
        #expect(refusal.stringValue?.contains("unsaved changes") == true)

        let (result, failed) = try await call(tools, "close_document", ["document": 1])
        #expect(!failed)
        #expect(result["note"] == nil)
        #expect(closed == [ObjectIdentifier(first)])

        let alone = self.tools(first)
        alone.windows.close = { _ in true }
        let (last, _) = try await call(alone, "close_document", ["document": 1])
        #expect(last["note"]?.stringValue?.contains("quits") == true)
    }

    // MARK: - HTTP

    func request(_ method: String = "POST", path: String = "/mcp", headers: [String: String] = [:]) -> MCPHTTPServer.Request {
        let base = ["host": "127.0.0.1:52700", "authorization": "Bearer secret"]
        return MCPHTTPServer.Request(method: method, path: path,
                                     headers: base.merging(headers) { _, new in new }, body: Data())
    }

    @Test func httpRefusesStrangersAndWebPages() {
        func status(_ r: MCPHTTPServer.Request) -> Int? {
            MCPHTTPServer.refusal(for: r, port: 52700, token: "secret")?.status
        }
        #expect(status(request()) == nil)
        #expect(status(request(headers: ["host": "localhost:52700", "origin": "http://localhost:52700"])) == nil)
        #expect(status(request(headers: ["host": "evil.example:52700"])) == 403) // DNS rebinding
        #expect(status(request(headers: ["origin": "https://evil.example"])) == 403)
        #expect(status(request(headers: ["authorization": "Bearer wrong"])) == 401)
        #expect(status(request(headers: ["authorization": ""])) == 401)
        #expect(status(request(path: "/other")) == 404)
        #expect(status(request("GET")) == 405)
    }

    @Test func httpParsingWaitsForTheWholeBody() {
        let head = "POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1:1\r\nContent-Length: 4\r\n\r\n"
        guard case .incomplete = MCPHTTPServer.parse(Data((head + "ab").utf8)) else {
            Issue.record("a partial body is incomplete"); return
        }
        guard case .complete(let request) = MCPHTTPServer.parse(Data((head + "abcd").utf8)) else {
            Issue.record("the whole body completes it"); return
        }
        #expect(request.path == "/mcp")
        #expect(request.headers["content-length"] == "4")
        #expect(request.body == Data("abcd".utf8))
        guard case .invalid(let response) = MCPHTTPServer.parse(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) else {
            Issue.record("chunked bodies are refused"); return
        }
        #expect(response.status == 411)
    }

    @Test func aRequestOverARealSocket() async throws {
        let doc = SpreadsheetDocument()
        let endpoint = MCPEndpoint(tools: tools(doc))
        let seen = StateLog()
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let server = MCPHTTPServer(port: 0, token: "secret", handler: { await endpoint.handle($0) }, onStateChange: { state in
                seen.states.append(state)
                guard !seen.resumed else { return }
                switch state {
                case .listening(let port): seen.resumed = true; continuation.resume(returning: port)
                case .failed(let message): seen.resumed = true; continuation.resume(throwing: MCPTools.ToolError(message))
                default: break
                }
            })
            server.start()
            Self.running = server
        }
        defer { Self.running?.stop() }

        func post(_ body: String, token: String = "secret") async throws -> (Int, Data) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = Data(body.utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }

        let (status, data) = try await post(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"write_cells","arguments":{"start":"A1","values":[["=6*7"]]}}}"#)
        #expect(status == 200)
        #expect(try JSONValue.parse(data)["result"]?["isError"] == false)
        #expect(doc.activeSheet.value(at: a("A1")) == .number(42))

        #expect(try await post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).0 == 202)
        #expect(try await post(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#, token: "nope").0 == 401)
        #expect(seen.states.first == .starting)
    }

    /// What the live server reported, in order.
    @MainActor final class StateLog {
        var states: [MCPHTTPServer.State] = []
        var resumed = false
    }

    /// Keeps the live server alive for the length of its test.
    nonisolated(unsafe) static var running: MCPHTTPServer?
}
