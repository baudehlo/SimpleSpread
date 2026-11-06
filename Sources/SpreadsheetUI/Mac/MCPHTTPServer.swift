#if os(macOS)
import Foundation
import Network

/// MCP's Streamable HTTP transport, as small as it can be: POST /mcp with a
/// JSON-RPC message, answered with one JSON body (no event streams, no
/// sessions; GET is refused with 405, which the spec allows). One request
/// per connection.
///
/// Who may talk to it: the server listens on 127.0.0.1 only, every request
/// must carry the bearer token the user copied from Settings, and a Host or
/// Origin header naming anything but this machine is refused, so a web page
/// can't reach it by DNS rebinding.
public final class MCPHTTPServer: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case starting
        case listening(port: UInt16)
        case failed(String)
        case stopped
    }

    struct Request {
        var method: String
        var path: String
        /// Lowercased names.
        var headers: [String: String]
        var body: Data
    }

    struct Response: Equatable {
        var status: Int
        var headers: [(String, String)] = []
        var body = Data()

        static func == (a: Response, b: Response) -> Bool {
            a.status == b.status && a.body == b.body && a.headers.elementsEqual(b.headers, by: ==)
        }

        static func json(_ data: Data) -> Response {
            Response(status: 200, headers: [("Content-Type", "application/json")], body: data)
        }

        static func error(_ status: Int, _ message: String, headers: [(String, String)] = []) -> Response {
            Response(status: status, headers: headers + [("Content-Type", "text/plain; charset=utf-8")],
                     body: Data((message + "\n").utf8))
        }
    }

    static let path = "/mcp"
    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 32 * 1024 * 1024

    let requestedPort: UInt16
    let token: String
    /// Answers one POST body (nil: 202, nothing to say).
    let handler: @MainActor @Sendable (Data) async -> Data?
    let onStateChange: @MainActor @Sendable (State) -> Void

    /// Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "com.kikiplan.simplespread.mcp")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var boundPort: UInt16 = 0

    /// `port` 0 picks a free one (tests).
    public init(port: UInt16, token: String,
                handler: @escaping @MainActor @Sendable (Data) async -> Data?,
                onStateChange: @escaping @MainActor @Sendable (State) -> Void) {
        self.requestedPort = port
        self.token = token
        self.handler = handler
        self.onStateChange = onStateChange
    }

    public func start() {
        queue.async { self.startOnQueue() }
    }

    public func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
        }
    }

    private func report(_ state: State) {
        let onStateChange = self.onStateChange
        Task { @MainActor in onStateChange(state) }
    }

    private func startOnQueue() {
        report(.starting)
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                     port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            report(.failed(error.localizedDescription))
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                self.boundPort = listener.port?.rawValue ?? self.requestedPort
                self.report(.listening(port: self.boundPort))
            case .failed(let error):
                self.report(.failed(Self.describe(error, port: self.requestedPort)))
                listener.cancel()
                self.listener = nil
            case .cancelled:
                self.report(.stopped)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    static func describe(_ error: NWError, port: UInt16) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "Port \(port) is in use by another app. Choose another port."
        }
        return error.localizedDescription
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections[key] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        // A client that never finishes its request is dropped.
        queue.asyncAfter(deadline: .now() + 60) { [weak connection] in connection?.cancel() }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch Self.parse(buffer) {
            case .complete(let request):
                self.respond(to: request, on: connection)
            case .invalid(let response):
                self.send(response, on: connection)
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func respond(to request: Request, on connection: NWConnection) {
        if let refusal = Self.refusal(for: request, port: boundPort, token: token) {
            send(refusal, on: connection)
            return
        }
        let handler = self.handler
        let body = request.body
        Task { @MainActor in
            let reply = await handler(body)
            self.queue.async {
                self.send(reply.map(Response.json) ?? Response(status: 202), on: connection)
            }
        }
    }

    private func send(_ response: Response, on connection: NWConnection) {
        connection.send(content: Self.serialize(response), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - HTTP

    enum ParseResult {
        case incomplete
        case complete(Request)
        case invalid(Response)
    }

    static func parse(_ buffer: Data) -> ParseResult {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHeaderBytes ? .invalid(.error(431, "Request headers too large")) : .incomplete
        }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .invalid(.error(400, "Bad request"))
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil {
            return .invalid(.error(411, "Send a Content-Length"))
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid(.error(400, "Bad Content-Length")) }
        guard length <= maxBodyBytes else { return .invalid(.error(413, "Request too large")) }
        let bodyStart = headerEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        var path = String(requestLine[1])
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        return .complete(Request(method: String(requestLine[0]), path: path, headers: headers,
                                 body: buffer[bodyStart..<(bodyStart + length)]))
    }

    /// Why `request` is turned away, or nil to answer it.
    static func refusal(for request: Request, port: UInt16, token: String) -> Response? {
        let local = ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"]
        guard let host = request.headers["host"]?.lowercased(), local.contains(host) else {
            return .error(403, "Forbidden host")
        }
        if let origin = request.headers["origin"]?.lowercased(),
           !local.contains(where: { origin == "http://" + $0 }) {
            return .error(403, "Forbidden origin")
        }
        guard request.path == path else { return .error(404, "Not found; the MCP endpoint is \(path)") }
        guard tokensMatch(request.headers["authorization"], "Bearer " + token) else {
            return .error(401, "Missing or wrong token; copy it from SimpleSpread Settings ▸ Agents",
                          headers: [("WWW-Authenticate", "Bearer")])
        }
        guard request.method == "POST" else {
            return .error(405, "Method not allowed", headers: [("Allow", "POST")])
        }
        return nil
    }

    /// Compares in time that doesn't depend on where they differ.
    static func tokensMatch(_ given: String?, _ expected: String) -> Bool {
        let a = Array((given ?? "").utf8), b = Array(expected.utf8)
        var difference = a.count ^ b.count
        for i in 0..<b.count { difference |= Int(b[i] ^ (i < a.count ? a[i] : 0)) }
        return difference == 0
    }

    static let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                          404: "Not Found", 405: "Method Not Allowed", 411: "Length Required",
                          413: "Payload Too Large", 431: "Request Header Fields Too Large"]

    static func serialize(_ response: Response) -> Data {
        var head = "HTTP/1.1 \(response.status) \(reasons[response.status] ?? "Error")\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + response.body
    }
}
#endif
