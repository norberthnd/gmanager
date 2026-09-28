import Foundation

/// Where a site's Admin API lives.
///
/// Built from the "API URL" shown on a Ghost custom integration. Users paste it
/// in many shapes (with or without a trailing slash, with `/ghost/`, with the
/// full `/ghost/api/admin/` path, sometimes without a scheme), so it is
/// normalised to the site root and the admin API path is derived from that.
/// Subdirectory installs (`https://example.com/blog`) keep their path.
public struct SiteEndpoint: Sendable, Equatable, Hashable, Codable {
    /// Site root, e.g. `https://example.com/blog`, no trailing slash.
    public let rootURL: URL

    public init(_ raw: String) throws {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty
        else { throw GhostError.invalidSiteURL(raw) }

        var path = components.path
        for suffix in ["/ghost/api/admin", "/ghost/api/content", "/ghost"] {
            if let range = path.range(of: suffix, options: [.caseInsensitive]) {
                path = String(path[..<range.lowerBound])
                break
            }
        }
        while path.hasSuffix("/") { path.removeLast() }

        components.scheme = scheme
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw GhostError.invalidSiteURL(raw) }
        self.rootURL = url
    }

    /// `…/ghost/api/admin/`
    public var adminAPIURL: URL {
        rootURL.appendingPathComponent("ghost/api/admin", isDirectory: true)
    }
}
