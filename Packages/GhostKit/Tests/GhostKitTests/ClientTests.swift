import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import GhostKit

/// Returns queued responses in order and records every request.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: String
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply = lock.withLock {
            requests.append(request)
            return replies.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }
}

@Suite struct ClientTests {
    func makeClient(_ replies: [StubTransport.Reply], retry: RetryPolicy = RetryPolicy()) throws -> (GhostClient, StubTransport) {
        let transport = StubTransport(replies)
        let client = GhostClient(
            endpoint: try SiteEndpoint("https://example.com/blog"),
            key: try AdminAPIKey("abc:0011"),
            transport: transport,
            retryPolicy: retry,
            sleep: { _ in }
        )
        return (client, transport)
    }

    @Test func sendsAuthVersionAndEncodedFilter() async throws {
        let (client, transport) = try makeClient([.init(status: 200, body: Fixtures.postsPage)])
        let query = BrowseQuery(filter: .all([.equals("status", "published"), .in("tag", ["news"])]), include: ["tags"])
        _ = try await client.browse(.post, query)

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept-Version") == "v6.0")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Ghost ") == true)
        let url = try #require(request.url?.absoluteString)
        #expect(url.hasPrefix("https://example.com/blog/ghost/api/admin/posts/?"))
        #expect(url.contains("filter=status:'published'%2Btag:%5B'news'%5D") || url.contains("filter=status:%27published%27%2Btag:%5B%27news%27%5D"))
        #expect(!url.contains("+"))
    }

    @Test func decodesPostsAndPagination() async throws {
        let (client, _) = try makeClient([.init(status: 200, body: Fixtures.postsPage)])
        let page = try await client.browse(.post)
        #expect(page.items.count == 1)
        let post = try #require(page.items.first)
        #expect(post.title == "Hello")
        #expect(post.status == .published)
        #expect(post.visibility == .tiers)
        #expect(post.tiers?.map(\.name) == ["Gold"])
        #expect(post.tags?.map(\.slug) == ["news", "hash-internal"])
        #expect(post.tags?.last?.isInternal == true)
        #expect(post.updatedAt == "2025-03-01T10:00:00.000Z")
        #expect(post.publishedAt == Date(timeIntervalSince1970: 1_740_823_200.5))
        #expect(page.pagination?.next == 2)
        #expect(page.pagination?.total == 150)
    }

    @Test func editSendsOnlyChangedFields() async throws {
        let (client, transport) = try makeClient([.init(status: 200, body: Fixtures.postsPage)])
        var patch = PostPatch(updatedAt: "2025-03-01T10:00:00.000Z")
        patch.tags = [.id("t1"), .name("New tag")]
        _ = try await client.edit(.post, id: "p1", patch)

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path.hasSuffix("/ghost/api/admin/posts/p1/") == true)
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body == #"{"posts":[{"tags":[{"id":"t1"},{"name":"New tag"}],"updated_at":"2025-03-01T10:00:00.000Z"}]}"#)
    }

    @Test func mapsUpdateCollisionToConflictWithoutRetrying() async throws {
        let body = #"{"errors":[{"message":"Saving failed! Someone else is editing this post.","type":"UpdateCollisionError","code":"UPDATE_COLLISION"}]}"#
        let (client, transport) = try makeClient([.init(status: 409, body: body)])
        do {
            _ = try await client.edit(.post, id: "p1", PostPatch(updatedAt: "x"))
            Issue.record("expected an error")
        } catch GhostError.conflict(let errors) {
            #expect(errors.first?.code == "UPDATE_COLLISION")
        }
        #expect(transport.requests.count == 1)
    }

    @Test func retriesTransientFailures() async throws {
        let (client, transport) = try makeClient([
            .init(status: 503, body: ""),
            .init(status: 429, body: "", headers: ["Retry-After": "0"]),
            .init(status: 200, body: Fixtures.site),
        ])
        let site = try await client.site()
        #expect(site.title == "Example")
        #expect(site.version == "6.3")
        #expect(transport.requests.count == 3)
    }

    @Test func givesUpAfterMaxAttempts() async throws {
        let (client, transport) = try makeClient(
            Array(repeating: .init(status: 502, body: ""), count: 2),
            retry: RetryPolicy(maxAttempts: 2)
        )
        await #expect(throws: GhostError.http(status: 502, errors: [])) { try await client.site() }
        #expect(transport.requests.count == 2)
    }

    @Test func mapsAuthErrors() async throws {
        let body = #"{"errors":[{"message":"Invalid token","type":"UnauthorizedError"}]}"#
        let (client, transport) = try makeClient([.init(status: 401, body: body)])
        await #expect(throws: GhostError.unauthorized(errors: [GhostAPIError(message: "Invalid token", context: nil, type: "UnauthorizedError", code: nil)])) {
            try await client.site()
        }
        #expect(transport.requests.count == 1)
    }
}

enum Fixtures {
    static let site = #"{"site":{"title":"Example","url":"https://example.com/","version":"6.3","icon":null,"accent_color":"#ff1a75"}}"#

    static let postsPage = #"""
    {
      "posts": [{
        "id": "p1", "uuid": "u1", "title": "Hello", "slug": "hello",
        "status": "published", "visibility": "tiers", "featured": false,
        "url": "https://example.com/hello/",
        "created_at": "2025-02-01T10:00:00.000Z",
        "published_at": "2025-03-01T10:00:00.500Z",
        "updated_at": "2025-03-01T10:00:00.000Z",
        "tags": [
          {"id": "t1", "name": "News", "slug": "news", "visibility": "public"},
          {"id": "t2", "name": "#internal", "slug": "hash-internal", "visibility": "internal"}
        ],
        "authors": [{"id": "a1", "name": "Ada", "slug": "ada"}],
        "tiers": [{"id": "tier1", "name": "Gold", "slug": "gold", "type": "paid", "active": true}],
        "primary_tag": {"id": "t1", "name": "News", "slug": "news"},
        "some_future_field": {"ignored": true}
      }],
      "meta": {"pagination": {"page": 1, "limit": 1, "pages": 150, "total": 150, "next": 2, "prev": null}}
    }
    """#
}
