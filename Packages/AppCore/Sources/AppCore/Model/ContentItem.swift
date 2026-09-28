import Foundation
import GhostKit

/// Identifies a post or page. Ghost ids are unique across both.
public struct ItemKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public var kind: ContentKind
    public var id: String

    public init(kind: ContentKind, id: String) {
        self.kind = kind
        self.id = id
    }

    public var description: String { "\(kind.rawValue):\(id)" }
}

/// A tag as attached to a post. `id` is nil for a tag that does not exist yet
/// (to be created by name) or whose id is unknown.
public struct TagRef: Hashable, Codable, Sendable {
    public var id: String?
    public var slug: String
    public var name: String

    public init(id: String?, slug: String, name: String) {
        self.id = id
        self.slug = slug
        self.name = name
    }

    public init(_ tag: Tag) {
        self.init(id: tag.id, slug: tag.slug, name: tag.name)
    }

    /// A tag that will be created from `name` if no tag with its slug exists.
    public static func new(name: String) -> TagRef {
        TagRef(id: nil, slug: Slug.make(name), name: name)
    }

    /// Same tag: by id when both are known, otherwise by slug.
    public func matches(_ other: TagRef) -> Bool {
        if let id, let otherID = other.id { return id == otherID }
        return slug == other.slug
    }

    public var isInternal: Bool { name.hasPrefix("#") }
}

/// The editable state of a post that bulk operations read and write.
public struct ItemState: Codable, Hashable, Sendable, CustomStringConvertible {
    /// Ordered; the first tag is the primary tag.
    public var tags: [TagRef]
    public var visibility: Visibility
    /// Only meaningful when `visibility == .tiers`.
    public var tierIDs: [String]
    public var featured: Bool

    public init(tags: [TagRef], visibility: Visibility, tierIDs: [String], featured: Bool) {
        self.tags = tags
        self.visibility = visibility
        self.tierIDs = tierIDs.sorted()
        self.featured = featured
    }

    public init(_ post: Post) {
        self.init(
            tags: (post.tags ?? []).map(TagRef.init),
            visibility: post.visibility ?? .public,
            tierIDs: (post.tiers ?? []).map(\.id),
            featured: post.featured ?? false
        )
    }

    /// The fields in which `self` and `other` differ.
    public func changedFields(comparedTo other: ItemState) -> Set<ItemField> {
        var fields: Set<ItemField> = []
        if !Self.sameTags(tags, other.tags) { fields.insert(.tags) }
        if visibility != other.visibility || (visibility == .tiers && tierIDs != other.tierIDs) {
            fields.insert(.visibility)
        }
        if featured != other.featured { fields.insert(.featured) }
        return fields
    }

    public func equals(_ other: ItemState, in fields: Set<ItemField>) -> Bool {
        changedFields(comparedTo: other).isDisjoint(with: fields)
    }

    /// Copies `fields` from `source` into `self`.
    public func replacing(_ fields: Set<ItemField>, from source: ItemState) -> ItemState {
        var result = self
        if fields.contains(.tags) { result.tags = source.tags }
        if fields.contains(.visibility) {
            result.visibility = source.visibility
            result.tierIDs = source.tierIDs
        }
        if fields.contains(.featured) { result.featured = source.featured }
        return result
    }

    static func sameTags(_ a: [TagRef], _ b: [TagRef]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.matches($1) }
    }

    public var description: String {
        let tagList = tags.map(\.slug).joined(separator: ",")
        let tiers = visibility == .tiers ? "(\(tierIDs.joined(separator: ",")))" : ""
        return "tags=[\(tagList)] visibility=\(visibility.rawValue)\(tiers) featured=\(featured)"
    }
}

public enum ItemField: String, Codable, Sendable, CaseIterable, Comparable {
    case tags, visibility, featured

    public static func < (a: ItemField, b: ItemField) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// A post or page as held in the local store.
public struct ContentItem: Identifiable, Hashable, Sendable {
    public var key: ItemKey
    public var id: String { key.id }
    public var kind: ContentKind { key.kind }
    public var title: String
    public var slug: String
    public var status: PostStatus
    public var visibility: Visibility
    public var featured: Bool
    public var url: String?
    public var excerpt: String?
    public var featureImage: String?
    public var metaDescription: String?
    public var createdAt: Date?
    public var publishedAt: Date?
    public var updatedAt: Date?
    /// Exact server value; edits must echo it back.
    public var updatedAtRaw: String
    public var tags: [TagRef]
    public var tierIDs: [String]
    public var authorIDs: [String]

    public var state: ItemState {
        ItemState(tags: tags, visibility: visibility, tierIDs: tierIDs, featured: featured)
    }

    public static func == (a: ContentItem, b: ContentItem) -> Bool {
        a.key == b.key && a.updatedAtRaw == b.updatedAtRaw && ItemState.sameTags(a.tags, b.tags)
            && a.visibility == b.visibility && a.tierIDs == b.tierIDs && a.featured == b.featured
            && a.title == b.title && a.status == b.status
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(updatedAtRaw)
    }
}

/// Approximation of Ghost's slug rules, used to compare not-yet-created tags.
/// The server's slug replaces it once the tag exists.
enum Slug {
    static func make(_ name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespaces)
        var prefix = ""
        if text.hasPrefix("#") {
            prefix = "hash-"
            text.removeFirst()
        }
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var slug = ""
        var lastWasDash = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return prefix + slug
    }
}
