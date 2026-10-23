import CryptoKit
import Foundation
import Network

/// Minimal HTTPS + WebSocket server on a single TLS port (Network.framework).
///
///   GET /?t=TOKEN     the trackpad page
///   GET /ws?t=TOKEN   WebSocket for input messages
///   GET /cert         the public root certificate (to install on the phone)
///   POST /voice?t=TOKEN  audio recorded on the phone (body), handed to Haki to type as text
///
/// Messages (phone → Mac), one JSON object per WebSocket text frame:
///   {"t":"m","dx":3,"dy":-2}    move cursor (pixels)
///   {"t":"c","b":"l","n":1}     click; b = "l" | "r", n = 2 for the 2nd click of a double click
///   {"t":"d","s":1}             press (1) / release (0) the left button, for dragging
///   {"t":"s","dx":0,"dy":-12}   scroll (pixels)
///   {"t":"g","d":"l"}           three-finger swipe; d = "l" | "r" | "u" | "d"
///
/// With "to":"tv" the same m / c / s messages drive the LG TV's pointer instead (a right
/// click is the Back key), plus:
///   {"t":"b","k":"HOME","to":"tv"}   remote control key
///   {"t":"h","to":"tv"}              the TV tab opened: connect to the TV
///
/// Mac → phone: {"t":"tv","s":"connected","m":"TV connected"} whenever the TV link changes.
final class Server {
    var onClientsChanged: ((Int) -> Void)?  // called on the main queue
    var onError: ((String) -> Void)?        // called on the main queue

    private let queue = DispatchQueue(label: "AirMouse.server")
    private let input: InputController
    private let tv: TVController
    private let port: UInt16
    private let pageURL: URL
    private let rootCAURL: URL
    private var token: String
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var heartbeat: DispatchSourceTimer?

    private static let maxDelta = 1000.0       // ignore absurd values from a misbehaving client
    private static let maxFrame = 4096         // our messages are tiny
    private static let maxUpload = 10 << 20    // voice clips: ~1 MB per minute of AAC
    private static let wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    private final class Session {
        let connection: NWConnection
        var buffer = Data()
        var isWebSocket = false
        var closed = false
        var lastSeen = Date()
        var upload: (length: Int, ext: String)?  // POST /voice body still arriving
        init(_ connection: NWConnection) { self.connection = connection }
    }

    init(port: UInt16, token: String, input: InputController, tv: TVController, pageURL: URL, rootCAURL: URL) {
        self.port = port
        self.token = token
        self.input = input
        self.tv = tv
        self.pageURL = pageURL
        self.rootCAURL = rootCAURL
    }

    // MARK: Lifecycle

