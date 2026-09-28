import Crypto
import Foundation

/// Signs the short-lived HS256 JWTs the Ghost Admin API expects.
///
/// Tokens are valid for five minutes; the signer caches one and reissues it
/// shortly before expiry so every request doesn't pay for a signature.
public final class TokenSigner: @unchecked Sendable {
    public static let lifetime: TimeInterval = 5 * 60
    /// Reissue when less than this much validity remains.
    static let refreshMargin: TimeInterval = 60

    private let key: AdminAPIKey
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cached: (token: String, expiresAt: Date)?

    public init(key: AdminAPIKey, now: @escaping @Sendable () -> Date = Date.init) {
        self.key = key
        self.now = now
    }

    public func token() -> String {
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        if let cached, cached.expiresAt.timeIntervalSince(current) > Self.refreshMargin {
            return cached.token
        }
        let issuedAt = Int(current.timeIntervalSince1970)
        let expiresAt = issuedAt + Int(Self.lifetime)
        let token = Self.sign(key: key, issuedAt: issuedAt, expiresAt: expiresAt)
        cached = (token, Date(timeIntervalSince1970: TimeInterval(expiresAt)))
        return token
    }

    static func sign(key: AdminAPIKey, issuedAt: Int, expiresAt: Int) -> String {
        // Hand-written JSON keeps key order stable, which makes tokens reproducible in tests.
        let header = #"{"alg":"HS256","kid":"\#(key.id)","typ":"JWT"}"#
        let payload = #"{"iat":\#(issuedAt),"exp":\#(expiresAt),"aud":"/admin/"}"#
        let signingInput = base64URL(Data(header.utf8)) + "." + base64URL(Data(payload.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: SymmetricKey(data: key.secret))
        return signingInput + "." + base64URL(Data(mac))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
