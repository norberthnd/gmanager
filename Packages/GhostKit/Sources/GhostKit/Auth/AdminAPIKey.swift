import Foundation

/// A Ghost Admin API key as shown on a custom integration: `<id>:<hex secret>`.
public struct AdminAPIKey: Sendable, Equatable {
    public let id: String
    /// The decoded secret bytes (the hex part of the key).
    public let secret: [UInt8]

    public init(_ raw: String) throws {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw GhostError.invalidAPIKey
        }
        guard let secret = Self.decodeHex(parts[1]) else {
            throw GhostError.invalidAPIKey
        }
        self.id = String(parts[0])
        self.secret = secret
    }

    private static func decodeHex(_ hex: Substring) -> [UInt8]? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
