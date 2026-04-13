import Foundation
import Network

/// Tiny HTTP/1.1 server over Network.framework.
/// Accepts POST /hook with a JSON body, decodes a HookEvent, and forwards it.
final class HTTPServer {
    private var port: NWEndpoint.Port
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "agentpulse.http")
    private let onEvent: @Sendable (HookEvent) -> Void
    private let expectedToken: String

    /// Actual port the listener ended up on (may differ from requested
    /// port if we had to fall through to another one).
    private(set) var actualPort: UInt16 = 0

    init(port: UInt16, token: String, onEvent: @escaping @Sendable (HookEvent) -> Void) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.expectedToken = token
        self.onEvent = onEvent
    }

    /// Starts the listener. Tries `preferredPort`, then the next `maxTries`
    /// ports if the preferred one is taken. Returns the port it bound to.
    @discardableResult
    func start(preferredPort: UInt16, maxTries: UInt16) throws -> UInt16 {
        var lastError: Error = POSIXError(.EADDRINUSE)
        for offset in 0..<max(1, maxTries) {
            let candidate = UInt16(clamping: Int(preferredPort) + Int(offset))
            do {
                try bind(on: candidate)
                actualPort = candidate
                return candidate
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func bind(on candidate: UInt16) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let tcpOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            tcpOptions.version = .v4
        }
        guard let portEP = NWEndpoint.Port(rawValue: candidate) else {
            throw POSIXError(.EINVAL)
        }
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: portEP)

        let listener = try NWListener(using: params)
        let signal = DispatchSemaphore(value: 0)
        var bindError: Error?
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                NSLog("[AgentPulse] HTTP ready on 127.0.0.1:\(candidate)")
                signal.signal()
            case .failed(let err):
                bindError = err
                signal.signal()
            case .cancelled:
                signal.signal()
            default: break
            }
        }
        listener.start(queue: queue)

        // Wait synchronously for ready/fail so we can fall through to the
        // next port on EADDRINUSE. This runs once at app launch.
        let timed = signal.wait(timeout: .now() + .milliseconds(500))
        if timed == .timedOut {
            listener.cancel()
            throw POSIXError(.ETIMEDOUT)
        }
        if let err = bindError {
            listener.cancel()
            throw err
        }

        self.listener = listener
        self.port = portEP
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn, buffer: Data())
    }

    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }

            if let req = Self.parse(buf) {
                self.process(req, on: conn)
                return
            }

            if error != nil || isComplete {
                conn.cancel()
                return
            }
            self.receiveRequest(conn, buffer: buf)
        }
    }

    private struct Request {
        var method: String
        var path: String
        var token: String?
        var body: Data
    }

    private static func parse(_ data: Data) -> Request? {
        // Find header/body delimiter.
        let sep = Data([0x0d, 0x0a, 0x0d, 0x0a])
        guard let range = data.range(of: sep) else { return nil }
        let header = data.subdata(in: 0..<range.lowerBound)
        guard let headerStr = String(data: header, encoding: .utf8) else { return nil }

        let lines = headerStr.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var contentLength = 0
        var token: String?
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let v = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(v) ?? 0
            } else if lower.hasPrefix("x-agentpulse-token:") {
                token = String(line.dropFirst("x-agentpulse-token:".count)).trimmingCharacters(in: .whitespaces)
            }
        }

        let bodyStart = range.upperBound
        let available = data.count - bodyStart
        if available < contentLength { return nil }

        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        return Request(method: String(parts[0]), path: String(parts[1]),
                       token: token, body: body)
    }

    private func process(_ req: Request, on conn: NWConnection) {
        // /health is unauthenticated so diagnostics / loopback reachability
        // probes can work without the token.
        if req.method == "GET" && req.path == "/health" {
            respond(conn, status: 200, body: Data("ok".utf8))
            return
        }

        guard req.token == expectedToken else {
            respond(conn, status: 401, body: Data("unauthorized".utf8))
            return
        }

        if req.method == "POST" && req.path == "/hook" {
            do {
                let event = try JSONDecoder().decode(HookEvent.self, from: req.body)
                onEvent(event)
                respond(conn, status: 204, body: Data())
            } catch {
                NSLog("[AgentPulse] decode error: \(error) body=\(String(data: req.body, encoding: .utf8) ?? "")")
                respond(conn, status: 400, body: Data("bad json".utf8))
            }
        } else {
            respond(conn, status: 404, body: Data("not found".utf8))
        }
    }

    private func respond(_ conn: NWConnection, status: Int, body: Data) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 204: statusText = "No Content"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        default: statusText = "Status"
        }
        let header = """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Length: \(body.count)\r
        Content-Type: text/plain; charset=utf-8\r
        Connection: close\r
        \r

        """
        var out = Data(header.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
