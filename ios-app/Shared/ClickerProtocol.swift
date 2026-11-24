import CryptoKit
import Foundation

/// Wire protocol shared by the iPhone and Mac apps (newline-terminated UTF-8 lines over TCP).
///
///   Mac → iPhone (on connect):  "server <macID> 2"
///                               "challenge <nonceHex>"
///   iPhone → Mac:  "auth <deviceID> <hmacHex> <device name…>"   (already paired)
///                  "pair <code> <deviceID> <device name…>"       (first time, code shown on the Mac)
///   Mac → iPhone:  "ok" | "paired <secretHex>" | "auth-failed" | "pair-failed" | "need-pair"
///   After "ok"/"paired":  iPhone → Mac  "next" | "prev" | "ping"
///
/// The shared secret never travels after pairing: each session proves it with
/// HMAC-SHA256(secret, "slideclicker-auth:" + nonce + ":" + deviceID).
enum ClickerProtocol {
    static let serviceType = "_slideclicker._tcp"
    static let defaultPort: UInt16 = 52345
    static let version = 2
    static let codeLength = 6

    static func authProof(secretHex: String, nonceHex: String, deviceID: String) -> String? {
        guard let secret = Data(hex: secretHex) else { return nil }
        let message = Data("slideclicker-auth:\(nonceHex):\(deviceID)".utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret))
        return Data(mac).hexString
    }

    static func randomHex(bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).hexString
    }

    static func randomCode() -> String {
        String((0..<codeLength).map { _ in "0123456789".randomElement()! })
    }

    /// Constant-time comparison for hex strings.
    static func safeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
