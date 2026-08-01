import Foundation
import Network
import Security

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
}

struct HTTPResponse {
    var status: Int = 200
    var contentType: String = "text/plain; charset=utf-8"
    var body: Data = Data()
    var extraHeaders: [String: String] = [:]

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json", body: data)
    }

    static func text(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: Data(string.utf8))
    }
}

/// HTTP and WebSocket over a single port, optionally wrapped in TLS.
///
/// Sharing one port is what makes the rest of the product tractable: one origin, one certificate to
/// trust, one URL to put in a QR code, and no reverse-proxy configuration that has to know about a
/// second socket.
final class Server {
    final class Client {
        let connection: NWConnection
        var authenticated = false
        var inFlight = 0
        /// Nothing is sent to a client until its first keyframe. Requesting an IDR at auth time is
        /// not enough on its own, because a delta frame already in flight can beat it to the socket.
        var awaitingKeyframe = true
        /// Touched only on the server queue, unlike the flags above.
        var inbox: [UInt8] = []
        var fragment = Data()
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private static let maxHeaderBytes = 1 << 16
    private static let maxBodyBytes = 1 << 22
    private static let maxFragmentBytes = 1 << 20

    private let queue = DispatchQueue(label: "screenlink.server", qos: .userInteractive)
    private let lock = NSLock()
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var token: String

    var httpHandler: ((HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void)?
    var onCommand: ((InputCommand) -> Void)?
    var onClientReady: (() -> Void)?
    var streamInfo: (() -> StreamInfo?)?
    var statusMessage: (() -> String)?

    init(token: String) {
        self.token = token
    }

    func start(host: NWEndpoint.Host, port: UInt16, identity: SecIdentity?) throws {
        let params: NWParameters
        if let identity, let secIdentity = sec_identity_create(identity) {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
            // TLS 1.2 is the floor: every browser that can run this client supports it, and older
            // versions only widen the attack surface.
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            params = NWParameters(tls: tls)
        } else {
            params = NWParameters.tcp
        }
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: host, port: .init(rawValue: port)!)

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { Log.error("listener failed: \(error)") }
        }
        listener.start(queue: queue)
        self.listener = listener

        let scheme = identity == nil ? "http" : "https"
        Log.info("listening on \(scheme)://\(host):\(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let open = Array(clients.values)
        clients.removeAll()
        lock.unlock()
        for client in open { client.connection.cancel() }
    }

    var clientCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return clients.values.filter { $0.authenticated }.count
    }

    /// Replaces the shared secret and hangs up on everyone, so the old link stops working
    /// immediately rather than at the end of whatever session is in progress.
    func rotateToken(to newToken: String) {
        lock.lock()
        token = newToken
        let open = Array(clients.values)
        clients.removeAll()
        lock.unlock()
        for client in open { client.connection.cancel() }
    }

