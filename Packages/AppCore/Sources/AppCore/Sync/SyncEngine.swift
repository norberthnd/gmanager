import Foundation
import GhostKit

public struct SyncProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case metadata, posts, pages, saving
    }
    public var phase: Phase
    public var fetched: Int
    public var total: Int?
}

public struct SyncReport: Sendable, Equatable {
    public var posts: Int
    public var pages: Int
    public var tags: Int
    public var duration: TimeInterval
    public var completedAt: Date
}

/// Mirrors a site into its `SiteStore`.
///
/// Always a full sync of metadata (no post bodies): Ghost doesn't bump
/// `updated_at` for tag-only changes, so an incremental "changed since"
/// sync would miss tag edits made elsewhere. Without bodies, a 5,000-post
/// site is 50 requests, fetched in parallel within the client's limit.
public struct SyncEngine: Sendable {
    public static let lastSyncKey = "lastSyncAt"

    public let client: GhostClient
    public let store: SiteStore

    public init(client: GhostClient, store: SiteStore) {
        self.client = client
        self.store = store
    }

    @discardableResult
    public func run(progress: (@Sendable (SyncProgress) -> Void)? = nil) async throws -> SyncReport {
        let started = Date()
        progress?(SyncProgress(phase: .metadata, fetched: 0, total: nil))

        async let tiers = client.browseAll(BrowseQuery(limit: 100)) { try await client.browseTiers($0) }
        async let users = client.browseAll(BrowseQuery(limit: 100)) { try await client.browseUsers($0) }
        async let newsletters = client.browseAll(BrowseQuery(limit: 100)) { try await client.browseNewsletters($0) }
        async let tags = client.browseAll(BrowseQuery(limit: 100, order: "id asc")) { try await client.browseTags($0) }
        let (fetchedTiers, fetchedUsers, fetchedNewsletters, fetchedTags) = try await (tiers, users, newsletters, tags)

        let posts = try await fetchAll(.post, progress: progress)
        let pages = try await fetchAll(.page, progress: progress)

        progress?(SyncProgress(phase: .saving, fetched: posts.count + pages.count, total: posts.count + pages.count))
        try store.replaceTiers(fetchedTiers)
        try store.replaceAuthors(fetchedUsers)
        try store.replaceNewsletters(fetchedNewsletters)
        try store.replaceTags(fetchedTags)
        try store.replaceAll(.post, with: posts)
        try store.replaceAll(.page, with: pages)
        let now = Date()
        try store.setMeta(Self.lastSyncKey, String(now.timeIntervalSince1970))

        return SyncReport(posts: posts.count, pages: pages.count, tags: fetchedTags.count, duration: now.timeIntervalSince(started), completedAt: now)
    }

    public var lastSync: Date? {
        (try? store.meta(Self.lastSyncKey)).flatMap { $0.flatMap(TimeInterval.init) }.map(Date.init(timeIntervalSince1970:))
    }

    /// Fetches page 1, then the remaining pages concurrently. Ordered by id
    /// (creation order) so new posts land on the last page; if the total
    /// changes mid-sync the whole fetch is repeated once.
    func fetchAll(_ kind: ContentKind, progress: (@Sendable (SyncProgress) -> Void)?) async throws -> [Post] {
        let phase: SyncProgress.Phase = kind == .post ? .posts : .pages
        for attempt in 1...2 {
            let base = BrowseQuery(limit: 100, order: "id asc", include: GhostClient.postIncludes, fields: GhostClient.postSyncFields)
            let first = try await client.browse(kind, base)
            let pageCount = first.pagination?.pages ?? 1
            let total = first.pagination?.total ?? first.items.count
            progress?(SyncProgress(phase: phase, fetched: first.items.count, total: total))

            var pages: [Int: [Post]] = [1: first.items]
            if pageCount > 1 {
                try await withThrowingTaskGroup(of: (Int, ResultPage<Post>).self) { group in
                    for number in 2...pageCount {
                        var query = base
                        query.page = number
                        group.addTask { (number, try await client.browse(kind, query)) }
                    }
                    var fetched = first.items.count
                    for try await (number, page) in group {
                        pages[number] = page.items
                        fetched += page.items.count
                        progress?(SyncProgress(phase: phase, fetched: fetched, total: total))
                    }
                }
            }

            var seen = Set<String>()
            let items = pages.keys.sorted().flatMap { pages[$0]! }.filter { seen.insert($0.id).inserted }
            if items.count == total || attempt == 2 { return items }
        }
        return []
    }
}
