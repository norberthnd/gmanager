import Foundation
import Testing
@testable import GhostKit

@Suite struct NQLTests {
    @Test func rendersComparisons() {
        #expect(NQL.equals("status", "published").rendered == "status:'published'")
        #expect(NQL.notEquals("visibility", "public").rendered == "visibility:-'public'")
        #expect(NQL.equals("featured", true).rendered == "featured:true")
        #expect(NQL.isNull("feature_image").rendered == "feature_image:null")
        #expect(NQL.isNotNull("feature_image").rendered == "feature_image:-null")
        #expect(NQL.compare(field: "title", op: .contains, value: .string("swift")).rendered == "title:~'swift'")
    }

    @Test func rendersLists() {
        #expect(NQL.in("tag", ["news", "updates"]).rendered == "tag:['news','updates']")
        #expect(NQL.notIn("tag", ["hash-archive"]).rendered == "tag:-['hash-archive']")
    }

    @Test func escapesQuotes() {
        #expect(NQL.equals("title", "It's").rendered == #"title:'It\'s'"#)
    }

    @Test func rendersDatesInUTC() {
        let date = Date(timeIntervalSince1970: 1_672_531_200) // 2023-01-01 00:00:00 UTC
        #expect(NQL.compare(field: "published_at", op: .less, value: .date(date)).rendered == "published_at:<'2023-01-01 00:00:00'")
    }

    @Test func groupsNestedExpressions() {
        let filter: NQL = .all([
            .equals("status", "published"),
            .any([.equals("tag", "a"), .equals("tag", "b")]),
        ])
        #expect(filter.rendered == "status:'published'+(tag:'a',tag:'b')")
    }

    @Test func flattensTrivialGroups() {
        #expect(NQL.all([]).rendered == "")
        #expect(NQL.all([.any([.equals("tag", "a")])]).rendered == "tag:'a'")
    }
}
