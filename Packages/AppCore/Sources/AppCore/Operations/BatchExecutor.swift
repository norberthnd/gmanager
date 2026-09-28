import Foundation
import GhostKit

public enum BatchEvent: Sendable {
    case started(batch: UUID, total: Int)
    case itemFinished(ItemKey, ChangeStatus, message: String?, completed: Int, total: Int)
    case paused
    case resumed
    case finished(BatchStatus)
}

/// A running (or finished) batch. Pause, resume or cancel it; await `result()`.
public final class BatchRun: Sendable {
    public let id: UUID
    public let plan: Plan
    public let events: AsyncStream<BatchEvent>
    let control: RunControl
    let task: Task<BatchRecord, Error>

    init(id: UUID, plan: Plan, events: AsyncStream<BatchEvent>, control: RunControl, task: Task<BatchRecord, Error>) {
        self.id = id
        self.plan = plan
        self.events = events
        self.control = control
        self.task = task
    }

    public func pause() async { await control.pause() }
    public func resume() async { await control.resume() }
    /// Stops starting new items; items already being written finish.
    /// A paused run is resumed so it can wind down.
    public func cancel() {
        task.cancel()
        Task { await control.resume() }
    }
    public func result() async throws -> BatchRecord { try await task.value }
}

actor RunControl {
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    let emit: @Sendable (BatchEvent) -> Void

    init(emit: @escaping @Sendable (BatchEvent) -> Void) { self.emit = emit }

    var isPaused: Bool { paused }

    func pause() {
        guard !paused else { return }
        paused = true
        emit(.paused)
    }

    func resume() {
        guard paused else { return }
        paused = false
        emit(.resumed)
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func waitIfPaused() async {
        if paused { await withCheckedContinuation { waiters.append($0) } }
    }
}

/// Applies plans to the server, one post at a time with bounded parallelism.
///
/// Per item: re-read the post, apply the operation to its *fresh* state,
/// send only the changed fields with the fresh `updated_at`, store the
/// server's response locally and record before/after in the change log.
/// On a conflict (409) the item is re-read and retried.
public struct BatchExecutor: Sendable {
    public let client: GhostClient
    public let store: SiteStore
    public var parallelism: Int
    public var maxAttempts = 3

    public init(client: GhostClient, store: SiteStore, parallelism: Int = 3) {
        self.client = client
        self.store = store
        self.parallelism = max(1, parallelism)
    }

    public func start(_ plan: Plan) throws -> BatchRun {
        let batchID = try store.beginBatch(plan)
        let (events, continuation) = AsyncStream<BatchEvent>.makeStream()
        let control = RunControl { continuation.yield($0) }
        let executor = self
        let task = Task<BatchRecord, Error> {
            defer { continuation.finish() }
            continuation.yield(.started(batch: batchID, total: plan.changes.count))
            let status = await executor.execute(plan, batch: batchID, control: control) { continuation.yield($0) }
            try executor.store.finishBatch(batchID, status: status)
            continuation.yield(.finished(status))
            guard let record = try executor.store.batch(batchID) else { throw GhostError.invalidResponse }
            return record
        }
        return BatchRun(id: batchID, plan: plan, events: events, control: control, task: task)
    }

    /// Runs `plan` to completion and returns the batch record.
    public func run(_ plan: Plan) async throws -> BatchRecord {
        try await start(plan).result()
    }

    private func execute(_ plan: Plan, batch: UUID, control: RunControl, emit: @Sendable (BatchEvent) -> Void) async -> BatchStatus {
        let total = plan.changes.count
        var completed = 0
        var hadIssues = false

        await withTaskGroup(of: (ItemKey, ItemResult).self) { group in
            var pending = plan.changes[...]
            var running = 0
            while true {
                // Fill free slots, unless paused or cancelled. While paused with
                // items in flight, keep collecting their results.
                while running < parallelism, !pending.isEmpty, !Task.isCancelled {
                    if running > 0, await control.isPaused { break }
                    await control.waitIfPaused()
                    guard !Task.isCancelled, let change = pending.popFirst() else { break }
                    group.addTask {
                        // Unstructured, so cancelling the batch doesn't abort a
                        // write mid-request and leave its outcome unknown.
                        let result = await Task { await self.apply(plan.operation, to: change) }.value
                        return (change.item, result)
                    }
                    running += 1
                }
                guard let (item, result) = await group.next() else { break }
                running -= 1
                completed += 1
                if result.status == .failed || result.status == .conflict { hadIssues = true }
                try? store.recordChange(batch: batch, item: item, status: result.status, actualBefore: result.before, actualAfter: result.after, message: result.message)
                emit(.itemFinished(item, result.status, message: result.message, completed: completed, total: total))
            }
        }

        if Task.isCancelled && completed < total { return .cancelled }
        return hadIssues ? .completedWithIssues : .completed
    }

    struct ItemResult {
        var status: ChangeStatus
        var before: ItemState?
        var after: ItemState?
        var message: String?
    }

    func apply(_ operation: BulkOperation, to change: PlannedChange) async -> ItemResult {
        let key = change.item
        var lastError: Error?
        for _ in 1...maxAttempts {
            do {
                let fresh = try await client.read(key.kind, id: key.id, fields: GhostClient.postSyncFields)
                try? store.upsert([fresh], kind: key.kind)
                let current = ItemState(fresh)

                let target: ItemState
                switch operation.outcome(for: key, current: current) {
                case .noChange:
                    return ItemResult(status: .unchanged, before: current, after: current, message: nil)
                case .conflict(let reason):
                    return ItemResult(status: .conflict, before: current, message: reason)
                case .change(let value):
                    target = value
                }

                let patch = try makePatch(from: current, to: target, updatedAt: fresh.updatedAt, fields: operation.fields)
                let updated = try await client.edit(key.kind, id: key.id, patch)
                try? store.upsert([updated], kind: key.kind)
                let result = ItemState(updated)

                let driftedFromPreview = !current.equals(change.before, in: operation.fields)
                var message: String?
                if driftedFromPreview {
                    message = "Changed on the server after the preview; applied to its current state."
                }
                if !result.equals(target, in: operation.fields) {
                    message = [message, "Ghost stored: \(result)"].compactMap { $0 }.joined(separator: " ")
                }
                return ItemResult(status: driftedFromPreview ? .adjusted : .applied, before: current, after: result, message: message)
            } catch GhostError.conflict {
                lastError = GhostError.conflict(errors: [])
                continue // re-read and try again
            } catch GhostError.notFound {
                try? store.deleteItem(id: key.id)
                return ItemResult(status: .failed, message: "No longer exists on the server.")
            } catch {
                return ItemResult(status: .failed, message: Self.describe(error))
            }
        }
        return ItemResult(status: .conflict, message: "Kept changing on the server (\(lastError.map(Self.describe) ?? "conflict")).")
    }

    /// Only the fields that differ are sent. Tags are sent by id when the tag
    /// is known to exist, otherwise by slug + name so Ghost reuses or recreates it.
    func makePatch(from current: ItemState, to target: ItemState, updatedAt: String, fields: Set<ItemField>) throws -> PostPatch {
        var patch = PostPatch(updatedAt: updatedAt)
        let changed = current.changedFields(comparedTo: target).intersection(fields)
        if changed.contains(.tags) {
            let known = try store.tagIDs().union(current.tags.compactMap(\.id))
            patch.tags = target.tags.map { tag in
                if let id = tag.id, known.contains(id) { return .id(id) }
                return .slug(tag.slug, name: tag.name)
            }
        }
        if changed.contains(.visibility) {
            patch.visibility = target.visibility
            if target.visibility == .tiers { patch.tiers = target.tierIDs.map(Ref.id) }
        }
        if changed.contains(.featured) {
            patch.featured = target.featured
        }
        return patch
    }

    static func describe(_ error: Error) -> String {
        guard let ghost = error as? GhostError else { return String(describing: error) }
        switch ghost {
        case .http(let status, let errors):
            return "HTTP \(status): " + (errors.first.map { [$0.message, $0.context].compactMap { $0 }.joined(separator: " — ") } ?? "")
        case .unauthorized(let errors): return "Not authorised: " + (errors.first?.message ?? "")
        case .rateLimited: return "Rate limited by the server."
        case .transport(let text): return "Network error: \(text)"
        default: return String(describing: ghost)
        }
    }
}
