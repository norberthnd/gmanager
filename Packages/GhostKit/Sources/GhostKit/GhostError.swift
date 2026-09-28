import Foundation

/// One entry of Ghost's `{"errors": [...]}` response body.
public struct GhostAPIError: Decodable, Sendable, Equatable {
    public let message: String
    public let context: String?
    public let type: String?
    public let code: String?
}

public enum GhostError: Error, Sendable, Equatable {
    case invalidAPIKey
    case invalidSiteURL(String)
    /// The server answered with a non-success status.
    case http(status: Int, errors: [GhostAPIError])
    /// The item changed on the server since it was read (`updated_at` mismatch).
    case conflict(errors: [GhostAPIError])
    case notFound(errors: [GhostAPIError])
    case unauthorized(errors: [GhostAPIError])
    case rateLimited(retryAfter: TimeInterval?)
    case invalidResponse
    case decoding(String)
    case transport(String)

    /// Whether retrying the same request later may succeed.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .transport: return true
        case .http(let status, _): return status >= 500
        default: return false
        }
    }
}
