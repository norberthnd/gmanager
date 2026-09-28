import Foundation
import GhostKit
#if canImport(Security)
import Security
#endif

/// A connected Ghost site. The Admin API key is not stored here but in a
/// `CredentialStore` (the Keychain on macOS), keyed by `id`.
public struct Site: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Site root as normalised by `SiteEndpoint`.
    public var url: String
    public var ghostVersion: String?
    public var iconURL: String?
    public var addedAt: Date

    public init(id: UUID = UUID(), name: String, url: String, ghostVersion: String? = nil, iconURL: String? = nil, addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.url = url
        self.ghostVersion = ghostVersion
        self.iconURL = iconURL
        self.addedAt = addedAt
    }
}

/// The list of connected sites, persisted as JSON in the app's support directory.
public final class SiteCatalog: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private var fileURL: URL { directory.appendingPathComponent("sites.json") }

    public init(directory: URL) {
        self.directory = directory
    }

    public func sites() throws -> [Site] {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Site].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ site: Site) throws {
        var all = try sites()
        if let index = all.firstIndex(where: { $0.id == site.id }) { all[index] = site } else { all.append(site) }
        try write(all)
    }

    /// Removes the site, its key and its local store.
    public func remove(_ site: Site, credentials: CredentialStore) throws {
        try write(try sites().filter { $0.id != site.id })
        try credentials.deleteKey(for: site.id)
        let base = directory.appendingPathComponent("site-\(site.id.uuidString).sqlite").path
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: base + suffix) {
            try FileManager.default.removeItem(atPath: base + suffix)
        }
    }

    private func write(_ sites: [Site]) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sites).write(to: fileURL, options: .atomic)
    }
}

// MARK: - Connecting

public struct SiteConnection: Sendable {
    public var site: Site
    public var key: AdminAPIKey
}

public enum ConnectError: Error, Equatable {
    case invalidURL
    case invalidKey
    /// The server rejected the key.
    case unauthorized
    case notGhost
    case unsupportedVersion(String)
    case network(String)
}

/// Validates a URL + Admin API key pair before a site is saved.
public enum SiteConnector {
    public static let minimumMajorVersion = 6

    public static func connect(url: String, key rawKey: String, transport: HTTPTransport = URLSessionTransport()) async throws -> SiteConnection {
        guard let endpoint = try? SiteEndpoint(url) else { throw ConnectError.invalidURL }
        guard let key = try? AdminAPIKey(rawKey) else { throw ConnectError.invalidKey }
        let client = GhostClient(endpoint: endpoint, key: key, transport: transport, retryPolicy: RetryPolicy(maxAttempts: 2))
        let info: SiteInfo
        do {
            info = try await client.site()
        } catch GhostError.transport(let message) {
            throw ConnectError.network(message)
        } catch {
            throw ConnectError.notGhost
        }
        if let version = info.version, let major = Int(version.split(separator: ".").first ?? ""), major < minimumMajorVersion {
            throw ConnectError.unsupportedVersion(version)
        }
        do {
            try await client.verifyAccess()
        } catch GhostError.unauthorized {
            throw ConnectError.unauthorized
        } catch GhostError.transport(let message) {
            throw ConnectError.network(message)
        }
        let site = Site(name: info.title, url: endpoint.rootURL.absoluteString, ghostVersion: info.version, iconURL: info.icon)
        return SiteConnection(site: site, key: key)
    }
}

// MARK: - Credentials

public protocol CredentialStore: Sendable {
    func key(for site: UUID) throws -> String?
    func setKey(_ key: String, for site: UUID) throws
    func deleteKey(for site: UUID) throws
}

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var keys: [UUID: String] = [:]
    private let lock = NSLock()
    public init() {}
    public func key(for site: UUID) throws -> String? { lock.withLock { keys[site] } }
    public func setKey(_ key: String, for site: UUID) throws { lock.withLock { keys[site] = key } }
    public func deleteKey(for site: UUID) throws { lock.withLock { _ = keys.removeValue(forKey: site) } }
}

#if canImport(Security)
/// Stores Admin API keys as generic passwords in the login Keychain,
/// readable only when the Mac is unlocked and never synced to iCloud.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public enum KeychainError: Error, Equatable {
        case status(OSStatus)
    }

    private func query(_ site: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: site.uuidString,
        ]
    }

    public func key(for site: UUID) throws -> String? {
        var query = query(site)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError.status(status) }
        return String(data: data, encoding: .utf8)
    }

    public func setKey(_ key: String, for site: UUID) throws {
        let data = Data(key.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query(site) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(site)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    public func deleteKey(for site: UUID) throws {
        let status = SecItemDelete(query(site) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}
#endif
