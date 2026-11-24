import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Network

/// Listens for iPhones (advertised over Bonjour), pairs them with a one-time code,
/// and turns "next"/"prev" into Right/Left arrow key presses for the frontmost app.
/// Everything runs on the main queue (traffic is a few lines per minute).
final class ClickerServer: ObservableObject {
    struct PairedDevice: Codable, Identifiable {
        let id: String      // deviceID chosen by the iPhone
        var name: String
        let secret: String  // hex
        var lastSeen: Date?
    }

    struct LiveSession: Identifiable {
        let id: Int
        var name: String
        var authenticated: Bool
    }

    enum ListenerState: Equatable {
        case starting, ready, failed(String)
    }

    @Published private(set) var listenerState: ListenerState = .starting
    @Published private(set) var pairingCode = ClickerProtocol.randomCode() {
        didSet { debugLog("pairing code \(pairingCode)") }
    }
    @Published private(set) var pairedDevices: [PairedDevice] = []
    @Published private(set) var sessions: [LiveSession] = []
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var lastEvent: String?
    @Published private(set) var commandCount = 0

    let serviceName: String
    let macID: String

    private var listener: NWListener?
    private var connections: [Int: Connection] = [:]
    private var nextID = 1
    private var failedPairings = 0
    private var axTimer: Timer?
    private let defaults = UserDefaults.standard

