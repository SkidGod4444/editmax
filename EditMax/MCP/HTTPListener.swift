import Foundation
import Network
import MCP

/// Minimal HTTP/1.1 server on Network.framework, bound to loopback only.
/// One request per connection (`Connection: close`), which is all the MCP Streamable HTTP client needs.
final class HTTPListener {
    typealias Handler = (HTTPRequest) async -> HTTPResponse

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "io.openhorizon.editmax.http")
    private let handler: Handler
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    init(handler: @escaping Handler) { self.handler = handler }

    func start(port: UInt16) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            let c = HTTPConnection(conn, handler: self.handler) { [weak self] id in self?.queue.async { self?.connections[id] = nil } }
            self.queue.async { self.connections[ObjectIdentifier(c)] = c }
            c.start(on: self.queue)
        }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel(); listener = nil
        queue.async { self.connections.values.forEach { $0.cancel() }; self.connections.removeAll() }
    }
}

final class HTTPConnection {
    private let conn: NWConnection
    private let handler: HTTPListener.Handler
    private let onClose: (ObjectIdentifier) -> Void
    private var buffer = Data()
    private var handled = false

    init(_ conn: NWConnection, handler: @escaping HTTPListener.Handler, onClose: @escaping (ObjectIdentifier) -> Void) {
        self.conn = conn; self.handler = handler; self.onClose = onClose
    }

    func start(on queue: DispatchQueue) {
        conn.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.cancel() }
            if case .cancelled = state, let self { self.onClose(ObjectIdentifier(self)) }
        }
        conn.start(queue: queue)
        receive()
    }

    func cancel() { conn.cancel() }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if error != nil { self.cancel(); return }
            if self.tryHandle() { return }
            if isComplete { self.cancel(); return }
            self.receive()
        }
    }

    /// Returns true once a complete request has been parsed and dispatched.
    private func tryHandle() -> Bool {
        guard !handled, let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let headData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let head = String(data: headData, encoding: .utf8) else { write(.error(statusCode: 400, .invalidRequest("Bad request"))); return true }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard requestLine.count >= 2 else { write(.error(statusCode: 400, .invalidRequest("Bad request line"))); return true }
        var headers: [String: String] = [:]
        for line in lines {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<i]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers.first { $0.key.lowercased() == "content-length" }?.value ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return false }
        let body = length > 0 ? Data(buffer[bodyStart..<bodyStart + length]) : nil
        handled = true
        let path = requestLine[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? requestLine[1]
        let request = HTTPRequest(method: requestLine[0].uppercased(), headers: headers, body: body, path: path)
        Task { [handler] in
            let response = await handler(request)
            self.write(response)
        }
        return true
    }

    private func write(_ response: HTTPResponse) {
        let reason: [Int: String] = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable", 415: "Unsupported Media Type", 421: "Misdirected Request", 500: "Internal Server Error"]
        var headers = response.headers
        headers["Connection"] = "close"
        if case .stream(let stream, _) = response {
            headers["Transfer-Encoding"] = "chunked"
            if headers["Content-Type"] == nil { headers["Content-Type"] = "text/event-stream" }
            var head = "HTTP/1.1 200 OK\r\n"
            headers.forEach { head += "\($0.key): \($0.value)\r\n" }
            head += "\r\n"
            conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            Task {
                do {
                    for try await chunk in stream {
                        var d = Data("\(String(chunk.count, radix: 16))\r\n".utf8); d.append(chunk); d.append(Data("\r\n".utf8))
                        self.conn.send(content: d, completion: .contentProcessed { _ in })
                    }
                } catch {}
                self.conn.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { _ in self.conn.cancel() })
            }
            return
        }
        let body = response.bodyData ?? Data()
        headers["Content-Length"] = String(body.count)
        if !body.isEmpty, headers["Content-Type"] == nil { headers["Content-Type"] = "application/json" }
        var head = "HTTP/1.1 \(response.statusCode) \(reason[response.statusCode] ?? "OK")\r\n"
        headers.forEach { head += "\($0.key): \($0.value)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8); out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in self.conn.cancel() })
    }
}
