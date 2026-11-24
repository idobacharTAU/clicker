import Foundation
import Network
import Security
import UIKit

/// Finds Macs running "קליקר" via Bonjour, pairs with one using the code shown on the Mac,
/// keeps a TCP connection open, reconnects automatically, and sends "next" / "prev".
final class ClickerClient: ObservableObject {
    struct MacInfo: Identifiable, Equatable {
        let id: String      // macID from the TXT record (falls back to the service name)
        let name: String
        let isPaired: Bool
    }

    enum Status: Equatable {
        case searching
        case chooseMac                 // Macs found, none paired yet
        case connecting(String)
        case needsCode(String)         // connected, waiting for the user to type the Mac's code
        case connected(String)
        case noPermission
    }

    @Published private(set) var status: Status = .searching
    @Published private(set) var macs: [MacInfo] = []
    @Published private(set) var pairingError: String?

    private let queue = DispatchQueue(label: "slideclicker.client")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var results: [NWBrowser.Result] = []
    private var buffer = Data()
    private var reconnectWork: DispatchWorkItem?
    private var started = false

    /// The Mac we are (or want to be) talking to, by macID.
    private var targetID: String?
    private var targetName = "Mac"
    private var serverMacID: String?
    private var nonce: String?
    private var authenticated = false

    private let deviceID: String = {
        let key = "deviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    private var deviceName: String {
        // Since iOS 16 this is the model name ("iPhone") unless the user-assigned-name entitlement is granted.
        UIDevice.current.name.replacingOccurrences(of: "\n", with: " ")
    }

    init() {
        targetID = UserDefaults.standard.string(forKey: "lastMacID")
    }

    // MARK: Public

    func start() {
        queue.async {
            guard !self.started else { return }
            self.started = true
            self.startBrowser()
        }
    }

    /// Called when the app returns to the foreground: make sure everything is alive.
    func refresh() {
        queue.async {
            guard self.started else { return self.start() }
            if self.browser == nil || self.browserIsDead { self.restartBrowser() }
            if self.connection?.state != .ready { self.scheduleReconnect(after: 0) }
        }
    }

    /// User picked a Mac from the list.
    func choose(_ mac: MacInfo) {
        queue.async {
            self.targetID = mac.id
            self.targetName = mac.name
            self.dropConnection(rebrowse: false)
            self.scheduleReconnect(after: 0)
        }
    }

    /// Back to the list of Macs (e.g. from the code screen).
    func showMacList() {
        queue.async {
            self.targetID = nil
            UserDefaults.standard.removeObject(forKey: "lastMacID")
            self.dropConnection(rebrowse: false)
            self.publishResults()
            self.publish(self.results.isEmpty ? .searching : .chooseMac)
        }
    }

    func submitCode(_ code: String) {
        let digits = code.filter(\.isNumber)
        queue.async {
            guard let conn = self.connection, conn.state == .ready else { return }
            self.publishError(nil)
            self.sendRaw("pair \(digits) \(self.deviceID) \(self.deviceName)", on: conn)
        }
    }

    /// Forget the pairing with the current Mac.
    func unpairCurrent() {
        queue.async {
            if let id = self.serverMacID ?? self.targetID { Keychain.delete(id) }
            self.showMacList()
        }
    }

    /// Returns false if there is no live connection (the command was not sent). Call on the main thread.
    @discardableResult
    func send(_ command: String) -> Bool {
        guard case .connected = status else {
            refresh()
            return false
        }
        queue.async {
            guard let connection = self.connection, connection.state == .ready, self.authenticated else {
                self.scheduleReconnect(after: 0)
                return
            }
            connection.send(content: Data((command + "\n").utf8), completion: .contentProcessed { error in
                if error != nil { self.dropConnection() } // completion runs on `queue`
            })
        }
        return true
    }

    // MARK: Browser

    private var browserIsDead: Bool {
        guard let browser else { return true }
        switch browser.state {
        case .failed, .cancelled: return true
        default: return false
        }
    }

