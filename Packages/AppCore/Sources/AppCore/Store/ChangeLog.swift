import Foundation
import GhostKit
import GRDB

public enum BatchStatus: String, Codable, Sendable {
    case running
    case completed
    /// Finished, but some items failed or conflicted.
    case completedWithIssues
    case cancelled
    /// The app quit or crashed while running.
    case interrupted
}

public enum ChangeStatus: String, Codable, Sendable {
    case pending
    case applied
    /// Applied to a state that differed from the preview (the post changed
    /// in between); `actualBefore`/`actualAfter` hold what really happened.
    case adjusted
    /// The fresh state already matched the target.
    case unchanged
    case conflict
    case failed
    case cancelled

    public var didChange: Bool { self == .applied || self == .adjusted }
}

public struct ChangeRecord: Identifiable, Hashable, Sendable {
    public var item: ItemKey
    public var id: String { item.id }
    public var title: String
    public var plannedBefore: ItemState
    public var plannedAfter: ItemState
    public var status: ChangeStatus
    public var actualBefore: ItemState?
    public var actualAfter: ItemState?
    public var message: String?
}

/// A tag the batch deleted (tag merge), kept so undo can recreate it.
public struct DeletedTag: Codable, Hashable, Sendable {
    public var tag: TagRef
    public var description: String?
}

public struct BatchRecord: Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var completedAt: Date?
    public var title: String
    public var operation: BulkOperation
    public var status: BatchStatus
    public var undoOf: UUID?
    public var deletedTag: DeletedTag?
    public var changes: [ChangeRecord]

    public func count(_ status: ChangeStatus) -> Int { changes.filter { $0.status == status }.count }
    public var changedCount: Int { changes.filter { $0.status.didChange }.count }
}

extension SiteStore {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    private static func json<T: Encodable>(_ value: T?) throws -> String? {
        guard let value else { return nil }
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ text: String?) -> T? {
        guard let text else { return nil }
        return try? JSONDecoder().decode(type, from: Data(text.utf8))
    }

    /// Records a plan as a running batch, one pending row per change.
    public func beginBatch(_ plan: Plan, id: UUID = UUID()) throws -> UUID {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO batch (id, createdAt, title, operation, status, undoOf) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [id.uuidString, Date(), plan.title, try Self.json(plan.operation), BatchStatus.running.rawValue, plan.undoOf?.uuidString]
            )
            for (position, change) in plan.changes.enumerated() {
                try db.execute(sql: """
                    INSERT INTO batch_change (batchId, position, itemId, kind, title, plannedBefore, plannedAfter, status)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        id.uuidString, position, change.item.id, change.item.kind.rawValue, change.title,
                        try Self.json(change.before), try Self.json(change.after), ChangeStatus.pending.rawValue,
                    ])
            }
        }
        return id
    }

    public func recordChange(batch: UUID, item: ItemKey, status: ChangeStatus, actualBefore: ItemState?, actualAfter: ItemState?, message: String?) throws {
        try db.write { db in
            try db.execute(sql: """
                UPDATE batch_change SET status = ?, actualBefore = ?, actualAfter = ?, message = ?
                WHERE batchId = ? AND itemId = ?
                """, arguments: [status.rawValue, try Self.json(actualBefore), try Self.json(actualAfter), message, batch.uuidString, item.id])
        }
    }

    public func recordDeletedTag(batch: UUID, _ tag: DeletedTag) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE batch SET deletedTag = ? WHERE id = ?", arguments: [try Self.json(tag), batch.uuidString])
        }
    }

    public func finishBatch(_ id: UUID, status: BatchStatus) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE batch_change SET status = ? WHERE batchId = ? AND status = ?",
                           arguments: [ChangeStatus.cancelled.rawValue, id.uuidString, ChangeStatus.pending.rawValue])
            try db.execute(sql: "UPDATE batch SET status = ?, completedAt = ? WHERE id = ?",
                           arguments: [status.rawValue, Date(), id.uuidString])
        }
    }

    /// Marks batches left running by a previous launch as interrupted.
    public func markInterruptedBatches() throws {
        let running = try db.read { try String.fetchAll($0, sql: "SELECT id FROM batch WHERE status = ?", arguments: [BatchStatus.running.rawValue]) }
        for id in running.compactMap(UUID.init(uuidString:)) {
            try finishBatch(id, status: .interrupted)
        }
    }

    public func batches(limit: Int = 200) throws -> [BatchRecord] {
        let ids = try db.read {
            try String.fetchAll($0, sql: "SELECT id FROM batch ORDER BY createdAt DESC LIMIT ?", arguments: [limit])
        }
        return try ids.compactMap(UUID.init(uuidString:)).compactMap { try batch($0) }
    }

    public func batch(_ id: UUID) throws -> BatchRecord? {
        try db.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM batch WHERE id = ?", arguments: [id.uuidString]),
                  let operation = Self.decode(BulkOperation.self, row["operation"])
            else { return nil }
            let changes = try Row.fetchAll(db, sql: "SELECT * FROM batch_change WHERE batchId = ? ORDER BY position", arguments: [id.uuidString]).compactMap { r -> ChangeRecord? in
                guard let before = Self.decode(ItemState.self, r["plannedBefore"]),
                      let after = Self.decode(ItemState.self, r["plannedAfter"]) else { return nil }
                return ChangeRecord(
                    item: ItemKey(kind: ContentKind(rawValue: r["kind"]) ?? .post, id: r["itemId"]),
                    title: r["title"],
                    plannedBefore: before,
                    plannedAfter: after,
                    status: ChangeStatus(rawValue: r["status"]) ?? .pending,
                    actualBefore: Self.decode(ItemState.self, r["actualBefore"]),
                    actualAfter: Self.decode(ItemState.self, r["actualAfter"]),
                    message: r["message"]
                )
            }
            return BatchRecord(
                id: id,
                createdAt: row["createdAt"],
                completedAt: row["completedAt"],
                title: row["title"],
                operation: operation,
                status: BatchStatus(rawValue: row["status"]) ?? .interrupted,
                undoOf: (row["undoOf"] as String?).flatMap(UUID.init(uuidString:)),
                deletedTag: Self.decode(DeletedTag.self, row["deletedTag"]),
                changes: changes
            )
        }
    }
}
