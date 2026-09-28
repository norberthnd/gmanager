import Foundation
import GhostKit
import Testing
@testable import AppCore

/// End-to-end against a real Ghost (tools/ghost-dev). Enabled when
/// `GHOST_URL` and `GHOST_ADMIN_KEY` are set. Works on `seed`-tagged posts
/// and uses unique tag names per run, restoring what it changes.
@Suite(.serialized, .enabled(if: Live.isConfigured, "GHOST_URL / GHOST_ADMIN_KEY not set"))
struct LiveSessionTests {
    let session: SiteSession
    let run = String(UUID().uuidString.prefix(6)).lowercased()

    init() async throws {
        session = SiteSession(site: Site(name: "Live", url: Live.url), client: Live.client(), store: try SiteStore.inMemory())
        try await session.sync.run()
    }

    /// Published seed posts from the local store.
    func seedPosts(_ count: Int, excluding: Set<String> = []) throws -> [ContentItem] {
        var query = ContentQuery()
        query.statuses = [.published]
        query.anyTags = [try #require(try session.store.tags().first { $0.tag.slug == "seed" }?.tag.id)]
        return Array(try session.store.items(matching: query).filter { !excluding.contains($0.id) }.prefix(count))
    }

    func serverState(_ key: ItemKey) async throws -> ItemState {
        ItemState(try await session.client.read(key.kind, id: key.id, fields: GhostClient.postSyncFields))
    }

    @Test func syncMirrorsServerCounts() async throws {
        let posts = try await session.client.count(.post)
        let pages = try await session.client.count(.page)
        #expect(try session.store.count() == posts)
        #expect(try session.store.count(matching: { var q = ContentQuery(); q.kinds = [.page]; return q }()) == pages)
        #expect(try session.store.tags().contains { $0.tag.slug == "seed" })
        #expect(try !session.store.tiers().isEmpty)
        #expect(session.sync.lastSync != nil)
        let seed = try #require(try session.store.tags().first { $0.tag.slug == "seed" })
        #expect(try await session.usage(ofTag: seed.tag.id!) == seed.postCount + seed.pageCount)
    }

    @Test func addThenRemoveTagThenUndo() async throws {
        let items = try seedPosts(5)
        let tag = TagRef.new(name: "Live \(run)")

        let added = try await session.executor.run(try session.plan(.addTags([tag]), for: items.map(\.key)))
        #expect(added.status == .completed)
        #expect(added.count(.applied) == 5)
        for item in items {
            #expect(try await serverState(item.key).tags.last?.slug == tag.slug)
            #expect(try session.store.item(id: item.id)?.tags.last?.slug == tag.slug, "local store updated from response")
        }

        let createdID = try #require(try session.store.item(id: items[0].id)?.tags.last?.id)
        let removed = try await session.executor.run(try session.plan(.removeTags([TagRef(id: createdID, slug: tag.slug, name: tag.name)]), for: items.map(\.key)))
        #expect(removed.count(.applied) == 5)

        // Undo the removal → tag back, in its original position.
        let undo = try session.planUndo(of: removed.id)
        #expect(undo.changes.count == 5)
        let undone = try await session.executor.run(undo)
        #expect(undone.status == .completed)
        for item in items {
            #expect(try await serverState(item.key).tags.last?.slug == tag.slug)
        }

        // Clean up.
        _ = try await session.executor.run(try session.plan(.removeTags([TagRef(id: createdID, slug: tag.slug, name: tag.name)]), for: items.map(\.key)))
        _ = try await session.deleteUnusedTags([TagRef(id: createdID, slug: tag.slug, name: tag.name)])
    }

    @Test func editMadeOnServerAfterPreviewIsKept() async throws {
        let item = try #require(try seedPosts(1).first)
        let ours = TagRef.new(name: "Ours \(run)")
        let theirs = TagRef.new(name: "Theirs \(run)")
        let plan = try session.plan(.addTags([ours]), for: [item.key])

        // Someone else adds a tag after our preview, without touching updated_at.
        let fresh = try await session.client.read(.post, id: item.id)
        var patch = PostPatch(updatedAt: fresh.updatedAt)
        patch.tags = (fresh.tags ?? []).map { Ref.id($0.id) } + [.name(theirs.name)]
        _ = try await session.client.edit(.post, id: item.id, patch)

        let record = try await session.executor.run(plan)
        #expect(record.changes.first?.status == .adjusted)
        let slugs = try await serverState(item.key).tags.map(\.slug)
        #expect(slugs.contains(theirs.slug), "their tag was not overwritten")
        #expect(slugs.contains(ours.slug))

        // Clean up.
        let tags = try await serverState(item.key).tags.filter { $0.slug == ours.slug || $0.slug == theirs.slug }
        try await session.sync.run()
        _ = try await session.executor.run(try session.plan(.removeTags(tags), for: [item.key]))
        _ = try await session.deleteUnusedTags(tags)
    }

    @Test func visibilityToTiersAndUndo() async throws {
        let items = try seedPosts(3)
        let gold = try #require(try session.store.tiers().first { $0.name == "Gold" })
        let original = try await items.asyncMap { try await serverState($0.key) }

        let record = try await session.executor.run(try session.plan(.setVisibility(.tiers, tierIDs: [gold.id]), for: items.map(\.key)))
        #expect(record.changedCount == items.filter { !($0.visibility == .tiers && $0.tierIDs == [gold.id]) }.count)
        for item in items {
            let state = try await serverState(item.key)
            #expect(state.visibility == .tiers)
            #expect(state.tierIDs == [gold.id])
        }

        _ = try await session.executor.run(try session.planUndo(of: record.id))
        for (item, before) in zip(items, original) {
            #expect(try await serverState(item.key).visibility == before.visibility)
        }
    }

    @Test func undoSkipsItemsChangedAgain() async throws {
        let items = try seedPosts(2).filter { !$0.featured }
        try #require(items.count == 2)
        let record = try await session.executor.run(try session.plan(.setFeatured(true), for: items.map(\.key)))
        #expect(record.count(.applied) == 2)

        // Someone unfeatures the first post again.
        let fresh = try await session.client.read(.post, id: items[0].id)
        var patch = PostPatch(updatedAt: fresh.updatedAt)
        patch.featured = false
        _ = try await session.client.edit(.post, id: items[0].id, patch)

        // Local store is stale here: the plan expects both, execution detects the conflict.
        let undo = try await session.executor.run(try session.planUndo(of: record.id))
        let statuses = Dictionary(uniqueKeysWithValues: undo.changes.map { ($0.item.id, $0.status) })
        #expect(statuses[items[0].id] == .conflict)
        #expect(statuses[items[1].id] == .applied)
        #expect(undo.status == .completedWithIssues)
        #expect(try await serverState(items[1].key).featured == false)
    }

    @Test func mergeTagsThenUndoRecreatesSource() async throws {
        let sourcePosts = try seedPosts(3)
        let targetPost = try #require(try seedPosts(1, excluding: Set(sourcePosts.map(\.id))).first)
        let source = TagRef.new(name: "Merge Source \(run)")
        let target = TagRef.new(name: "Merge Target \(run)")
        _ = try await session.executor.run(try session.plan(.addTags([source]), for: sourcePosts.map(\.key)))
        _ = try await session.executor.run(try session.plan(.addTags([target]), for: [targetPost.key]))
        try await session.sync.run()
        let sourceRef = try #require(try session.store.tags().first { $0.tag.slug == source.slug }?.tag)
        let targetRef = try #require(try session.store.tags().first { $0.tag.slug == target.slug }?.tag)

        let plan = try session.planMerge(sourceRef, into: targetRef)
        #expect(plan.changes.count == 3)
        let merged = try await session.runMerge(plan)
        #expect(merged.status == .completed)
        #expect(merged.deletedTag?.tag.slug == source.slug)
        let serverTags = try await session.client.browseTags(BrowseQuery(filter: .equals("slug", source.slug))).items
        #expect(serverTags.isEmpty, "source tag deleted on the server")
        #expect(!(try session.store.tagIDs().contains(sourceRef.id!)))
        for item in sourcePosts {
            let slugs = try await serverState(item.key).tags.map(\.slug)
            #expect(slugs.contains(target.slug) && !slugs.contains(source.slug))
        }

        // Undo: the deleted tag is recreated by slug + name and put back.
        let undone = try await session.executor.run(try session.planUndo(of: merged.id))
        #expect(undone.count(.applied) == 3)
        for item in sourcePosts {
            let slugs = try await serverState(item.key).tags.map(\.slug)
            #expect(slugs.contains(source.slug) && !slugs.contains(target.slug))
        }

        // Clean up.
        try await session.sync.run()
        let cleanup = try session.store.tags().filter { $0.tag.slug == source.slug || $0.tag.slug == target.slug }.map(\.tag)
        _ = try await session.executor.run(try session.plan(.removeTags(cleanup), for: (sourcePosts + [targetPost]).map(\.key)))
        #expect(try await session.deleteUnusedTags(cleanup).count == 2)
    }

    @Test func cancelStopsStartingNewItems() async throws {
        let items = try seedPosts(12)
        let executor = BatchExecutor(client: session.client, store: session.store, parallelism: 1)
        let tag = TagRef.new(name: "Cancel \(run)")
        let batch = try executor.start(try session.plan(.addTags([tag]), for: items.map(\.key)))
        for await event in batch.events {
            if case .itemFinished(_, _, _, let completed, _) = event, completed == 2 { batch.cancel() }
        }
        let record = try await batch.result()
        #expect(record.status == .cancelled)
        #expect(record.count(.cancelled) > 0)
        #expect(record.changedCount >= 2 && record.changedCount < items.count)

        // Clean up via undo of what was applied.
        _ = try await session.executor.run(try session.planUndo(of: record.id))
        try await session.sync.run()
        _ = try await session.deleteUnusedTags(try session.store.tags().filter { $0.tag.slug == tag.slug }.map(\.tag))
    }
}

extension LiveSessionTests {
    @Test func pauseHoldsNewItemsUntilResumed() async throws {
        let items = try seedPosts(6)
        let executor = BatchExecutor(client: session.client, store: session.store, parallelism: 1)
        let tag = TagRef.new(name: "Pause \(run)")
        let batch = try executor.start(try session.plan(.addTags([tag]), for: items.map(\.key)))

        var completedAtPause = 0
        var sawPaused = false
        for await event in batch.events {
            switch event {
            case .itemFinished(_, _, _, let completed, _) where completed == 1 && !sawPaused:
                await batch.pause()
            case .paused:
                sawPaused = true
                try await Task.sleep(for: .milliseconds(800))
                completedAtPause = try session.store.batch(batch.id)?.changes.filter { $0.status != .pending }.count ?? 0
                await batch.resume()
            default:
                break
            }
        }
        let record = try await batch.result()
        #expect(sawPaused)
        #expect(completedAtPause <= 2, "at most the in-flight item finished while paused")
        #expect(record.status == .completed)
        #expect(record.changedCount == items.count)

        _ = try await session.executor.run(try session.planUndo(of: record.id))
        try await session.sync.run()
        _ = try await session.deleteUnusedTags(try session.store.tags().filter { $0.tag.slug == tag.slug }.map(\.tag))
    }
}

enum Live {
    static let env = ProcessInfo.processInfo.environment
    static var isConfigured: Bool { env["GHOST_URL"] != nil && env["GHOST_ADMIN_KEY"] != nil }
    static var url: String { env["GHOST_URL"] ?? "http://localhost" }

    static func client() -> GhostClient {
        GhostClient(endpoint: try! SiteEndpoint(url), key: try! AdminAPIKey(env["GHOST_ADMIN_KEY"] ?? "a:00"))
    }
}

extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