    private func startBrowser() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: ClickerProtocol.serviceType, domain: nil), using: params)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case let .waiting(error), let .failed(error):
                if case let .dns(code) = error, code == -65570 /* kDNSServiceErr_PolicyDenied */ {
                    self.publish(.noPermission)
                }
                if case .failed = state {
                    self.queue.asyncAfter(deadline: .now() + 2) { self.restartBrowser() }
                }
            case .ready:
                if self.status == .noPermission { self.publish(.searching) }
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] newResults, _ in
            guard let self else { return }
            self.results = Array(newResults)
            self.publishResults()
            if self.connection == nil { self.connectToTarget() }
        }

        browser.start(queue: queue)
    }

    private func restartBrowser() {
        browser?.cancel()
        browser = nil
        results = []
        startBrowser()
    }

    private func info(for result: NWBrowser.Result) -> MacInfo {
        var name = "Mac"
        if case let .service(n, _, _, _) = result.endpoint { name = n }
        var id = name
        if case let .bonjour(txt) = result.metadata, let macID = txt["id"], !macID.isEmpty { id = macID }
        return MacInfo(id: id, name: name, isPaired: Keychain.read(id) != nil)
    }

    private func publishResults() {
        var seen = Set<String>()
        let list = results.map(info(for:)).filter { seen.insert($0.id).inserted }.sorted { $0.name < $1.name }
        DispatchQueue.main.async { if self.macs != list { self.macs = list } }
    }

    // MARK: Connection

    /// Connects to the chosen Mac; if none is chosen, auto-picks a paired one, otherwise asks the user.
    private func connectToTarget() {
        guard connection == nil else { return }
        let infos = results.map { ($0, info(for: $0)) }
        guard !infos.isEmpty else {
            if status != .noPermission { publish(.searching) }
            return
        }
        let chosen = infos.first { $0.1.id == targetID }
            ?? (targetID == nil ? infos.first { $0.1.isPaired } : nil)
        guard let (result, mac) = chosen else {
            if case .connecting = status, targetID != nil { return } // chosen Mac briefly gone; keep waiting
            publish(.chooseMac)
            return
        }
        targetID = mac.id
        targetName = mac.name
        connect(to: result.endpoint)
    }

    private func connect(to endpoint: NWEndpoint) {
        publish(.connecting(targetName))
        buffer.removeAll()
        nonce = nil
        serverMacID = nil
        authenticated = false

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.noDelay = true
        tcp.connectionTimeout = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true

        let conn = NWConnection(to: endpoint, using: params)
        connection = conn

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn, conn === self.connection else { return }
            switch state {
            case .ready:
                self.receiveLoop(conn)
            case .waiting, .failed:
                self.dropConnection()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func sendRaw(_ line: String, on conn: NWConnection) {
        conn.send(content: Data((line + "\n").utf8), completion: .idempotent)
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak conn] data, _, isComplete, error in
            guard let self, let conn, conn === self.connection else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                while let newline = self.buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: self.buffer[self.buffer.startIndex..<newline], as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    self.buffer.removeSubrange(self.buffer.startIndex...newline)
                    self.handle(line, on: conn)
                }
            }
            if isComplete || error != nil {
                self.dropConnection()
            } else {
                self.receiveLoop(conn)
            }
        }
    }

    private func handle(_ line: String, on conn: NWConnection) {
        let parts = line.split(separator: " ").map(String.init)
        guard let command = parts.first else { return }
        switch command {
        case "server" where parts.count >= 2:
            serverMacID = parts[1]
        case "challenge" where parts.count >= 2:
            nonce = parts[1]
            authenticateOrAskForCode(on: conn)
        case "ok":
            markConnected()
        case "paired" where parts.count >= 2:
            if let id = serverMacID { Keychain.save(parts[1], for: id) }
            publishResults()
            markConnected()
        case "auth-failed":
            // The Mac forgot us (or was reset): pair again.
            if let id = serverMacID { Keychain.delete(id) }
            publishResults()
            publish(.needsCode(targetName))
        case "pair-failed":
            publishError("הקוד שגוי. בדקו את הקוד שמופיע במק ונסו שוב.")
        case "need-pair":
            authenticated = false
            publish(.needsCode(targetName))
        default:
            break
        }
    }

    private func authenticateOrAskForCode(on conn: NWConnection) {
        guard let nonce else { return }
        let macID = serverMacID ?? targetID ?? ""
        if let secret = Keychain.read(macID),
           let proof = ClickerProtocol.authProof(secretHex: secret, nonceHex: nonce, deviceID: deviceID) {
            sendRaw("auth \(deviceID) \(proof) \(deviceName)", on: conn)
        } else {
            publish(.needsCode(targetName))
        }
    }

    private func markConnected() {
        authenticated = true
        if let id = serverMacID ?? targetID { UserDefaults.standard.set(id, forKey: "lastMacID") }
        publishError(nil)
        publish(.connected(targetName))
    }

    private func dropConnection(rebrowse: Bool = true) {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        authenticated = false
        guard rebrowse else { return }
        publish(.connecting(targetName))
        // The old endpoint may belong to an interface that just went away. Re-browse so we
        // reconnect over whatever path is up now.
        restartBrowser()
        scheduleReconnect(after: 1)
    }

    private func scheduleReconnect(after seconds: Double) {
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let conn = self.connection, conn.state != .ready {
                conn.stateUpdateHandler = nil
                conn.cancel()
                self.connection = nil
            }
            if self.browserIsDead { self.restartBrowser() }
            self.connectToTarget()
        }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func publish(_ newStatus: Status) {
        DispatchQueue.main.async {
            if self.status != newStatus { self.status = newStatus }
        }
    }

    private func publishError(_ text: String?) {
        DispatchQueue.main.async { self.pairingError = text }
    }
}

/// Pairing secrets, one per Mac, in the Keychain (this device only, available after first unlock).
enum Keychain {
    private static let service = "com.idobachar.slideclicker.pairing"

    static func save(_ value: String, for account: String) {
        delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
