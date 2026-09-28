import Foundation
import Testing
@testable import GhostKit

/// Runs against a real Ghost when `GHOST_URL` and `GHOST_ADMIN_KEY` are set
/// (see tools/ghost-dev: `set -a; . tools/ghost-dev/.env; swift test`).
/// Skipped otherwise. Only edits posts tagged `seed`.
@Suite(.enabled(if: LiveGhost.isConfigured, "GHOST_URL / GHOST_ADMIN_KEY not set"))
struct LiveGhostTests {
    let client = LiveGhost.client()

    @Test func acceptsKeyAndRejectsBadKey() async throws {
        try await client.verifyAccess()

        let bad = GhostClient(
            endpoint: client.endpoint,
            key: try AdminAPIKey("000000000000000000000000:" + String(repeating: "ab", count: 32)),
            retryPolicy: .none
        )
        await #expect {
            try await bad.verifyAccess()
        } throws: { error in
            if case GhostError.unauthorized = error { return true }
            return false
        }
    }

    @Test func readsSiteInfo() async throws {
        let site = try await client.site()
        #expect(site.version?.hasPrefix("6.") == true)
    }

    @Test func browsesAllPagesWithoutBodies() async throws {
        let query = BrowseQuery(
            filter: .equals("tag", "seed"),
            include: GhostClient.postIncludes,
            fields: GhostClient.postSyncFields
        )
        let posts = try await client.browseAll(query) { try await client.browse(.post, $0) }
        #expect(posts.count > 100, "seed data spans more than one page")
        #expect(Set(posts.map(\.id)).count == posts.count, "no duplicates across pages")
        #expect(posts.allSatisfy { $0.tags?.contains { $0.slug == "seed" } == true })
    }

    @Test func filtersWithCompoundNQL() async throws {
        let query = BrowseQuery(
            filter: .all([.equals("status", "published"), .notIn("tag", ["news"]), .equals("tag", "seed")]),
            limit: 100,
            fields: GhostClient.postSyncFields
        )
        let page = try await client.browse(.post, query)
        #expect(page.pagination?.total ?? 0 > 0)
    }

    @Test func editsFieldAndDetectsConflict() async throws {
        let query = BrowseQuery(filter: .all([.equals("tag", "seed"), .equals("status", "published")]), limit: 1, include: GhostClient.postIncludes)
        let post = try #require(try await client.browse(.post, query).items.first)
        try await Task.sleep(for: .milliseconds(1100)) // updated_at has one-second resolution

        var patch = PostPatch(updatedAt: post.updatedAt)
        patch.featured = !(post.featured ?? false)
        let edited = try await client.edit(.post, id: post.id, patch)
        #expect(edited.featured == patch.featured)
        #expect(edited.updatedAt != post.updatedAt)
        #expect(edited.tags == post.tags, "untouched relations are preserved")

        var stale = PostPatch(updatedAt: post.updatedAt)
        stale.featured = post.featured
        await #expect {
            _ = try await client.edit(.post, id: post.id, stale)
        } throws: { error in
            if case GhostError.conflict = error { return true }
            return false
        }

        // Restore.
        var restore = PostPatch(updatedAt: edited.updatedAt)
        restore.featured = post.featured
        _ = try await client.edit(.post, id: post.id, restore)
    }
}

enum LiveGhost {
    static var isConfigured: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["GHOST_URL"] != nil && env["GHOST_ADMIN_KEY"] != nil
    }

    static func client() -> GhostClient {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["GHOST_URL"], let key = env["GHOST_ADMIN_KEY"] else {
            return GhostClient(endpoint: try! SiteEndpoint("http://localhost"), key: try! AdminAPIKey("a:00"))
        }
        return GhostClient(endpoint: try! SiteEndpoint(url), key: try! AdminAPIKey(key))
    }
}
