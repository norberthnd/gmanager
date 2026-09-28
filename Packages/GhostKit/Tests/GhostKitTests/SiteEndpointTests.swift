import Testing
@testable import GhostKit

@Suite struct SiteEndpointTests {
    @Test(arguments: [
        ("https://example.com", "https://example.com"),
        ("https://example.com/", "https://example.com"),
        ("example.com", "https://example.com"),
        ("https://example.com/ghost/", "https://example.com"),
        ("https://example.com/ghost/api/admin/", "https://example.com"),
        ("https://Example.com/ghost/#/dashboard", "https://example.com"),
        ("https://example.com/blog/", "https://example.com/blog"),
        ("https://example.com/blog/ghost/api/admin", "https://example.com/blog"),
        ("http://localhost:2368", "http://localhost:2368"),
    ])
    func normalisesToSiteRoot(input: String, expected: String) throws {
        let endpoint = try SiteEndpoint(input)
        #expect(endpoint.rootURL.absoluteString.lowercased() == expected)
    }

    @Test func derivesAdminAPIURL() throws {
        let endpoint = try SiteEndpoint("https://example.com/blog")
        #expect(endpoint.adminAPIURL.absoluteString == "https://example.com/blog/ghost/api/admin/")
    }

    @Test(arguments: ["", "ftp://example.com", "https://"])
    func rejectsInvalidURLs(_ input: String) {
        #expect(throws: GhostError.self) { try SiteEndpoint(input) }
    }
}
