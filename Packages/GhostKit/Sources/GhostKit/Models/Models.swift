import Foundation

/// Posts and pages share one model and one set of endpoints.
public enum ContentKind: String, Sendable, Codable, CaseIterable {
    case post
    case page

    /// Path segment and JSON root key: `posts` / `pages`.
    public var resource: String { rawValue + "s" }
}

public enum PostStatus: String, Sendable, Codable {
    case draft, published, scheduled, sent
}

public enum Visibility: String, Sendable, Codable {
    case `public`, members, paid, tiers
}

/// Reference to a related object when editing.
///
/// Ghost resolves tag references by `id`, else by `slug`, else by `name`,
/// creating the tag when no match exists. An unknown `id` fails the whole
/// edit (422), so references to tags that may have been deleted must use
/// `slug` + `name` instead.
public struct Ref: Sendable, Codable, Equatable, Hashable {
    public var id: String?
    public var slug: String?
    public var name: String?

    public init(id: String? = nil, slug: String? = nil, name: String? = nil) {
        self.id = id
        self.slug = slug
        self.name = name
    }

    public static func id(_ id: String) -> Ref { Ref(id: id) }
    public static func name(_ name: String) -> Ref { Ref(name: name) }
    public static func slug(_ slug: String, name: String) -> Ref { Ref(slug: slug, name: name) }
}

public struct Post: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let uuid: String?
    public var title: String?
    public var slug: String
    public var status: PostStatus
    public var visibility: Visibility?
    public var featured: Bool?
    public var url: String?
    public var excerpt: String?
    public var customExcerpt: String?
    public var featureImage: String?
    public var featureImageAlt: String?
    public var metaTitle: String?
    public var metaDescription: String?
    public var canonicalURL: String?
    public var customTemplate: String?
    public var createdAt: Date?
    public var publishedAt: Date?
    /// Kept as the server's exact string: edits must echo it back verbatim.
    public var updatedAt: String
    public var tags: [Tag]?
    public var authors: [User]?
    public var tiers: [Tier]?
    public var primaryTag: Tag?

    enum CodingKeys: String, CodingKey {
        case id, uuid, title, slug, status, visibility, featured, url, excerpt, tags, authors, tiers
        case customExcerpt = "custom_excerpt"
        case featureImage = "feature_image"
        case featureImageAlt = "feature_image_alt"
        case metaTitle = "meta_title"
        case metaDescription = "meta_description"
        case canonicalURL = "canonical_url"
        case customTemplate = "custom_template"
        case createdAt = "created_at"
        case publishedAt = "published_at"
        case updatedAt = "updated_at"
        case primaryTag = "primary_tag"
    }
}

/// Fields to change on a post or page. `nil` fields are left out of the
/// request and therefore untouched on the server.
public struct PostPatch: Sendable, Encodable, Equatable {
    public var updatedAt: String
    public var tags: [Ref]?
    public var visibility: Visibility?
    public var tiers: [Ref]?
    public var featured: Bool?
    public var status: PostStatus?
    public var authors: [Ref]?

    public init(updatedAt: String) { self.updatedAt = updatedAt }

    enum CodingKeys: String, CodingKey {
        case tags, visibility, tiers, featured, status, authors
        case updatedAt = "updated_at"
    }
}

public struct Tag: Sendable, Codable, Equatable, Hashable, Identifiable {
    public let id: String
    public var name: String
    public var slug: String
    public var description: String?
    public var visibility: String?
    public var url: String?
    public var updatedAt: String?
    public var count: Count?

    public struct Count: Sendable, Codable, Equatable, Hashable {
        public var posts: Int?
    }

    /// Internal tags start with `#` and have `visibility: internal`.
    public var isInternal: Bool { visibility == "internal" || name.hasPrefix("#") }

    enum CodingKeys: String, CodingKey {
        case id, name, slug, description, visibility, url, count
        case updatedAt = "updated_at"
    }
}

public struct TagPatch: Sendable, Encodable, Equatable {
    public var name: String?
    public var slug: String?
    public var description: String?
    public init(name: String? = nil, slug: String? = nil, description: String? = nil) {
        self.name = name
        self.slug = slug
        self.description = description
    }
}

public struct Tier: Sendable, Codable, Equatable, Hashable, Identifiable {
    public let id: String
    public var name: String
    public var slug: String?
    public var type: String?
    public var active: Bool?
    public var visibility: String?

    public init(id: String, name: String, slug: String? = nil, type: String? = nil, active: Bool? = nil, visibility: String? = nil) {
        self.id = id
        self.name = name
        self.slug = slug
        self.type = type
        self.active = active
        self.visibility = visibility
    }
}

public struct User: Sendable, Codable, Equatable, Hashable, Identifiable {
    public let id: String
    public var name: String
    public var slug: String
    public var email: String?
    public var profileImage: String?

    public init(id: String, name: String, slug: String, email: String? = nil, profileImage: String? = nil) {
        self.id = id
        self.name = name
        self.slug = slug
        self.email = email
        self.profileImage = profileImage
    }

    enum CodingKeys: String, CodingKey {
        case id, name, slug, email
        case profileImage = "profile_image"
    }
}

public struct Newsletter: Sendable, Codable, Equatable, Hashable, Identifiable {
    public let id: String
    public var name: String
    public var slug: String?
    public var status: String?

    public init(id: String, name: String, slug: String? = nil, status: String? = nil) {
        self.id = id
        self.name = name
        self.slug = slug
        self.status = status
    }
}

public struct SiteInfo: Sendable, Codable, Equatable {
    public var title: String
    public var url: String
    public var version: String?
    public var icon: String?
    public var accentColor: String?

    enum CodingKeys: String, CodingKey {
        case title, url, version, icon
        case accentColor = "accent_color"
    }
}

public struct Pagination: Sendable, Codable, Equatable {
    public var page: Int
    public var limit: Int
    public var pages: Int
    public var total: Int
    public var next: Int?
    public var prev: Int?
}

/// One page of a browse response.
public struct ResultPage<Item: Sendable>: Sendable {
    public var items: [Item]
    public var pagination: Pagination?
}