    init() {
        if let id = defaults.string(forKey: "macID") {
            macID = id
        } else {
            macID = UUID().uuidString
            defaults.set(macID, forKey: "macID")
        }
        if let data = defaults.data(forKey: "pairedDevices"),
           let list = try? JSONDecoder().decode([PairedDevice].self, from: data) {
            pairedDevices = list
        }
        // localizedName may contain invisible bidi marks (e.g. "‏⁨MacBook Air⁩ של ⁨עידו⁩").
        let raw = Host.current().localizedName ?? "Mac"
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.properties.generalCategory != .format }))
            .trimmingCharacters(in: .whitespaces)
        serviceName = cleaned.isEmpty ? "Mac" : cleaned

        axTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            let granted = AXIsProcessTrusted()
            if self?.accessibilityGranted != granted { self?.accessibilityGranted = granted }
        }
        debugLog("pairing code \(pairingCode)")
        startListener()
    }

    // MARK: Public actions

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        accessibilityGranted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if !accessibilityGranted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func newPairingCode() {
        pairingCode = ClickerProtocol.randomCode()
        failedPairings = 0
    }

    func forget(_ device: PairedDevice) {
        pairedDevices.removeAll { $0.id == device.id }
        savePaired()
        for conn in connections.values where conn.deviceID == device.id { conn.close() }
    }

    func restart() {
        listener?.cancel()
        listener = nil
        startListener()
    }

    // MARK: Listener

    private func startListener() {
        listenerState = .starting
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true

        let listener: NWListener
        do {
            // Prefer the fixed port (handy for `nc` tests); fall back to any free port.
            if let port = NWEndpoint.Port(rawValue: ClickerProtocol.defaultPort),
               let fixed = try? NWListener(using: params, on: port) {
                listener = fixed
            } else {
                listener = try NWListener(using: params)
            }
        } catch {
            listenerState = .failed("\(error)")
            return
        }
        let txt = NWTXTRecord(["id": macID, "v": "\(ClickerProtocol.version)"])
        listener.service = NWListener.Service(name: serviceName, type: ClickerProtocol.serviceType, txtRecord: txt)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, listener === self.listener else { return }
            switch state {
            case .ready:
                self.listenerState = .ready
            case let .failed(error):
                self.listenerState = .failed("\(error)")
                // Port taken or network change: retry on any port shortly.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.restart() }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] nw in self?.accept(nw) }
        self.listener = listener
        listener.start(queue: .main)
    }

    private func accept(_ nw: NWConnection) {
        let id = nextID
        nextID += 1
        let conn = Connection(id: id, connection: nw, server: self)
        connections[id] = conn
        conn.start()
    }

    // MARK: Called by connections

    fileprivate func sessionChanged(_ conn: Connection) {
        var list = connections.values.filter { $0.isOpen }.map {
            LiveSession(id: $0.id, name: $0.displayName, authenticated: $0.deviceID != nil)
        }
        list.sort { $0.id < $1.id }
        sessions = list
    }

    fileprivate func connectionClosed(_ conn: Connection) {
        connections[conn.id] = nil
        sessionChanged(conn)
    }

    fileprivate func verify(deviceID: String, proof: String, nonce: String, name: String) -> Bool {
        guard let index = pairedDevices.firstIndex(where: { $0.id == deviceID }),
              let expected = ClickerProtocol.authProof(secretHex: pairedDevices[index].secret, nonceHex: nonce, deviceID: deviceID),
              ClickerProtocol.safeEquals(expected, proof) else { return false }
        pairedDevices[index].name = name
        pairedDevices[index].lastSeen = Date()
        savePaired()
        return true
    }

    /// Returns the new shared secret if the code matches.
    fileprivate func pair(code: String, deviceID: String, name: String) -> String? {
        guard ClickerProtocol.safeEquals(code, pairingCode) else {
            failedPairings += 1
            if failedPairings >= 10 { newPairingCode() } // limit guessing
            return nil
        }
        let secret = ClickerProtocol.randomHex(bytes: 32)
        pairedDevices.removeAll { $0.id == deviceID }
        pairedDevices.append(PairedDevice(id: deviceID, name: name, secret: secret, lastSeen: Date()))
        savePaired()
        newPairingCode() // one-time code
        record("📱 \(name) הוצמד")
        return secret
    }

    fileprivate func perform(_ command: String, from name: String) {
        switch command {
        case "next":
            pressKey(124)
            commandCount += 1
            record("➡️ הבא · \(name)")
        case "prev":
            pressKey(123)
            commandCount += 1
            record("⬅️ הקודם · \(name)")
        default:
            break
        }
    }

    fileprivate func record(_ text: String) {
        lastEvent = text
        debugLog(text)
    }

    private func debugLog(_ text: String) {
        #if DEBUG
        NSLog("[clicker] %@", text)
        #endif
    }

    private func savePaired() {
        if let data = try? JSONEncoder().encode(pairedDevices) {
            defaults.set(data, forKey: "pairedDevices")
        }
    }

    private func pressKey(_ keyCode: CGKeyCode) {
        if !AXIsProcessTrusted() {
            accessibilityGranted = false
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

// MARK: - One TCP connection

private final class Connection {
    let id: Int
    let connection: NWConnection
    unowned let server: ClickerServer

    private(set) var isOpen = false
    private(set) var deviceID: String?
    private var name: String
    private var buffer = Data()
    private let nonce = ClickerProtocol.randomHex(bytes: 16)
    private var pairAttempts = 0
    private var closed = false

    var displayName: String { name }

    init(id: Int, connection: NWConnection, server: ClickerServer) {
        self.id = id
        self.connection = connection
        self.server = server
        if case let .hostPort(host, _) = connection.endpoint {
            var text = "\(host)"
            if let pct = text.firstIndex(of: "%") { text = String(text[..<pct]) }
            name = text
        } else {
            name = "iPhone"
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isOpen = true
                self.send("server \(self.server.macID) \(ClickerProtocol.version)")
                self.send("challenge \(self.nonce)")
                self.server.sessionChanged(self)
            case .failed, .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true
        isOpen = false
        connection.cancel()
        server.connectionClosed(self)
    }

    private func send(_ line: String) {
        connection.send(content: Data((line + "\n").utf8), completion: .idempotent)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.processLines()
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            if !self.closed { self.receive() }
        }
    }

    private func processLines() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line)
        }
        if buffer.count > 8192 { close() } // garbage guard
    }

    private func handle(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
        guard let command = parts.first?.lowercased() else { return }

        switch command {
        case "ping":
            return
        case "auth" where parts.count >= 3:
            let devName = parts.count > 3 ? parts[3] : "iPhone"
            if server.verify(deviceID: parts[1], proof: parts[2].lowercased(), nonce: nonce, name: devName) {
                deviceID = parts[1]
                name = devName
                send("ok")
                server.record("📱 \(devName) התחבר")
                server.sessionChanged(self)
            } else {
                send("auth-failed")
            }
        case "pair" where parts.count >= 3:
            pairAttempts += 1
            let devName = parts.count > 3 ? parts[3] : "iPhone"
            if let secret = server.pair(code: parts[1], deviceID: parts[2], name: devName) {
                deviceID = parts[2]
                name = devName
                send("paired \(secret)")
                server.sessionChanged(self)
            } else {
                send("pair-failed")
                if pairAttempts >= 5 { close() }
            }
        case "next", "prev":
            guard deviceID != nil else { return send("need-pair") }
            server.perform(command, from: name)
        default:
            return
        }
    }
}
