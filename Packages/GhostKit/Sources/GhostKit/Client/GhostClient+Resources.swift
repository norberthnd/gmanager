import Foundation

/// Options for a browse (list) request.
public struct BrowseQuery: Sendable, Equatable {
    public var filter: NQL?
    /// Items per page. Ghost 6 caps this at 100 (even for `limit=all`).
    public var limit: Int
    public var page: Int
    public var order: String?
    public var include: [String]
    /// Restrict returned fields (e.g. to skip post bodies during sync).
    public var fields: [String]
    public var extra: [URLQueryItem]

    public init(
        filter: NQL? = nil,
        limit: Int = 100,
        page: Int = 1,
        order: String? = nil,
        include: [String] = [],
        fields: [String] = [],
        extra: [URLQueryItem] = []
    ) {
        self.filter = filter
        self.limit = limit
        self.page = page
        self.order = order
        self.include = include
        self.fields = fields
        self.extra = extra
    }

    var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "page", value: String(page))]
        if let filter, !filter.rendered.isEmpty { items.append(URLQueryItem(name: "filter", value: filter.rendered)) }
        if let order { items.append(URLQueryItem(name: "order", value: order)) }
        if !include.isEmpty { items.append(URLQueryItem(name: "include", value: include.joined(separator: ","))) }
        if !fields.isEmpty { items.append(URLQueryItem(name: "fields", value: fields.joined(separator: ","))) }
        return items + extra
    }
}

extension GhostClient {
    public static let postIncludes = ["tags", "authors", "tiers"]

    /// Every `Post` field except bodies. Browse returns `lexical` by default,
    /// so sync passes these as `fields=` to keep responses small.
    public static let postSyncFields = [
        "id", "uuid", "title", "slug", "status", "visibility", "featured", "url", "excerpt",
        "custom_excerpt", "feature_image", "feature_image_alt", "meta_title", "meta_description",
        "canonical_url", "custom_template", "created_at", "published_at", "updated_at",
    ]

    // MARK: Site

    public func site() async throws -> SiteInfo {
        let data = try await send(.get, "site")
        return try decode(Envelope<SiteInfo>.self, from: data).single("site")
    }

    /// Confirms the key is accepted. `/site/` answers without auth and
    /// `/users/me/` is 404 for integrations, so this makes the smallest
    /// authenticated request instead. Throws `.unauthorized` for a bad key.
    public func verifyAccess() async throws {
        _ = try await send(.get, "posts", query: [URLQueryItem(name: "limit", value: "1"), URLQueryItem(name: "fields", value: "id")])
    }

    // MARK: Posts & pages

    public func browse(_ kind: ContentKind, _ query: BrowseQuery = BrowseQuery(include: GhostClient.postIncludes)) async throws -> ResultPage<Post> {
        try await browse(kind.resource, query)
    }

    public func read(_ kind: ContentKind, id: String) async throws -> Post {
        let data = try await send(.get, "\(kind.resource)/\(id)", query: [include(Self.postIncludes)])
        return try decode(ListEnvelope<Post>.self, from: data).first(kind.resource)
    }

    /// Applies `patch` to one post or page. Throws `.conflict` if a field
    /// changed on the server since `patch.updatedAt` was read.
    ///
    /// Relation-only changes (tags, authors) do not bump `updated_at`, so two
    /// tag edits made from the same read both succeed and the last one wins.
    /// Callers must re-read immediately before a tag edit (see docs/api-notes.md).
    public func edit(_ kind: ContentKind, id: String, _ patch: PostPatch) async throws -> Post {
        let body = try Self.encoder.encode([kind.resource: [patch]])
        let data = try await send(.put, "\(kind.resource)/\(id)", query: [include(Self.postIncludes)], body: body)
        return try decode(ListEnvelope<Post>.self, from: data).first(kind.resource)
    }

    // MARK: Tags

