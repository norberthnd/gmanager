import Foundation
import GhostKit
import GRDB

/// Local mirror of one site: posts, pages, tags, tiers, authors, newsletters,
/// plus the change log and saved filters. One SQLite file per site.
public final class SiteStore: Sendable {
    public let db: any DatabaseWriter

    /// Opens (creating if needed) the store at `url`.
    public convenience init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        try self.init(writer: DatabasePool(path: url.path, configuration: config))
    }

    /// In-memory store, for tests and previews.
    public static func inMemory() throws -> SiteStore {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try SiteStore(writer: DatabaseQueue(configuration: config))
    }

    init(writer: any DatabaseWriter) throws {
        self.db = writer
        try Self.migrator.migrate(writer)
    }

    // MARK: Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE item (
                    id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    uuid TEXT,
                    title TEXT NOT NULL DEFAULT '',
                    slug TEXT NOT NULL,
                    status TEXT NOT NULL,
                    visibility TEXT NOT NULL,
                    featured INTEGER NOT NULL DEFAULT 0,
                    url TEXT,
                    excerpt TEXT,
                    customExcerpt TEXT,
                    featureImage TEXT,
                    featureImageAlt TEXT,
                    metaTitle TEXT,
                    metaDescription TEXT,
                    canonicalURL TEXT,
                    customTemplate TEXT,
                    createdAt DATETIME,
                    publishedAt DATETIME,
                    updatedAt DATETIME,
                    updatedAtRaw TEXT NOT NULL
                );
                CREATE INDEX item_kind ON item(kind, publishedAt);

                CREATE TABLE tag (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    slug TEXT NOT NULL,
                    description TEXT,
                    visibility TEXT
                );
                CREATE INDEX tag_slug ON tag(slug);

                CREATE TABLE item_tag (
                    itemId TEXT NOT NULL REFERENCES item(id) ON DELETE CASCADE,
                    tagId TEXT NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL,
                    PRIMARY KEY (itemId, tagId)
                );
                CREATE INDEX item_tag_tag ON item_tag(tagId);

                CREATE TABLE tier (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    slug TEXT,
                    type TEXT,
                    active INTEGER,
                    visibility TEXT
                );

                CREATE TABLE item_tier (
                    itemId TEXT NOT NULL REFERENCES item(id) ON DELETE CASCADE,
                    tierId TEXT NOT NULL,
                    PRIMARY KEY (itemId, tierId)
                );

                CREATE TABLE author (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    slug TEXT NOT NULL,
                    email TEXT,
                    profileImage TEXT
                );

                CREATE TABLE item_author (
                    itemId TEXT NOT NULL REFERENCES item(id) ON DELETE CASCADE,
                    authorId TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    PRIMARY KEY (itemId, authorId)
                );

                CREATE TABLE newsletter (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    slug TEXT,
                    status TEXT
                );

                CREATE TABLE meta (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT
                );

                CREATE TABLE batch (
                    id TEXT PRIMARY KEY NOT NULL,
                    createdAt DATETIME NOT NULL,
                    completedAt DATETIME,
                    title TEXT NOT NULL,
                    operation TEXT NOT NULL,
                    status TEXT NOT NULL,
                    undoOf TEXT REFERENCES batch(id),
                    deletedTag TEXT
                );

                CREATE TABLE batch_change (
                    batchId TEXT NOT NULL REFERENCES batch(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL,
                    itemId TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    title TEXT NOT NULL,
                    plannedBefore TEXT NOT NULL,
                    plannedAfter TEXT NOT NULL,
                    status TEXT NOT NULL,
                    actualBefore TEXT,
                    actualAfter TEXT,
                    message TEXT,
                    PRIMARY KEY (batchId, itemId)
                );

                CREATE TABLE saved_filter (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    query TEXT NOT NULL,
                    position INTEGER NOT NULL
                );
                """)
        }
        return migrator
    }

    // MARK: Writing synced data

    /// Replaces every item of `kind` with `posts`; items no longer present are deleted.
    public func replaceAll(_ kind: ContentKind, with posts: [Post]) throws {
        try db.write { db in
            let keep = Set(posts.map(\.id))
            let existing = try String.fetchAll(db, sql: "SELECT id FROM item WHERE kind = ?", arguments: [kind.rawValue])
            for id in existing where !keep.contains(id) {
                try db.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [id])
            }
            for post in posts { try Self.upsert(post, kind: kind, in: db) }
        }
    }

    /// Inserts or updates single items, e.g. with the server's response after an edit.
    public func upsert(_ posts: [Post], kind: ContentKind) throws {
        try db.write { db in
            for post in posts { try Self.upsert(post, kind: kind, in: db) }
        }
    }

    public func deleteItem(id: String) throws {
        try db.write { try $0.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [id]) }
    }

    static func upsert(_ post: Post, kind: ContentKind, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO item (id, kind, uuid, title, slug, status, visibility, featured, url, excerpt,
                customExcerpt, featureImage, featureImageAlt, metaTitle, metaDescription, canonicalURL,
                customTemplate, createdAt, publishedAt, updatedAt, updatedAtRaw)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                kind = excluded.kind, uuid = excluded.uuid, title = excluded.title, slug = excluded.slug,
                status = excluded.status, visibility = excluded.visibility, featured = excluded.featured,
                url = excluded.url, excerpt = excluded.excerpt, customExcerpt = excluded.customExcerpt,
                featureImage = excluded.featureImage, featureImageAlt = excluded.featureImageAlt,
                metaTitle = excluded.metaTitle, metaDescription = excluded.metaDescription,
                canonicalURL = excluded.canonicalURL, customTemplate = excluded.customTemplate,
                createdAt = excluded.createdAt, publishedAt = excluded.publishedAt,
                updatedAt = excluded.updatedAt, updatedAtRaw = excluded.updatedAtRaw
            """, arguments: [
                post.id, kind.rawValue, post.uuid, post.title ?? "", post.slug, post.status.rawValue,
                (post.visibility ?? .public).rawValue, post.featured ?? false, post.url, post.excerpt,
                post.customExcerpt, post.featureImage, post.featureImageAlt, post.metaTitle,
                post.metaDescription, post.canonicalURL, post.customTemplate, post.createdAt,
                post.publishedAt, parseDate(post.updatedAt), post.updatedAt,
            ])

        // Relations are only replaced when the response carried them.
        if let tags = post.tags {
            try db.execute(sql: "DELETE FROM item_tag WHERE itemId = ?", arguments: [post.id])
            for (position, tag) in tags.enumerated() {
                try upsertTag(tag, in: db, overwrite: false)
                try db.execute(
                    sql: "INSERT OR IGNORE INTO item_tag (itemId, tagId, position) VALUES (?, ?, ?)",
                    arguments: [post.id, tag.id, position]
                )
            }
        }
        if let tiers = post.tiers {
            try db.execute(sql: "DELETE FROM item_tier WHERE itemId = ?", arguments: [post.id])
            for tier in tiers {
                try db.execute(sql: "INSERT OR IGNORE INTO item_tier (itemId, tierId) VALUES (?, ?)", arguments: [post.id, tier.id])
            }
        }
        if let authors = post.authors {
            try db.execute(sql: "DELETE FROM item_author WHERE itemId = ?", arguments: [post.id])
            for (position, author) in authors.enumerated() {
                try upsertAuthor(author, in: db)
                try db.execute(
                    sql: "INSERT OR IGNORE INTO item_author (itemId, authorId, position) VALUES (?, ?, ?)",
                    arguments: [post.id, author.id, position]
                )
            }
        }
    }

    public func replaceTags(_ tags: [Tag]) throws {
        try db.write { db in
            let keep = Set(tags.map(\.id))
            let existing = try String.fetchAll(db, sql: "SELECT id FROM tag")
            for id in existing where !keep.contains(id) {
                try db.execute(sql: "DELETE FROM tag WHERE id = ?", arguments: [id])
            }
            for tag in tags { try Self.upsertTag(tag, in: db, overwrite: true) }
        }
    }

    public func upsertTag(_ tag: Tag) throws {
        try db.write { try Self.upsertTag(tag, in: $0, overwrite: true) }
    }

    /// Removes a tag and its attachments (after deleting it on the server).
    public func deleteTag(id: String) throws {
        try db.write { try $0.execute(sql: "DELETE FROM tag WHERE id = ?", arguments: [id]) }
    }

    static func upsertTag(_ tag: Tag, in db: Database, overwrite: Bool) throws {
        // Tags embedded in posts lack description/visibility; don't blank them out.
        if overwrite {
            try db.execute(sql: """
                INSERT INTO tag (id, name, slug, description, visibility) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, slug = excluded.slug,
                    description = excluded.description, visibility = excluded.visibility
                """, arguments: [tag.id, tag.name, tag.slug, tag.description, tag.visibility])
        } else {
            try db.execute(sql: """
                INSERT INTO tag (id, name, slug, description, visibility) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, slug = excluded.slug,
                    visibility = COALESCE(excluded.visibility, tag.visibility)
                """, arguments: [tag.id, tag.name, tag.slug, tag.description, tag.visibility])
        }
    }

    public func replaceTiers(_ tiers: [Tier]) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM tier")
            for tier in tiers {
                try db.execute(
                    sql: "INSERT INTO tier (id, name, slug, type, active, visibility) VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [tier.id, tier.name, tier.slug, tier.type, tier.active, tier.visibility]
                )
            }
        }
    }

    public func replaceAuthors(_ users: [User]) throws {
        try db.write { db in
            for user in users { try Self.upsertAuthor(user, in: db) }
        }
    }

    static func upsertAuthor(_ user: User, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO author (id, name, slug, email, profileImage) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, slug = excluded.slug,
                email = COALESCE(excluded.email, author.email),
                profileImage = COALESCE(excluded.profileImage, author.profileImage)
            """, arguments: [user.id, user.name, user.slug, user.email, user.profileImage])
    }

    public func replaceNewsletters(_ newsletters: [Newsletter]) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM newsletter")
            for n in newsletters {
                try db.execute(sql: "INSERT INTO newsletter (id, name, slug, status) VALUES (?, ?, ?, ?)", arguments: [n.id, n.name, n.slug, n.status])
            }
        }
    }

    // MARK: Meta

    public func setMeta(_ key: String, _ value: String?) throws {
        try db.write {
            try $0.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value])
        }
    }

    public func meta(_ key: String) throws -> String? {
        try db.read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) }
    }

    // MARK: Reading

    public func items(matching query: ContentQuery = ContentQuery()) throws -> [ContentItem] {
        try db.read { db in
            let (sql, arguments) = query.sql()
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return try Self.hydrate(rows, in: db)
        }
    }

    public func items(ids: [String]) throws -> [ContentItem] {
        guard !ids.isEmpty else { return [] }
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM item WHERE id IN (\(placeholders(ids.count)))", arguments: StatementArguments(ids))
            let byID = Dictionary(uniqueKeysWithValues: try Self.hydrate(rows, in: db).map { ($0.id, $0) })
            return ids.compactMap { byID[$0] }
        }
    }

    public func item(id: String) throws -> ContentItem? {
        try items(ids: [id]).first
    }

    public func count(matching query: ContentQuery = ContentQuery()) throws -> Int {
        try db.read { db in
            let (sql, arguments) = query.countSQL()
            return try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
        }
    }

    static func hydrate(_ rows: [Row], in db: Database) throws -> [ContentItem] {
        guard !rows.isEmpty else { return [] }
        let ids: [String] = rows.map { $0["id"] }
        var tags: [String: [TagRef]] = [:]
        var tiers: [String: [String]] = [:]
        var authors: [String: [String]] = [:]
        // Chunk to stay well under SQLite's bound-parameter limit.
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            let marks = placeholders(chunk.count)
            for row in try Row.fetchAll(db, sql: """
                SELECT it.itemId, t.id, t.slug, t.name FROM item_tag it JOIN tag t ON t.id = it.tagId
                WHERE it.itemId IN (\(marks)) ORDER BY it.itemId, it.position
                """, arguments: StatementArguments(chunk)) {
                tags[row[0], default: []].append(TagRef(id: row[1], slug: row[2], name: row[3]))
            }
            for row in try Row.fetchAll(db, sql: "SELECT itemId, tierId FROM item_tier WHERE itemId IN (\(marks))", arguments: StatementArguments(chunk)) {
                tiers[row[0], default: []].append(row[1])
            }
            for row in try Row.fetchAll(db, sql: "SELECT itemId, authorId FROM item_author WHERE itemId IN (\(marks)) ORDER BY itemId, position", arguments: StatementArguments(chunk)) {
                authors[row[0], default: []].append(row[1])
            }
        }
        return rows.map { row in
            let id: String = row["id"]
            let kind = ContentKind(rawValue: row["kind"]) ?? .post
            return ContentItem(
                key: ItemKey(kind: kind, id: id),
                title: row["title"],
                slug: row["slug"],
                status: PostStatus(rawValue: row["status"]) ?? .draft,
                visibility: Visibility(rawValue: row["visibility"]) ?? .public,
                featured: row["featured"],
                url: row["url"],
                excerpt: row["customExcerpt"] ?? row["excerpt"],
                featureImage: row["featureImage"],
                metaDescription: row["metaDescription"],
                createdAt: row["createdAt"],
                publishedAt: row["publishedAt"],
                updatedAt: row["updatedAt"],
                updatedAtRaw: row["updatedAtRaw"],
                tags: tags[id] ?? [],
                tierIDs: (tiers[id] ?? []).sorted(),
                authorIDs: authors[id] ?? []
            )
        }
    }

    public func tags() throws -> [TagSummary] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.id, t.name, t.slug, t.description, t.visibility,
                    COUNT(CASE WHEN i.kind = 'post' THEN 1 END) AS posts,
                    COUNT(CASE WHEN i.kind = 'page' THEN 1 END) AS pages
                FROM tag t
                LEFT JOIN item_tag it ON it.tagId = t.id
                LEFT JOIN item i ON i.id = it.itemId
                GROUP BY t.id
                ORDER BY t.name COLLATE NOCASE
                """).map { row in
                TagSummary(
                    tag: TagRef(id: row["id"], slug: row["slug"], name: row["name"]),
                    description: row["description"],
                    visibility: row["visibility"],
                    postCount: row["posts"],
                    pageCount: row["pages"]
                )
            }
        }
    }

    public func tag(id: String) throws -> TagSummary? {
        try tags().first { $0.tag.id == id }
    }

    public func tagIDs() throws -> Set<String> {
        try db.read { Set(try String.fetchAll($0, sql: "SELECT id FROM tag")) }
    }

    public func tiers() throws -> [Tier] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM tier ORDER BY name COLLATE NOCASE").map {
                Tier(id: $0["id"], name: $0["name"], slug: $0["slug"], type: $0["type"], active: $0["active"], visibility: $0["visibility"])
            }
        }
    }

    public func authors() throws -> [User] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM author ORDER BY name COLLATE NOCASE").map {
                User(id: $0["id"], name: $0["name"], slug: $0["slug"], email: $0["email"], profileImage: $0["profileImage"])
            }
        }
    }

    public func newsletters() throws -> [Newsletter] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM newsletter ORDER BY name COLLATE NOCASE").map {
                Newsletter(id: $0["id"], name: $0["name"], slug: $0["slug"], status: $0["status"])
            }
        }
    }

    // MARK: Saved filters

    public func savedFilters() throws -> [SavedFilter] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM saved_filter ORDER BY position").compactMap { row in
                guard let query = try? JSONDecoder().decode(ContentQuery.self, from: Data((row["query"] as String).utf8)) else { return nil }
                return SavedFilter(id: UUID(uuidString: row["id"]) ?? UUID(), name: row["name"], query: query)
            }
        }
    }

    public func saveFilter(_ filter: SavedFilter) throws {
        let json = String(decoding: try JSONEncoder().encode(filter.query), as: UTF8.self)
        try db.write { db in
            let position = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM saved_filter") ?? 0
            try db.execute(sql: """
                INSERT INTO saved_filter (id, name, query, position) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, query = excluded.query
                """, arguments: [filter.id.uuidString, filter.name, json, position])
        }
    }

    public func deleteFilter(id: UUID) throws {
        try db.write { try $0.execute(sql: "DELETE FROM saved_filter WHERE id = ?", arguments: [id.uuidString]) }
    }
}

public struct TagSummary: Identifiable, Hashable, Sendable {
    public var tag: TagRef
    public var id: String { tag.id ?? tag.slug }
    public var description: String?
    public var visibility: String?
    public var postCount: Int
    public var pageCount: Int
    public var isUnused: Bool { postCount == 0 && pageCount == 0 }
}

public struct SavedFilter: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var query: ContentQuery

    public init(id: UUID = UUID(), name: String, query: ContentQuery) {
        self.id = id
        self.name = name
        self.query = query
    }
}

func placeholders(_ count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}

func parseDate(_ text: String) -> Date? {
    if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
    return try? Date.ISO8601FormatStyle().parse(text)
}
