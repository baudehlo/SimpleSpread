#if os(macOS)
import Foundation

/// A JSON value: what MCP messages, tool arguments and tool results are
/// made of. Objects encode with sorted keys, whole numbers without a
/// fraction (so a request id of 1 comes back as 1).
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var isNull: Bool { self == .null }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    public var encodedString: String { String(decoding: encoded(), as: UTF8.self) }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n):
            if !n.isFinite {
                try container.encodeNil()
            } else if n == n.rounded(), abs(n) < 1e15 {
                try container.encode(Int64(n))
            } else {
                try container.encode(n)
            }
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                     ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
                     ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

/// The Model Context Protocol over JSON-RPC 2.0: lifecycle (`initialize`,
/// `ping`) and tools (`tools/list`, `tools/call`). Transport-free: the
/// HTTP server (MCPHTTPServer) hands each POST body to `handle`.
@MainActor
public final class MCPEndpoint {
    /// Protocol revisions this server speaks; a client asking for one of
    /// them gets it, any other gets the first.
    static let protocolVersions = ["2025-06-18", "2025-11-25", "2025-03-26", "2024-11-05"]

    let tools: MCPTools

    public init(tools: MCPTools) {
        self.tools = tools
    }

    /// The reply to one POST body, or nil when it held only notifications
    /// or responses (HTTP 202, no body).
    public func handle(_ body: Data) async -> Data? {
        let message: JSONValue
        do {
            message = try JSONValue.parse(body)
        } catch {
            return Self.errorResponse(id: .null, code: -32700, message: "Parse error").encoded()
        }
        if case .array(let batch) = message {
            var replies: [JSONValue] = []
            for message in batch {
                if let reply = await handle(message: message) { replies.append(reply) }
            }
            return replies.isEmpty ? nil : JSONValue.array(replies).encoded()
        }
        return await handle(message: message)?.encoded()
    }

    func handle(message: JSONValue) async -> JSONValue? {
        guard case .object = message, let method = message["method"]?.stringValue else {
            // A response to us, or not JSON-RPC: nothing to answer unless it
            // carries an id.
            if let id = message["id"], message["result"] == nil, message["error"] == nil {
                return Self.errorResponse(id: id, code: -32600, message: "Invalid request")
            }
            return nil
        }
        // Notifications (no id) get no reply: notifications/initialized,
        // notifications/cancelled, …
        guard let id = message["id"] else { return nil }
        let params = message["params"] ?? [:]
        switch method {
        case "initialize":
            return Self.result(id: id, initializeResult(params))
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": .array(tools.definitions)])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return Self.errorResponse(id: id, code: -32602, message: "Missing tool name")
            }
            guard tools.has(name) else {
                return Self.errorResponse(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
            return Self.result(id: id, await tools.call(name, arguments: params["arguments"] ?? [:]))
        default:
            return Self.errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func initializeResult(_ params: JSONValue) -> JSONValue {
        let requested = params["protocolVersion"]?.stringValue ?? ""
        let version = Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "SimpleSpread", "title": "SimpleSpread", "version": .string(AppInfo.currentVersion)],
            "instructions": .string(MCPTools.instructions),
        ]
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }
}
#endif
