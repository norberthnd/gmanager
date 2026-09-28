import Foundation
import GhostKit

/// Everything for one connected site: API client, local store, sync and
/// batch execution. The app holds one session per open site; views get a
/// session, never globals, so several sites can be open side by side later.
public final class SiteSession: Sendable {
    public let site: Site
    public let client: GhostClient
    public let store: SiteStore
    public let sync: SyncEngine
    public let executor: BatchExecutor

    public init(site: Site, client: GhostClient, store: SiteStore, parallelism: Int = 3) {
        self.site = site
        self.client = client
        self.store = store
        self.sync = SyncEngine(client: client, store: store)
        self.executor = BatchExecutor(client: client, store: store, parallelism: parallelism)
        try? store.markInterruptedBatches()
    }

    /// Opens a site's session with its stored key and on-disk store.
    public static func open(_ site: Site, credentials: CredentialStore, directory: URL, transport: HTTPTransport = URLSessionTransport()) throws -> SiteSession {
        guard let rawKey = try credentials.key(for: site.id) else { throw SessionError.missingCredentials }
        let client = GhostClient(endpoint: try SiteEndpoint(site.url), key: try AdminAPIKey(rawKey), transport: transport)
        let store = try SiteStore(url: directory.appendingPathComponent("site-\(site.id.uuidString).sqlite"))
        return SiteSession(site: site, client: client, store: store)
    }

    // MARK: Bulk operations

    public func plan(_ operation: BulkOperation, for items: [ItemKey]) throws -> Plan {
        Planner.plan(operation, items: try store.items(ids: items.map(\.id)))
    }

    public func run(_ plan: Plan) throws -> BatchRun {
        try executor.start(plan)
    }

    /// Plans the reversal of a batch: every item it changed is restored to
    /// its previous value, unless it has been changed again since.
    public func planUndo(of batchID: UUID) throws -> Plan {
        guard let batch = try store.batch(batchID) else { throw SessionError.batchNotFound }
        let entries: [BulkOperation.RestoreEntry] = batch.changes.compactMap { change in
            guard change.status.didChange, let before = change.actualBefore, let after = change.actualAfter else { return nil }
            let fields = before.changedFields(comparedTo: after)
            guard !fields.isEmpty else { return nil }
            return .init(item: change.item, fields: fields, expected: after, restore: before)
        }
        let operation = BulkOperation.restore(entries)
        let items = try store.items(ids: entries.map(\.item.id))
        var plan = Planner.plan(operation, items: items, title: "Undo “\(batch.title)”", undoOf: batchID)
        let present = Set(items.map(\.id))
        for entry in entries where !present.contains(entry.item.id) {
            plan.conflicts.append(PlannedConflict(item: entry.item, title: batch.changes.first { $0.item == entry.item }?.title ?? entry.item.id, reason: "No longer exists"))
        }
        return plan
    }

    // MARK: Tags

    /// Plans merging `source` into `target`: every post and page tagged
    /// `source` gets `target` instead (same position). Run it with
    /// `runMerge`, which deletes `source` once no item uses it.
    public func planMerge(_ source: TagRef, into target: TagRef) throws -> Plan {
        guard let sourceID = source.id else { throw SessionError.tagNotFound }
        var query = ContentQuery()
        query.kinds = [.post, .page]
        query.anyTags = [sourceID]
        let items = try store.items(matching: query)
        return Planner.plan(.replaceTag(from: source, to: target), items: items, title: "Merge “\(source.name)” into “\(target.name)”")
    }

    /// Runs a merge plan, then deletes the source tag if the server confirms
    /// nothing uses it any more. Returns the batch record.
    public func runMerge(_ plan: Plan) async throws -> BatchRecord {
        guard case .replaceTag(let source, _) = plan.operation, let sourceID = source.id else { throw SessionError.notAMerge }
        let run = try executor.start(plan)
        var record = try await run.result()
        guard record.status == .completed else { return record }

        // Re-check on the server: other posts may have gained the tag meanwhile.
        guard try await usage(ofTag: sourceID) == 0 else { return record }

        let summary = try store.tag(id: sourceID)
        try await client.deleteTag(id: sourceID)
        try store.deleteTag(id: sourceID)
        let deleted = DeletedTag(tag: source, description: summary?.description)
        try store.recordDeletedTag(batch: record.id, deleted)
        record.deletedTag = deleted
        return record
    }

    public func renameTag(_ tag: TagRef, name: String, slug: String? = nil) async throws -> Tag {
        guard let id = tag.id else { throw SessionError.tagNotFound }
        let updated = try await client.editTag(id: id, TagPatch(name: name, slug: slug))
        try store.upsertTag(updated)
        return updated
    }

    /// Deletes tags that are unused both locally and on the server.
    /// Returns the ids actually deleted; tags found in use are skipped.
    public func deleteUnusedTags(_ tags: [TagRef]) async throws -> [String] {
        var deleted: [String] = []
        for tag in tags {
            guard let id = tag.id else { continue }
            guard try await usage(ofTag: id) == 0 else { continue }
            try await client.deleteTag(id: id)
            try store.deleteTag(id: id)
            deleted.append(id)
        }
        return deleted
    }

    /// Posts plus pages using a tag, according to the server.
    func usage(ofTag id: String) async throws -> Int {
        async let posts = client.count(.post, filter: .equals("tags.id", id))
        async let pages = client.count(.page, filter: .equals("tags.id", id))
        return try await posts + pages
    }
}

public enum SessionError: Error, Equatable {
    case missingCredentials
    case batchNotFound
    case tagNotFound
    case notAMerge
}
