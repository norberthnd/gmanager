import Foundation
import GhostKit
@testable import AppCore

/// Builds `Post` values the way the API would return them.
enum Make {
    static func tag(_ slug: String, id: String? = nil) -> Tag {
        try! decode(Tag.self, ["id": id ?? "tag-\(slug)", "name": slug.capitalized, "slug": slug])
    }

    static func post(
        _ id: String,
        title: String? = nil,
        status: String = "published",
        visibility: String = "public",
        featured: Bool = false,
        tags: [String] = [],
        tiers: [String] = [],
        authors: [String] = ["ada"],
        publishedAt: String? = "2025-01-01T00:00:00Z",
        updatedAt: String = "2025-01-01T00:00:00.000Z"
    ) -> Post {
        var json: [String: Any] = [
            "id": id, "title": title ?? "Post \(id)", "slug": "post-\(id)", "status": status,
            "visibility": visibility, "featured": featured, "updated_at": updatedAt,
            "tags": tags.map { ["id": "tag-\($0)", "name": $0.capitalized, "slug": $0] },
            "tiers": tiers.map { ["id": $0, "name": $0.capitalized] },
            "authors": authors.map { ["id": "user-\($0)", "name": $0.capitalized, "slug": $0] },
        ]
        if let publishedAt { json["published_at"] = publishedAt }
        return try! decode(Post.self, json)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: [String: Any]) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: JSONSerialization.data(withJSONObject: json))
    }

    static func ref(_ slug: String) -> TagRef {
        TagRef(id: "tag-\(slug)", slug: slug, name: slug.capitalized)
    }

    static func state(tags: [String] = [], visibility: Visibility = .public, tiers: [String] = [], featured: Bool = false) -> ItemState {
        ItemState(tags: tags.map(ref), visibility: visibility, tierIDs: tiers, featured: featured)
    }
}

extension ItemKey {
    static func post(_ id: String) -> ItemKey { ItemKey(kind: .post, id: id) }
}