    public func browseTags(_ query: BrowseQuery = BrowseQuery(include: ["count.posts"])) async throws -> ResultPage<Tag> {
        try await browse("tags", query)
    }

    public func createTag(name: String, slug: String? = nil) async throws -> Tag {
        let body = try Self.encoder.encode(["tags": [TagPatch(name: name, slug: slug)]])
        let data = try await send(.post, "tags", body: body)
        return try decode(ListEnvelope<Tag>.self, from: data).first("tags")
    }

    public func editTag(id: String, _ patch: TagPatch) async throws -> Tag {
        let body = try Self.encoder.encode(["tags": [patch]])
        let data = try await send(.put, "tags/\(id)", body: body)
        return try decode(ListEnvelope<Tag>.self, from: data).first("tags")
    }

    /// Deleting a tag also removes it from every post that has it.
    public func deleteTag(id: String) async throws {
        _ = try await send(.delete, "tags/\(id)")
    }

    // MARK: Other collections

    public func browseTiers(_ query: BrowseQuery = BrowseQuery()) async throws -> ResultPage<Tier> {
        try await browse("tiers", query)
    }

    public func browseUsers(_ query: BrowseQuery = BrowseQuery()) async throws -> ResultPage<User> {
        try await browse("users", query)
    }

    public func browseNewsletters(_ query: BrowseQuery = BrowseQuery()) async throws -> ResultPage<Newsletter> {
        try await browse("newsletters", query)
    }

    /// Follows pagination and returns every item.
    public func browseAll<Item>(
        _ query: BrowseQuery,
        _ fetch: (BrowseQuery) async throws -> ResultPage<Item>
    ) async throws -> [Item] {
        var query = query
        var items: [Item] = []
        while true {
            let page = try await fetch(query)
            items += page.items
            guard let next = page.pagination?.next else { return items }
            query.page = next
        }
    }

    // MARK: Helpers

    func browse<Item: Decodable & Sendable>(_ resource: String, _ query: BrowseQuery) async throws -> ResultPage<Item> {
        let data = try await send(.get, resource, query: query.queryItems)
        let envelope = try decode(ListEnvelope<Item>.self, from: data)
        return ResultPage(items: try envelope.list(resource), pagination: envelope.meta?.pagination)
    }

    private func include(_ relations: [String]) -> URLQueryItem {
        URLQueryItem(name: "include", value: relations.joined(separator: ","))
    }
}

// MARK: - Response envelopes

/// Ghost wraps responses as `{ "<resource>": [...], "meta": {...} }`.
struct ListEnvelope<Item: Decodable>: Decodable {
    let lists: [String: [Item]]
    let meta: Meta?

    struct Meta: Decodable { let pagination: Pagination? }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        var lists: [String: [Item]] = [:]
        var meta: Meta?
        for key in container.allKeys {
            if key.stringValue == "meta" {
                meta = try container.decode(Meta.self, forKey: key)
            } else {
                lists[key.stringValue] = try container.decode([Item].self, forKey: key)
            }
        }
        self.lists = lists
        self.meta = meta
    }

    func list(_ key: String) throws -> [Item] {
        guard let list = lists[key] else { throw GhostError.decoding("Missing '\(key)' in response") }
        return list
    }

    func first(_ key: String) throws -> Item {
        guard let item = try list(key).first else { throw GhostError.decoding("Empty '\(key)' in response") }
        return item
    }
}

/// `{ "<key>": { ... } }` for single-object responses such as `/site/`.
struct Envelope<Item: Decodable>: Decodable {
    let values: [String: Item]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        var values: [String: Item] = [:]
        for key in container.allKeys {
            if let value = try? container.decode(Item.self, forKey: key) { values[key.stringValue] = value }
        }
        self.values = values
    }

    func single(_ key: String) throws -> Item {
        guard let value = values[key] else { throw GhostError.decoding("Missing '\(key)' in response") }
        return value
    }
}

struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
