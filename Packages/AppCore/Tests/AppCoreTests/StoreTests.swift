import Foundation
import GhostKit
import Testing
@testable import AppCore

@Suite struct StoreTests {
    let store: SiteStore

    init() throws {
        store = try SiteStore.inMemory()
        try store.replaceTags(["news", "js", "archive", "unused"].map { Make.tag($0) })
        try store.replaceAll(.post, with: [
            Make.post("1", title: "Swift tips", featured: true, tags: ["news", "js"], publishedAt: "2024-01-10T00:00:00Z"),
            Make.post("2", title: "Old news", tags: ["news", "archive"], publishedAt: "2022-05-01T00:00:00Z"),
            Make.post("3", title: "Members only", visibility: "members", tags: ["js"], publishedAt: "2024-06-01T00:00:00Z"),
            Make.post("4", title: "Draft 100%_done", status: "draft", tags: [], publishedAt: nil),
            Make.post("5", title: "Gold", visibility: "tiers", tags: ["news"], tiers: ["gold"], publishedAt: "2023-03-03T00:00:00Z"),
        ])
        try store.replaceAll(.page, with: [Make.post("page1", title: "About", tags: ["news"])])
    }

    func ids(_ configure: (inout ContentQuery) -> Void) throws -> [String] {
        var query = ContentQuery()
        configure(&query)
        return try store.items(matching: query).map(\.id)
    }

    @Test func defaultQueryIsPostsNewestFirstDraftsLast() throws {
        #expect(try ids { _ in } == ["3", "1", "5", "2", "4"])
    }

    @Test func hydratesRelationsInOrder() throws {
        let item = try #require(try store.item(id: "1"))
        #expect(item.tags.map(\.slug) == ["news", "js"])
        #expect(item.authorIDs == ["user-ada"])
        #expect(item.featured)
        #expect(try store.item(id: "5")?.tierIDs == ["gold"])
    }

    @Test func tagConditions() throws {
        #expect(Set(try ids { $0.anyTags = ["tag-js", "tag-archive"] }) == ["1", "2", "3"])
        #expect(try ids { $0.allTags = ["tag-news", "tag-js"] } == ["1"])
        #expect(Set(try ids { $0.excludedTags = ["tag-news"] }) == ["3", "4"])
        #expect(try ids { $0.untagged = true } == ["4"])
        #expect(try ids { $0.anyTags = ["tag-news"]; $0.excludedTags = ["tag-archive"] } == ["1", "5"])
    }

    @Test func fieldConditions() throws {
        #expect(try ids { $0.statuses = [.draft] } == ["4"])
        #expect(try ids { $0.visibilities = [.members] } == ["3"])
        #expect(try ids { $0.featured = true } == ["1"])
        #expect(try ids { $0.tierIDs = ["gold"] } == ["5"])
        #expect(try ids { $0.authorIDs = ["user-nobody"] } == [])
        #expect(try ids { $0.kinds = [.page] } == ["page1"])
        #expect(try store.count(matching: { var q = ContentQuery(); q.kinds = [.post, .page]; return q }()) == 6)
    }

    @Test func dateAndTextConditions() throws {
        let formatter = ISO8601DateFormatter()
        #expect(Set(try ids { $0.publishedAfter = formatter.date(from: "2024-01-01T00:00:00Z") }) == ["1", "3"])
        #expect(try ids { $0.publishedBefore = formatter.date(from: "2023-01-01T00:00:00Z") } == ["2"])
        #expect(try ids { $0.text = "swift" } == ["1"])
        #expect(try ids { $0.text = "post-2" } == ["2"], "matches slug")
        #expect(try ids { $0.text = "100%_" } == ["4"], "LIKE wildcards are escaped")
        #expect(try ids { $0.text = "t%" } == [], "% is literal, not a wildcard")
    }

    @Test func sorting() throws {
        #expect(try ids { $0.sort = .init(field: .title, ascending: true) } == ["4", "5", "3", "2", "1"])
    }

    @Test func tagSummariesCountPostsAndPages() throws {
        let tags = Dictionary(uniqueKeysWithValues: try store.tags().map { ($0.tag.slug, $0) })
        #expect(tags["news"]?.postCount == 3)
        #expect(tags["news"]?.pageCount == 1)
        #expect(tags["unused"]?.isUnused == true)
        #expect(tags["js"]?.isUnused == false)
    }

    @Test func replaceAllRemovesDeletedItemsAndTheirTags() throws {
        try store.replaceAll(.post, with: [Make.post("1", tags: ["js"])])
        #expect(try ids { _ in } == ["1"])
        #expect(try store.item(id: "1")?.tags.map(\.slug) == ["js"])
        #expect(try store.item(id: "page1") != nil, "pages untouched")
    }

    @Test func deletingTagDetachesIt() throws {
        try store.deleteTag(id: "tag-news")
        #expect(try store.item(id: "1")?.tags.map(\.slug) == ["js"])
        #expect(!(try store.tagIDs().contains("tag-news")))
    }

    @Test func savedFiltersRoundTrip() throws {
        var query = ContentQuery()
        query.anyTags = ["tag-news"]
        query.statuses = [.published]
        try store.saveFilter(SavedFilter(name: "Published news", query: query))
        let saved = try store.savedFilters()
        #expect(saved.map(\.name) == ["Published news"])
        #expect(saved.first?.query == query)
        try store.deleteFilter(id: saved[0].id)
        #expect(try store.savedFilters().isEmpty)
    }

    @Test func changeLogRoundTrip() throws {
        let items = try store.items(ids: ["1", "2"])
        let plan = Planner.plan(.removeTags([Make.ref("news")]), items: items)
        let id = try store.beginBatch(plan)
        try store.recordChange(batch: id, item: .post("1"), status: .applied, actualBefore: plan.changes[0].before, actualAfter: plan.changes[0].after, message: nil)
        try store.markInterruptedBatches()

        let batch = try #require(try store.batch(id))
        #expect(batch.status == .interrupted)
        #expect(batch.operation == plan.operation)
        #expect(batch.changes.map(\.status) == [.applied, .cancelled])
        #expect(batch.changes[0].actualAfter?.tags.map(\.slug) == ["js"])
        #expect(try store.batches().map(\.id) == [id])
    }

    @Test func undoPlanRestoresChangedItemsAndSkipsEditedOnes() throws {
        let session = SiteSession(
            site: Site(name: "Test", url: "https://example.com"),
            client: GhostClient(endpoint: try SiteEndpoint("https://example.com"), key: try AdminAPIKey("a:00")),
            store: store
        )
        let plan = try session.plan(.removeTags([Make.ref("news")]), for: [.post("1"), .post("2"), .post("3")])
        #expect(plan.changes.count == 2)
        let id = try store.beginBatch(plan)
        for change in plan.changes {
            try store.recordChange(batch: id, item: change.item, status: .applied, actualBefore: change.before, actualAfter: change.after, message: nil)
        }
        try store.finishBatch(id, status: .completed)
        // Simulate the server state after the batch; post 2 was then edited again.
        try store.upsert([Make.post("1", featured: true, tags: ["js"]), Make.post("2", tags: [])], kind: .post)

        let undo = try session.planUndo(of: id)
        #expect(undo.undoOf == id)
        #expect(undo.changes.map(\.item.id) == ["1"])
        #expect(undo.changes.first?.after.tags.map(\.slug) == ["news", "js"])
        #expect(undo.changes.first?.after.featured == true, "undo only touches the batch's fields")
        #expect(undo.conflicts.map(\.item.id) == ["2"])
    }
}
