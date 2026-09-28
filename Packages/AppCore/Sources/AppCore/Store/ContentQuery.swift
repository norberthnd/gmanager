import Foundation
import GhostKit
import GRDB

/// A filter over the local store. Empty sets mean "any".
///
/// Richer than Ghost's NQL where it matters for bulk work: tag conditions
/// combine any / all / none, and "untagged" is a first-class option.
public struct ContentQuery: Codable, Hashable, Sendable {
    public var kinds: Set<ContentKind> = [.post]
    public var statuses: Set<PostStatus> = []
    public var visibilities: Set<Visibility> = []
    /// Items restricted to any of these tiers (only `visibility == tiers`).
    public var tierIDs: Set<String> = []
    public var authorIDs: Set<String> = []
    public var featured: Bool?

    /// Has at least one of these tags.
    public var anyTags: Set<String> = []
    /// Has every one of these tags.
    public var allTags: Set<String> = []
    /// Has none of these tags.
    public var excludedTags: Set<String> = []
    /// Has no tags at all.
    public var untagged = false

    public var publishedAfter: Date?
    public var publishedBefore: Date?
    public var updatedAfter: Date?
    public var updatedBefore: Date?

    /// Case-insensitive match on title or slug.
    public var text: String?

    public var sort = Sort()

    public init() {}

    public struct Sort: Codable, Hashable, Sendable {
        public enum Field: String, Codable, Sendable, CaseIterable {
            case title, publishedAt, updatedAt, createdAt, status
        }
        public var field: Field = .publishedAt
        public var ascending = false
        public init(field: Field = .publishedAt, ascending: Bool = false) {
            self.field = field
            self.ascending = ascending
        }
    }

    // MARK: SQL

    func sql() -> (String, StatementArguments) {
        let (whereClause, arguments) = conditions()
        let direction = sort.ascending ? "ASC" : "DESC"
        let column: String
        switch sort.field {
        case .title: column = "title COLLATE NOCASE"
        case .publishedAt: column = "publishedAt"
        case .updatedAt: column = "updatedAt"
        case .createdAt: column = "createdAt"
        case .status: column = "status"
        }
        // Drafts have no publishedAt; keep them at the end of a date sort.
        let nulls = sort.field == .publishedAt ? "publishedAt IS NULL, " : ""
        return ("SELECT item.* FROM item \(whereClause) ORDER BY \(nulls)\(column) \(direction), id", arguments)
    }

    func countSQL() -> (String, StatementArguments) {
        let (whereClause, arguments) = conditions()
        return ("SELECT COUNT(*) FROM item \(whereClause)", arguments)
    }

    private func conditions() -> (String, StatementArguments) {
        var clauses: [String] = []
        var arguments = StatementArguments()

        func inList<T: DatabaseValueConvertible>(_ column: String, _ values: [T]) {
            clauses.append("\(column) IN (\(placeholders(values.count)))")
            arguments += StatementArguments(values)
        }

        if !kinds.isEmpty { inList("kind", kinds.map(\.rawValue).sorted()) }
        if !statuses.isEmpty { inList("status", statuses.map(\.rawValue).sorted()) }
        if !visibilities.isEmpty { inList("visibility", visibilities.map(\.rawValue).sorted()) }
        if let featured {
            clauses.append("featured = ?")
            arguments += [featured]
        }
        if !tierIDs.isEmpty {
            clauses.append("visibility = 'tiers' AND id IN (SELECT itemId FROM item_tier WHERE tierId IN (\(placeholders(tierIDs.count))))")
            arguments += StatementArguments(tierIDs.sorted())
        }
        if !authorIDs.isEmpty {
            clauses.append("id IN (SELECT itemId FROM item_author WHERE authorId IN (\(placeholders(authorIDs.count))))")
            arguments += StatementArguments(authorIDs.sorted())
        }
        if !anyTags.isEmpty {
            clauses.append("id IN (SELECT itemId FROM item_tag WHERE tagId IN (\(placeholders(anyTags.count))))")
            arguments += StatementArguments(anyTags.sorted())
        }
        if !allTags.isEmpty {
            clauses.append("id IN (SELECT itemId FROM item_tag WHERE tagId IN (\(placeholders(allTags.count))) GROUP BY itemId HAVING COUNT(DISTINCT tagId) = ?)")
            arguments += StatementArguments(allTags.sorted())
            arguments += [allTags.count]
        }
        if !excludedTags.isEmpty {
            clauses.append("id NOT IN (SELECT itemId FROM item_tag WHERE tagId IN (\(placeholders(excludedTags.count))))")
            arguments += StatementArguments(excludedTags.sorted())
        }
        if untagged {
            clauses.append("id NOT IN (SELECT itemId FROM item_tag)")
        }
        if let publishedAfter {
            clauses.append("publishedAt >= ?")
            arguments += [publishedAfter]
        }
        if let publishedBefore {
            clauses.append("publishedAt < ?")
            arguments += [publishedBefore]
        }
        if let updatedAfter {
            clauses.append("updatedAt >= ?")
            arguments += [updatedAfter]
        }
        if let updatedBefore {
            clauses.append("updatedAt < ?")
            arguments += [updatedBefore]
        }
        if let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            let pattern = "%" + text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_") + "%"
            clauses.append("(title LIKE ? ESCAPE '\\' OR slug LIKE ? ESCAPE '\\')")
            arguments += [pattern, pattern]
        }
        return (clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND "), arguments)
    }
}