    // MARK: - Connection lifecycle

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.drop(connection)
            default: break
            }
        }
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func drop(_ connection: NWConnection) {
        lock.lock()
        let removed = clients.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
        connection.cancel()
        if removed != nil { Log.info("client disconnected") }
    }

    // MARK: - HTTP

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            if error != nil { connection.cancel(); return }

            var accumulated = buffer
            if let chunk { accumulated.append(chunk) }

            guard let headerEnd = Self.range(of: Data("\r\n\r\n".utf8), in: accumulated) else {
                if isComplete || accumulated.count > Self.maxHeaderBytes { connection.cancel() }
                else { self.readRequest(connection, buffer: accumulated) }
                return
            }

            let head = String(decoding: accumulated[..<headerEnd.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let parts = (lines.first ?? "").split(separator: " ")
            guard parts.count >= 2 else { connection.cancel(); return }

            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                let pieces = line.split(separator: ":", maxSplits: 1)
                guard pieces.count == 2 else { continue }
                headers[pieces[0].lowercased()] = pieces[1].trimmingCharacters(in: .whitespaces)
            }

            if headers["upgrade"]?.lowercased() == "websocket" {
                let leftover = accumulated[headerEnd.upperBound...]
                self.upgrade(connection, headers: headers, leftover: Data(leftover))
                return
            }

            let contentLength = Int(headers["content-length"] ?? "") ?? 0
            guard contentLength <= Self.maxBodyBytes else { connection.cancel(); return }

            let bodyStart = headerEnd.upperBound
            guard accumulated.count - bodyStart >= contentLength else {
                if isComplete { connection.cancel() } else { self.readRequest(connection, buffer: accumulated) }
                return
            }

            let body = accumulated.subdata(in: bodyStart..<(bodyStart + contentLength))
            let target = String(parts[1])
            let split = target.split(separator: "?", maxSplits: 1)
            var query: [String: String] = [:]
            if split.count > 1 {
                for pair in split[1].split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    guard let key = kv.first else { continue }
                    let value = kv.count > 1 ? String(kv[1]) : ""
                    query[String(key)] = value.removingPercentEncoding ?? value
                }
            }

            let request = HTTPRequest(method: String(parts[0]), path: String(split.first ?? "/"),
                                      query: query, headers: headers, body: body)
            let respond: (HTTPResponse) -> Void = { response in
                connection.send(content: Self.serialize(response), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }

            if let handler = self.httpHandler { handler(request, respond) }
            else { respond(.text("not configured", status: 500)) }
        }
    }

    private static func serialize(_ response: HTTPResponse) -> Data {
        let reason: String
        switch response.status {
        case 200: reason = "OK"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 429: reason = "Too Many Requests"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        // This app can see and drive the whole machine, so no other origin may embed or script it.
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "X-Frame-Options: DENY\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        for (key, value) in response.extraHeaders { head += "\(key): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(response.body)
        return out
    }

    // MARK: - WebSocket

    private func upgrade(_ connection: NWConnection, headers: [String: String], leftover: Data) {
        guard let key = headers["sec-websocket-key"] else { connection.cancel(); return }

        let client = Client(connection)
        client.inbox = [UInt8](leftover)
        lock.lock()
        clients[ObjectIdentifier(connection)] = client
        lock.unlock()

        let response = WebSocketProtocol.handshakeResponse(acceptKey: WebSocketProtocol.acceptKey(for: key))
        connection.send(content: response, completion: .idempotent)

        guard processFrames(client) else { drop(connection); return }
        readFrames(client)
    }

    private func readFrames(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            if error != nil { self.drop(client.connection); return }
            if let chunk, !chunk.isEmpty {
                client.inbox.append(contentsOf: chunk)
                guard self.processFrames(client) else { self.drop(client.connection); return }
            }
            if isComplete { self.drop(client.connection); return }
            self.readFrames(client)
        }
    }

    /// Returns false when the connection should be torn down.
    private func processFrames(_ client: Client) -> Bool {
        guard let frames = WebSocketProtocol.decode(from: &client.inbox) else { return false }
        for frame in frames {
            switch frame.opcode {
            case .close:
                return false
            case .ping:
                send(frame.payload, to: client, opcode: .pong)
            case .pong:
                break
            case .text, .binary:
                if frame.isFinal {
                    handle(frame.payload, client: client)
                } else {
                    client.fragment = frame.payload
                }
            case .continuation:
                client.fragment.append(frame.payload)
                guard client.fragment.count <= Self.maxFragmentBytes else { return false }
                if frame.isFinal {
                    handle(client.fragment, client: client)
                    client.fragment = Data()
                }
            }
        }
        return true
    }

    private func handle(_ data: Data, client: Client) {
        guard let command = try? JSONDecoder().decode(InputCommand.self, from: data) else { return }

        if command.type == .auth {
            lock.lock()
            let expected = token
            lock.unlock()
            // Authenticating over the socket rather than the handshake URL keeps the token out of
            // proxy and server logs, which record request lines but not message payloads.
            guard let supplied = command.token, Self.constantTimeEquals(supplied, expected) else {
                Log.warn("client rejected: bad token")
                drop(client.connection)
                return
            }
            lock.lock()
            client.authenticated = true
            lock.unlock()
            Log.info("client authenticated")
            if let info = streamInfo?(), let json = try? JSONEncoder().encode(info) {
                send(json, to: client, opcode: .text)
            } else {
                let payload = ["type": "status", "message": statusMessage?() ?? "capture unavailable"]
                if let json = try? JSONSerialization.data(withJSONObject: payload) {
                    send(json, to: client, opcode: .text)
                }
            }
            onClientReady?()
            return
        }

        lock.lock()
        let ok = client.authenticated
        lock.unlock()
        guard ok else { return }

        if command.type == .keyframe {
            // The client rebuilt its decoder, so hold delta frames back until the new IDR arrives.
            lock.lock()
            client.awaitingKeyframe = true
            lock.unlock()
            onClientReady?()
            return
        }
        onCommand?(command)
    }

    /// Compares without leaking the position of the first mismatch through timing.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<lhs.count { diff |= lhs[i] ^ rhs[i] }
        return diff == 0
    }

    // MARK: - Sending

    func broadcast(_ frame: H264Encoder.Frame) {
        lock.lock()
        let targets = clients.values.filter {
            $0.authenticated && $0.inFlight <= 2 && (frame.isKeyframe || !$0.awaitingKeyframe)
        }
        for client in targets {
            client.inFlight += 1
            if frame.isKeyframe { client.awaitingKeyframe = false }
        }
        lock.unlock()
        guard !targets.isEmpty else { return }

        let payload = WebSocketProtocol.encode(BinaryFrame.encode(frame), opcode: .binary)
        for client in targets {
            client.connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                client.inFlight -= 1
                self.lock.unlock()
            })
        }
    }

    func broadcastJSON(_ data: Data) {
        lock.lock()
        let targets = clients.values.filter { $0.authenticated }
        lock.unlock()
        for client in targets { send(data, to: client, opcode: .text) }
    }

    private func send(_ data: Data, to client: Client, opcode: WebSocketProtocol.Opcode) {
        client.connection.send(content: WebSocketProtocol.encode(data, opcode: opcode),
                               completion: .idempotent)
    }

    private static func range(of needle: Data, in haystack: Data) -> Range<Int>? {
        guard haystack.count >= needle.count else { return nil }
        let bytes = [UInt8](haystack)
        let pattern = [UInt8](needle)
        let limit = bytes.count - pattern.count
        var i = 0
        while i <= limit {
            if Array(bytes[i..<(i + pattern.count)]) == pattern { return i..<(i + pattern.count) }
            i += 1
        }
        return nil
    }
}
