import Foundation
import Network

/// Netze, aus denen der Stream abgerufen werden darf. Eine Zeile pro Eintrag:
/// `192.168.x.x`, `10.*.*.*`, `192.168.178.0/24`, `192.168.178.30`, `fd00::/8` …
/// Text nach `#` ist Kommentar. Der Mac selbst (Loopback) hat immer Zugriff.
struct NetworkAccessList {
    static let defaultText = "192.168.x.x\n10.x.x.x"

    struct Subnet {
        /// 4 Bytes (IPv4) oder 16 Bytes (IPv6)
        let bytes: [UInt8]
        let prefix: Int
        let text: String

        func contains(_ address: [UInt8]) -> Bool {
            guard address.count == bytes.count else { return false }
            var remaining = prefix
            var index = 0
            while remaining > 0 && index < bytes.count {
                let bits = min(8, remaining)
                let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
                if address[index] & mask != bytes[index] & mask { return false }
                remaining -= bits
                index += 1
            }
            return true
        }
    }

    let subnets: [Subnet]
    /// Zeilen, die nicht als Netz erkannt wurden
    let invalidLines: [String]

    var summary: String { subnets.map(\.text).joined(separator: ", ") }

    init(text: String) {
        var subnets: [Subnet] = []
        var invalid: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let withoutComment = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let line = String(withoutComment).trimmingCharacters(in: .whitespaces)
            guard line.isEmpty == false else { continue }
            if let subnet = Self.parse(line) {
                subnets.append(subnet)
            } else {
                invalid.append(line)
            }
        }
        self.subnets = subnets
        self.invalidLines = invalid
    }

    // MARK: Prüfen

    func allows(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return allows(bytes: [UInt8](address.rawValue))
        case .ipv6(let address):
            return allows(bytes: [UInt8](address.rawValue))
        default:
            return false
        }
    }

    func allows(address text: String) -> Bool {
        guard let bytes = Self.addressBytes(text) else { return false }
        return allows(bytes: bytes)
    }

    private func allows(bytes raw: [UInt8]) -> Bool {
        let bytes = Self.mappedIPv4(raw) ?? raw
        if Self.isLoopback(bytes) { return true }
        return subnets.contains { $0.contains(bytes) }
    }

    // MARK: Einlesen

    static func parse(_ line: String) -> Subnet? {
        let parts = line.split(separator: "/", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let addressText = parts.first, addressText.isEmpty == false else { return nil }

        // Schreibweise mit Platzhaltern: 192.168.x.x oder 10.*.*.*
        let lowered = addressText.lowercased()
        if parts.count == 1, lowered.contains("x") || lowered.contains("*") {
            let octets = lowered.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4 else { return nil }
            var bytes: [UInt8] = []
            var wildcard = false
            var fixed = 0
            for octet in octets {
                if octet == "x" || octet == "*" {
                    wildcard = true
                    bytes.append(0)
                } else {
                    guard wildcard == false, let value = UInt8(octet) else { return nil }
                    bytes.append(value)
                    fixed += 1
                }
            }
            return Subnet(bytes: bytes, prefix: fixed * 8, text: line)
        }

        guard let bytes = addressBytes(addressText) else { return nil }
        let maxPrefix = bytes.count * 8
        var prefix = maxPrefix
        if parts.count == 2 {
            guard let value = Int(parts[1]), (0...maxPrefix).contains(value) else { return nil }
            prefix = value
        }
        return Subnet(bytes: bytes, prefix: prefix, text: line)
    }

    static func addressBytes(_ text: String) -> [UInt8]? {
        if let address = IPv4Address(text) { return [UInt8](address.rawValue) }
        if let address = IPv6Address(text) {
            let bytes = [UInt8](address.rawValue)
            return mappedIPv4(bytes) ?? bytes
        }
        return nil
    }

    /// ::ffff:a.b.c.d → a.b.c.d
    private static func mappedIPv4(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count == 16,
              bytes[0..<10].allSatisfy({ $0 == 0 }),
              bytes[10] == 0xFF, bytes[11] == 0xFF else { return nil }
        return Array(bytes[12..<16])
    }

    private static func isLoopback(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 4 { return bytes[0] == 127 }
        return bytes.count == 16 && bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1
    }
}
