import Foundation
import GhostKit

/// A bulk change, expressed as intent ("remove tag X") rather than as final
/// values, so it can be re-applied to a post's fresh state at execution time.
///
/// Re-applying matters because Ghost doesn't conflict-check tag-only edits
/// (see docs/api-notes.md): the executor re-reads every post right before
/// writing and applies the operation to what is actually there.
public enum BulkOperation: Codable, Hashable, Sendable {
    /// Adds tags not already present, after the existing ones.
    case addTags([TagRef])
    case removeTags([TagRef])
    /// Replaces `from` with `to` in the same position; if `to` is already
    /// present, `from` is just removed.
    case replaceTag(from: TagRef, to: TagRef)
    /// `tierIDs` is used only for `.tiers`.
    case setVisibility(Visibility, tierIDs: [String])
    case setFeatured(Bool)
    /// Undo of a batch: per item, restore `fields` to `restore`, but only if
    /// they still equal `expected` (the batch's result); otherwise conflict.
    case restore([RestoreEntry])

    public struct RestoreEntry: Codable, Hashable, Sendable {
        public var item: ItemKey
        public var fields: Set<ItemField>
        public var expected: ItemState
        public var restore: ItemState
    }

    public enum Outcome: Sendable, Equatable {
        case change(ItemState)
        case noChange
        case conflict(String)
    }

    /// Fields this operation may modify.
    public var fields: Set<ItemField> {
        switch self {
        case .addTags, .removeTags, .replaceTag: return [.tags]
        case .setVisibility: return [.visibility]
        case .setFeatured: return [.featured]
        case .restore(let entries): return entries.reduce(into: []) { $0.formUnion($1.fields) }
        }
    }

    /// Items an operation is limited to, if it names them itself (undo).
    public var restrictedItems: [ItemKey]? {
        if case .restore(let entries) = self { return entries.map(\.item) }
        return nil
    }

    public func outcome(for item: ItemKey, current: ItemState) -> Outcome {
        var target = current
        switch self {
        case .addTags(let tags):
            for tag in tags where !target.tags.contains(where: { $0.matches(tag) }) {
                target.tags.append(tag)
            }
        case .removeTags(let tags):
            target.tags.removeAll { existing in tags.contains { $0.matches(existing) } }
        case .replaceTag(let from, let to):
            guard let index = target.tags.firstIndex(where: { $0.matches(from) }) else { return .noChange }
            if target.tags.contains(where: { $0.matches(to) }) {
                target.tags.remove(at: index)
            } else {
                target.tags[index] = to
            }
        case .setVisibility(let visibility, let tierIDs):
            target.visibility = visibility
            target.tierIDs = visibility == .tiers ? tierIDs.sorted() : current.tierIDs
        case .setFeatured(let featured):
            target.featured = featured
        case .restore(let entries):
            guard let entry = entries.first(where: { $0.item == item }) else { return .noChange }
            guard current.equals(entry.expected, in: entry.fields) else {
                return .conflict("Changed since the original batch ran")
            }
            target = current.replacing(entry.fields, from: entry.restore)
        }
        return current.changedFields(comparedTo: target).isEmpty ? .noChange : .change(target)
    }

    /// Short human-readable description, used as the batch title.
    public var summary: String {
        func names(_ tags: [TagRef]) -> String { tags.map { "“\($0.name)”" }.joined(separator: ", ") }
        switch self {
        case .addTags(let tags): return "Add \(names(tags))"
        case .removeTags(let tags): return "Remove \(names(tags))"
        case .replaceTag(let from, let to): return "Replace “\(from.name)” with “\(to.name)”"
        case .setVisibility(let visibility, let tiers):
            return visibility == .tiers ? "Set access to \(tiers.count) tier(s)" : "Set access to \(visibility.rawValue)"
        case .setFeatured(let featured): return featured ? "Feature" : "Unfeature"
        case .restore(let entries): return "Undo (\(entries.count) item\(entries.count == 1 ? "" : "s"))"
        }
    }
}

/// What a batch will do, computed from the local store before anything is sent.
public struct Plan: Sendable {
    public var operation: BulkOperation
    public var title: String
    /// Items that will change, with local before/after for the preview.
    public var changes: [PlannedChange]
    /// Selected items the operation would not change.
    public var unchanged: [ItemKey]
    /// Items the operation refuses to change (undo of items edited since).
    public var conflicts: [PlannedConflict]
    /// Set when this plan undoes a batch.
    public var undoOf: UUID?

    public var isEmpty: Bool { changes.isEmpty }
}

public struct PlannedChange: Identifiable, Hashable, Codable, Sendable {
    public var item: ItemKey
    public var id: String { item.id }
    public var title: String
    public var before: ItemState
    public var after: ItemState

    public var changedFields: Set<ItemField> { before.changedFields(comparedTo: after) }

    public static func == (a: PlannedChange, b: PlannedChange) -> Bool { a.item == b.item }
    public func hash(into hasher: inout Hasher) { hasher.combine(item) }
}

public struct PlannedConflict: Hashable, Sendable {
    public var item: ItemKey
    public var title: String
    public var reason: String
}

public enum Planner {
    /// Plans `operation` over `items` using their locally stored state.
    public static func plan(_ operation: BulkOperation, items: [ContentItem], title: String? = nil, undoOf: UUID? = nil) -> Plan {
        var changes: [PlannedChange] = []
        var unchanged: [ItemKey] = []
        var conflicts: [PlannedConflict] = []
        for item in items {
            switch operation.outcome(for: item.key, current: item.state) {
            case .change(let after):
                changes.append(PlannedChange(item: item.key, title: item.title, before: item.state, after: after))
            case .noChange:
                unchanged.append(item.key)
            case .conflict(let reason):
                conflicts.append(PlannedConflict(item: item.key, title: item.title, reason: reason))
            }
        }
        return Plan(operation: operation, title: title ?? operation.summary, changes: changes, unchanged: unchanged, conflicts: conflicts, undoOf: undoOf)
    }
}