    func start(identity: SecIdentity) throws {
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity) else { throw ServerError.identity }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)

        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            if case .failed(let error) = state {
                listener?.cancel()
                let message = error == .posix(.EADDRINUSE)
                    ? "Port \(self?.port ?? 0) is already in use (is the Python server running?)"
                    : error.localizedDescription
                DispatchQueue.main.async { self?.onError?(message) }
            }
        }
        queue.sync {
            self.listener = listener
            listener.start(queue: queue)
            startHeartbeat()
        }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            heartbeat?.cancel()
            heartbeat = nil
            sessions.values.forEach(close)
        }
    }

    /// New access token: existing phones are disconnected and must rescan the QR code.
    func setToken(_ newToken: String) {
        queue.async {
            self.token = newToken
            self.sessions.values.forEach(self.close)
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let session = Session(connection)
        sessions[ObjectIdentifier(session)] = session
        connection.stateUpdateHandler = { [weak self, weak session] state in
            guard let self, let session else { return }
            switch state {
            case .failed, .cancelled: self.close(session)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(session)
    }

    private func receive(_ session: Session) {
        session.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !session.closed else { return }
            if let data, !data.isEmpty {
                session.buffer.append(data)
                session.lastSeen = Date()
                if session.isWebSocket { self.processFrames(session) } else { self.processHTTP(session) }
            }
            if isComplete || error != nil { self.close(session) } else if !session.closed { self.receive(session) }
        }
    }

    private func close(_ session: Session) {
        guard !session.closed else { return }
        session.closed = true
        session.connection.cancel()
        sessions.removeValue(forKey: ObjectIdentifier(session))
        if session.isWebSocket {
            input.hold(false)  // never leave the button stuck down if the phone drops off
            notifyClients()
        }
    }

    private func notifyClients() {
        let count = sessions.values.filter(\.isWebSocket).count
        DispatchQueue.main.async { self.onClientsChanged?(count) }
    }

    /// Ping phones every 15 s and drop silent ones, so the menu bar status stays accurate.
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            for session in self.sessions.values {
                let idle = now.timeIntervalSince(session.lastSeen)
                if session.isWebSocket {
                    if idle > 45 { self.close(session) } else { self.sendFrame(session, opcode: 0x9) }
                } else if idle > 30 {
                    self.close(session)  // half-open or stalled HTTP request
                }
            }
        }
        timer.resume()
        heartbeat = timer
    }

    // MARK: HTTP

    private func processHTTP(_ session: Session) {
        if let upload = session.upload { return receiveUpload(session, upload) }
        guard let end = session.buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if session.buffer.count > 16384 { close(session) }
            return
        }
        let head = String(decoding: session.buffer[..<end.lowerBound], as: UTF8.self)
        session.buffer = Data(session.buffer[end.upperBound...])

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2, requestLine[0] == "GET" || requestLine[0] == "POST" else {
            return respond(session, status: "405 Method Not Allowed", body: Data("Method not allowed\n".utf8))
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let components = URLComponents(string: String(requestLine[1]))
        let path = components?.path ?? "/"
        let given = components?.queryItems?.first(where: { $0.name == "t" })?.value ?? ""
        let authorized = Self.constantTimeEqual(given, token)

        if requestLine[0] == "POST" {
            guard path == "/voice", authorized else {
                return respond(session, status: "403 Forbidden", body: Data("Forbidden\n".utf8))
            }
            guard let length = Int(headers["content-length"] ?? ""), length > 0 else {
                return respond(session, status: "411 Length Required", body: Data("Missing Content-Length\n".utf8))
            }
            guard length <= Self.maxUpload else {
                return respond(session, status: "413 Payload Too Large", body: Data("Recording too long\n".utf8))
            }
            session.upload = (length, VoiceHandoff.fileExtension(contentType: headers["content-type"]))
            return receiveUpload(session, session.upload!)
        }

        switch path {
        case "/cert":
            // Public root certificate only (never a key) — lets the phone install it as a profile.
            respond(session, status: "200 OK", type: "application/x-x509-ca-cert",
                    body: (try? Data(contentsOf: rootCAURL)) ?? Data(),
                    extra: ["Content-Disposition": "attachment; filename=\"AirMouse-rootCA.crt\""])
        case "/" where authorized:
            respond(session, status: "200 OK", type: "text/html; charset=utf-8",
                    body: (try? Data(contentsOf: pageURL)) ?? Data("index.html missing\n".utf8),
                    extra: ["Cache-Control": "no-store", "Referrer-Policy": "no-referrer"])
        case "/ws" where authorized && headers["upgrade"]?.lowercased() == "websocket":
            upgrade(session, key: headers["sec-websocket-key"])
        case "/", "/ws":
            respond(session, status: "403 Forbidden",
                    body: Data("Forbidden: scan the QR code from the AirMouse menu bar app.\n".utf8))
        default:
            respond(session, status: "404 Not Found", body: Data("Not found\n".utf8))
        }
    }

    /// Waits until the whole POST /voice body has arrived, then passes it to Haki.
    private func receiveUpload(_ session: Session, _ upload: (length: Int, ext: String)) {
        guard session.buffer.count >= upload.length else { return }
        let audio = Data(session.buffer.prefix(upload.length))
        session.buffer = Data()
        session.upload = nil
        do {
            try VoiceHandoff.send(audio, ext: upload.ext)
            respond(session, status: "200 OK", body: Data("OK\n".utf8))
        } catch {
            respond(session, status: "503 Service Unavailable", body: Data("\(error.localizedDescription)\n".utf8))
        }
    }

    private func respond(_ session: Session, status: String, type: String = "text/plain; charset=utf-8",
                         body: Data, extra: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in extra { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        session.connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in
            self?.queue.async { self?.close(session) }
        })
    }

    private func upgrade(_ session: Session, key: String?) {
        guard let key else {
            return respond(session, status: "400 Bad Request", body: Data("Missing Sec-WebSocket-Key\n".utf8))
        }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + Self.wsGUID).utf8))).base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        session.connection.send(content: Data(response.utf8), completion: .idempotent)
        session.isWebSocket = true
        input.refreshDisplays()  // pick up monitor changes on each new connection
        notifyClients()
        processFrames(session)   // in case frames arrived together with the handshake
    }

    // MARK: WebSocket

    private func processFrames(_ session: Session) {
        while !session.closed {
            let bytes = [UInt8](session.buffer.prefix(14))
            guard bytes.count >= 2 else { return }
            let opcode = bytes[0] & 0x0F
            let masked = bytes[1] & 0x80 != 0
            var length = Int(bytes[1] & 0x7F)
            var offset = 2
            if length == 126 {
                guard bytes.count >= 4 else { return }
                length = Int(bytes[2]) << 8 | Int(bytes[3])
                offset = 4
            } else if length == 127 {
                return close(session)  // 64-bit lengths: far bigger than anything we accept
            }
            guard masked, length <= Self.maxFrame else { return close(session) }  // clients must mask
            let total = offset + 4 + length
            guard session.buffer.count >= total else { return }

            let frame = [UInt8](session.buffer.prefix(total))
            session.buffer = Data(session.buffer.dropFirst(total))
            let mask = Array(frame[offset..<offset + 4])
            var payload = Array(frame[(offset + 4)...])
            for i in payload.indices { payload[i] ^= mask[i % 4] }

            switch opcode {
            case 0x1: handleMessage(session, payload)                      // text
            case 0x8: sendFrame(session, opcode: 0x8); close(session)      // close
            case 0x9: sendFrame(session, opcode: 0xA, payload: payload)    // ping → pong
            default: break                                                 // pong, binary, continuation
            }
        }
    }

    private func sendFrame(_ session: Session, opcode: UInt8, payload: [UInt8] = []) {
        guard payload.count <= Self.maxFrame else { return }  // small control and status frames only
        let header: [UInt8] = payload.count < 126
            ? [0x80 | opcode, UInt8(payload.count)]
            : [0x80 | opcode, 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        session.connection.send(content: Data(header + payload), completion: .idempotent)
    }

    /// Tell every phone how the TV link is doing.
    func sendTVState(_ state: TVController.State) { sendTVState(state, to: nil) }

    private func sendTVState(_ state: TVController.State, to session: Session?) {
        let status: String
        switch state {
        case .off: status = "off"
        case .connecting: status = "connecting"
        case .pairing: status = "pairing"
        case .connected: status = "connected"
        case .failed: status = "error"
        }
        let message: [String: Any] = ["t": "tv", "s": status, "m": state.label]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        queue.async {
            let targets = session.map { [$0] } ?? self.sessions.values.filter(\.isWebSocket)
            for target in targets where !target.closed { self.sendFrame(target, opcode: 0x1, payload: [UInt8](data)) }
        }
    }

    private func handleMessage(_ session: Session, _ payload: [UInt8]) {
        guard let msg = (try? JSONSerialization.jsonObject(with: Data(payload))) as? [String: Any] else { return }
        func number(_ key: String) -> Double {
            let v = (msg[key] as? NSNumber)?.doubleValue ?? 0
            return v.isFinite ? min(max(v, -Self.maxDelta), Self.maxDelta) : 0
        }
        if msg["to"] as? String == "tv" {
            switch msg["t"] as? String {
            case "m": tv.move(dx: number("dx"), dy: number("dy"))
            case "c": if msg["b"] as? String == "r" { tv.button("BACK") } else { tv.click() }
            case "s": tv.scroll(dx: number("dx"), dy: number("dy"))
            case "b": if let key = msg["k"] as? String { tv.button(key) }
            case "h":
                tv.wake()
                sendTVState(tv.state, to: session)
            default: break
            }
            return
        }
        switch msg["t"] as? String {
        case "m": input.move(dx: number("dx"), dy: number("dy"))
        case "c": input.click(right: msg["b"] as? String == "r", count: (msg["n"] as? Int) == 2 ? 2 : 1)
        case "d": input.hold((msg["s"] as? Int) == 1)
        case "s": input.scroll(dx: Int32(number("dx")), dy: Int32(number("dy")))
        case "g": if let d = msg["d"] as? String { input.swipe(d) }
        default: break
        }
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

enum ServerError: LocalizedError {
    case identity
    var errorDescription: String? { "Could not use the TLS certificate." }
}
