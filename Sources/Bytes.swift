import Foundation

// Hilfsfunktionen für Binärformate (Big Endian) und einfache Text-Protokolle (HTTP, RTSP)

extension Array where Element == UInt8 {
    mutating func appendU16(_ value: Int) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendU24(_ value: Int) {
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendU32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendU64(_ value: UInt64) {
        appendU32(UInt32(truncatingIfNeeded: value >> 32))
        appendU32(UInt32(truncatingIfNeeded: value))
    }

    mutating func appendASCII(_ text: String) {
        append(contentsOf: Array(text.utf8))
    }
}

func hexString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
}

/// CRC-32 nach MPEG-2 (Polynom 0x04C11DB7, ohne Spiegelung) für PAT/PMT
enum CRC32MPEG {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index) << 24
        for _ in 0..<8 {
            value = (value & 0x8000_0000) != 0 ? (value << 1) ^ 0x04C1_1DB7 : value << 1
        }
        return value
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = (crc << 8) ^ table[Int(((crc >> 24) ^ UInt32(byte)) & 0xFF)]
        }
        return crc
    }
}

/// Position von „\r\n\r\n“ (Ende des Nachrichtenkopfs), falls vorhanden
func findHeaderEnd(_ bytes: [UInt8]) -> Int? {
    guard bytes.count >= 4 else { return nil }
    for index in 0...(bytes.count - 4)
    where bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
        return index
    }
    return nil
}

/// Zerlegt einen HTTP-/RTSP-Kopf in Startzeile und Header (Schlüssel klein geschrieben)
func parseMessageHead(_ bytes: ArraySlice<UInt8>) -> (startLine: String, headers: [String: String])? {
    guard let text = String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) else { return nil }
    var lines = text.components(separatedBy: "\r\n")
    guard lines.isEmpty == false else { return nil }
    let startLine = lines.removeFirst()
    var headers: [String: String] = [:]
    for line in lines {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        headers[key] = value
    }
    return (startLine, headers)
}
