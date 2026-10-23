import Foundation

/// Drives the on-screen pointer of an LG webOS TV (the Magic Remote cursor), over SSAP:
/// the TV's local WebSocket API that LG's own phone app uses.
///
///   1. wss://TV:3001 — register. The first time, the TV shows a prompt to allow AirMouse;
///      it then returns a client key, which we keep so later connections need no prompt.
///   2. ssap://com.webos.service.networkinput/getPointerInputSocket returns a second socket.
///   3. That socket takes plain-text commands, e.g. "type:move\ndx:4\ndy:-2\ndown:0\n\n".
///      The cursor appears over whatever app is open as soon as it moves.
///
/// Connects on demand (when a phone opens the TV tab or sends TV input), so nothing talks
/// to the TV while it isn't being used.
final class TVController: NSObject, URLSessionDelegate {
    enum State: Equatable {
        case off, connecting, pairing, connected
        case failed(String)

        /// Short status for the phone page and the menu.
        var label: String {
            switch self {
            case .off: return "TV not connected"
            case .connecting: return "Connecting to TV…"
            case .pairing: return "Accept AirMouse on the TV"
            case .connected: return "TV connected"
            case .failed(let reason): return reason
            }
        }
    }

    var onStateChanged: ((State) -> Void)?  // called on the main queue

    private let queue = DispatchQueue(label: "AirMouse.tv")
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self,
                                          delegateQueue: OperationQueue.withUnderlying(queue))
    private var host: String
    private var control: URLSessionWebSocketTask?   // SSAP requests
    private var pointer: URLSessionWebSocketTask?   // pointer input socket
    private var heartbeat: DispatchSourceTimer?
    private var lastAttempt = Date.distantPast
    private var scrollX = 0.0, scrollY = 0.0        // scroll not yet sent (TV scrolls in steps)
    private(set) var state: State = .off

    private static let retryInterval = 3.0          // seconds between connection attempts
    private static let scrollStep = 30.0            // phone scroll px per TV scroll step

    init(host: String) {
        self.host = host
        super.init()
    }

    // MARK: Public API (any thread)

    /// Connect now if not connected (a phone opened the TV tab).
    func wake() { queue.async { self.ensureConnected() } }

    func move(dx: Double, dy: Double) {
        send("type:move\ndx:\(Int(dx))\ndy:\(Int(dy))\ndown:0\n\n")
    }

    func click() { send("type:click\n\n") }

    /// Phone scroll deltas (natural scrolling: fingers up = negative dy) in TV scroll steps.
    func scroll(dx: Double, dy: Double) {
        queue.async {
            self.scrollX += dx
            self.scrollY += dy
            let sx = Int(self.scrollX / Self.scrollStep), sy = Int(self.scrollY / Self.scrollStep)
            guard sx != 0 || sy != 0 else { return }
            self.scrollX -= Double(sx) * Self.scrollStep
            self.scrollY -= Double(sy) * Self.scrollStep
            self.sendNow("type:scroll\ndx:\(-sx)\ndy:\(-sy)\n\n")
        }
    }

    /// Remote control key: BACK, HOME, VOLUMEUP, CHANNELDOWN, digits 0–9, …
    func button(_ name: String) {
        guard Self.buttons.contains(name) else { return }
        send("type:button\nname:\(name)\n\n")
    }

    private static let buttons: Set = ["BACK", "HOME", "ENTER", "EXIT", "MENU", "INFO",
                                       "UP", "DOWN", "LEFT", "RIGHT", "VOLUMEUP", "VOLUMEDOWN", "MUTE",
                                       "CHANNELUP", "CHANNELDOWN", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]

    /// Power key: off while connected; otherwise wake the TV over the network (Wake-on-LAN),
    /// since a TV in standby doesn't answer SSAP.
    func power() {
        queue.async {
            if self.state == .connected { return self.sendNow("type:button\nname:POWER\n\n") }
            guard let mac = Preferences.tvMAC(host: self.host) else {
                return self.setState(.failed("Connect once while the TV is on, then it can be woken"))
            }
            WakeOnLAN.send(mac: mac)
            self.lastAttempt = .distantPast  // let the next input reconnect right away
        }
    }

    /// New TV address: drop the current connection; the next input reconnects.
    func setHost(_ newHost: String) {
        queue.async {
            self.host = newHost
            self.disconnect(.off)
        }
    }

    // MARK: Connection

    private func send(_ command: String) {
        queue.async { self.sendNow(command) }
    }

    private func sendNow(_ command: String) {
        guard state == .connected, let pointer else { return ensureConnected() }
        pointer.send(.string(command)) { [weak self] error in
            guard error != nil, let self else { return }
            self.queue.async { if self.pointer === pointer { self.disconnect(.failed("TV connection lost")) } }
        }
    }

    private func ensureConnected() {
        switch state {
        case .connecting, .pairing, .connected: return
        case .off, .failed: break
        }
        guard Date().timeIntervalSince(lastAttempt) >= Self.retryInterval,
              let url = URL(string: "wss://\(host):3001") else { return }
        lastAttempt = Date()
        setState(.connecting)

        let task = session.webSocketTask(with: url)
        control = task
        task.resume()
        receive(task)
        var payload: [String: Any] = ["forcePairing": false, "pairingType": "PROMPT", "manifest": Self.manifest]
        if let key = Preferences.tvClientKey(host: host) { payload["client-key"] = key }
        request(type: "register", id: "register", payload: payload)
    }

    private func request(type: String = "request", id: String, uri: String? = nil, payload: [String: Any]? = nil) {
        var message: [String: Any] = ["type": type, "id": id]
        if let uri { message["uri"] = uri }
        if let payload { message["payload"] = payload }
        guard let control, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        control.send(.string(String(decoding: data, as: UTF8.self))) { _ in }  // failures surface in receive
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.control === task else { return }  // stale connection
                switch result {
                case .success(.string(let text)):
                    self.handle(text)
                    self.receive(task)
                case .success:
                    self.receive(task)
                case .failure:
                    let reason = self.state == .connecting ? "TV unreachable (is it on?)" : "TV connection lost"
                    self.disconnect(.failed(reason))
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let message = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        let payload = message["payload"] as? [String: Any] ?? [:]
        switch (message["type"] as? String, message["id"] as? String) {
        case ("response", "register"):
            if payload["pairingType"] as? String == "PROMPT" { setState(.pairing) }
        case ("registered", "register"):
            if let key = payload["client-key"] as? String { Preferences.setTVClientKey(key, host: host) }
            request(id: "pointer", uri: "ssap://com.webos.service.networkinput/getPointerInputSocket")
        case ("error", "register"):
            // Declined on the TV, or the saved key was revoked: forget it so the next try prompts again.
            Preferences.setTVClientKey(nil, host: host)
            disconnect(.failed("TV declined pairing"))
        case ("response", "pointer"):
            guard let path = payload["socketPath"] as? String, let url = URL(string: path) else {
                return disconnect(.failed("TV refused pointer input"))
            }
            let task = session.webSocketTask(with: url)
            pointer = task
            task.resume()
            watchPointer(task)
            startHeartbeat()
            setState(.connected)
            rememberMAC()
        case (_, "pointer"):
            disconnect(.failed("TV refused pointer input"))
        default:
            break
        }
    }

    /// The pointer socket never sends anything; a receive only completes when it closes.
    private func watchPointer(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.pointer === task else { return }
                if case .failure = result { self.disconnect(.failed("TV connection lost")) } else { self.watchPointer(task) }
            }
        }
    }

    /// Ping every 20 s: a TV switched off at the wall otherwise leaves a dead connection behind.
    private func startHeartbeat() {
        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in
            guard let self, let control = self.control else { return }
            control.sendPing { error in
                guard error != nil else { return }
                self.queue.async { if self.control === control { self.disconnect(.failed("TV connection lost")) } }
            }
        }
        timer.resume()
        heartbeat = timer
    }

    private func disconnect(_ newState: State) {
        heartbeat?.cancel()
        heartbeat = nil
        pointer?.cancel(with: .goingAway, reason: nil)
        control?.cancel(with: .goingAway, reason: nil)
        pointer = nil
        control = nil
        scrollX = 0
        scrollY = 0
        setState(newState)
    }

    private func setState(_ newState: State) {
        guard newState != state else { return }
        state = newState
        DispatchQueue.main.async { self.onStateChanged?(newState) }
    }

    /// Note the TV's hardware address while it's on, for Wake-on-LAN later.
    private func rememberMAC() {
        let host = host
        DispatchQueue.global(qos: .utility).async {
            let arp = Process()
            arp.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
            arp.arguments = ["-n", host]
            let pipe = Pipe()
            arp.standardOutput = pipe
            guard (try? arp.run()) != nil else { return }
            arp.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            // "? (192.168.1.51) at 4:b9:e3:1:2:3 on en0 ifscope [ethernet]"
            guard let word = output.split(separator: " ").drop(while: { $0 != "at" }).dropFirst().first,
                  WakeOnLAN.bytes(String(word)) != nil else { return }
            Preferences.setTVMAC(String(word), host: host)
        }
    }

    // MARK: TLS

    /// The TV serves a self-signed certificate. Accept it for the configured TV address only;
    /// any other server keeps the system's default checks.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host == host, let trust = space.serverTrust else {
            return completionHandler(.performDefaultHandling, nil)
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    // MARK: Registration manifest

    /// Permissions AirMouse asks for: pointer, keys and volume only.
    private static let manifest: [String: Any] = [
        "manifestVersion": 1,
        "appVersion": "1.0",
        "permissions": [
            "CONTROL_AUDIO",
            "CONTROL_INPUT_JOYSTICK",
            "CONTROL_INPUT_MEDIA_PLAYBACK",
            "CONTROL_INPUT_TEXT",
            "CONTROL_INPUT_TV",
            "CONTROL_MOUSE_AND_KEYBOARD",
            "READ_INPUT_DEVICE_LIST",
        ],
    ]
}

private extension OperationQueue {
    static func withUnderlying(_ queue: DispatchQueue) -> OperationQueue {
        let operations = OperationQueue()
        operations.underlyingQueue = queue
        operations.maxConcurrentOperationCount = 1
        return operations
    }
}

/// Magic packet that wakes a TV from standby (needs "Turn on via Wi-Fi" / "Mobile TV On" on the TV).
enum WakeOnLAN {
    /// "4:b9:e3:1:2:3" → six bytes.
    static func bytes(_ mac: String) -> [UInt8]? {
        let parts = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        return parts.count == 6 ? parts : nil
    }

    static func send(mac: String) {
        guard let address = bytes(mac) else { return }
        let packet = [UInt8](repeating: 0xFF, count: 6) + Array([[UInt8]](repeating: address, count: 16).joined())
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = in_port_t(9).bigEndian
        target.sin_addr.s_addr = INADDR_BROADCAST
        for _ in 0..<3 {  // UDP may drop one
            _ = withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}
