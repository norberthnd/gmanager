import GhostKit
import Testing
@testable import AppCore

@Suite struct OperationTests {
    let key = ItemKey.post("p1")

    func target(_ op: BulkOperation, _ state: ItemState) -> ItemState? {
        if case .change(let s) = op.outcome(for: key, current: state) { return s }
        return nil
    }

    @Test func addTagsAppendsMissingOnly() {
        let result = target(.addTags([Make.ref("b"), Make.ref("c")]), Make.state(tags: ["a", "b"]))
        #expect(result?.tags.map(\.slug) == ["a", "b", "c"])
        #expect(BulkOperation.addTags([Make.ref("a")]).outcome(for: key, current: Make.state(tags: ["a"])) == .noChange)
    }

    @Test func newTagMatchesExistingBySlug() {
        // A tag typed by name matches an existing tag with the same slug.
        let op = BulkOperation.addTags([.new(name: "News")])
        #expect(op.outcome(for: key, current: Make.state(tags: ["news"])) == .noChange)
    }

    @Test func removeTagsKeepsOrder() {
        let result = target(.removeTags([Make.ref("b")]), Make.state(tags: ["a", "b", "c"]))
        #expect(result?.tags.map(\.slug) == ["a", "c"])
        #expect(BulkOperation.removeTags([Make.ref("x")]).outcome(for: key, current: Make.state(tags: ["a"])) == .noChange)
    }

    @Test func replaceTagKeepsPosition() {
        let result = target(.replaceTag(from: Make.ref("a"), to: Make.ref("z")), Make.state(tags: ["a", "b"]))
        #expect(result?.tags.map(\.slug) == ["z", "b"], "primary tag stays primary")
    }

    @Test func replaceTagWhenTargetAlreadyPresentJustRemoves() {
        let result = target(.replaceTag(from: Make.ref("a"), to: Make.ref("b")), Make.state(tags: ["a", "b"]))
        #expect(result?.tags.map(\.slug) == ["b"])
    }

    @Test func setVisibility() {
        let tiers = target(.setVisibility(.tiers, tierIDs: ["gold"]), Make.state())
        #expect(tiers?.visibility == .tiers)
        #expect(tiers?.tierIDs == ["gold"])

        // Changing only the tier set of a tiers post is a change.
        #expect(target(.setVisibility(.tiers, tierIDs: ["silver"]), Make.state(visibility: .tiers, tiers: ["gold"])) != nil)
        // Tier ids don't matter for non-tier visibility.
        #expect(BulkOperation.setVisibility(.paid, tierIDs: []).outcome(for: key, current: Make.state(visibility: .paid, tiers: ["x", "y"])) == .noChange)
    }

    @Test func setFeatured() {
        #expect(target(.setFeatured(true), Make.state())?.featured == true)
        #expect(BulkOperation.setFeatured(false).outcome(for: key, current: Make.state()) == .noChange)
    }

    @Test func restoreOnlyWhenUnchangedSinceBatch() {
        let entry = BulkOperation.RestoreEntry(item: key, fields: [.tags], expected: Make.state(tags: ["a"]), restore: Make.state(tags: ["a", "b"]))
        let op = BulkOperation.restore([entry])
        // Still as the batch left it → restore; other fields untouched.
        let result = target(op, Make.state(tags: ["a"], featured: true))
        #expect(result?.tags.map(\.slug) == ["a", "b"])
        #expect(result?.featured == true)
        // Changed since → conflict.
        guard case .conflict = op.outcome(for: key, current: Make.state(tags: ["a", "c"])) else {
            Issue.record("expected conflict"); return
        }
        // Items not in the undo are left alone.
        #expect(op.outcome(for: .post("other"), current: Make.state()) == .noChange)
    }

    @Test func plannerSplitsChangesAndNoOps() {
        let items = [Make.post("1", tags: ["a"]), Make.post("2", tags: ["b"])].map(item)
        let plan = Planner.plan(.removeTags([Make.ref("a")]), items: items)
        #expect(plan.changes.map(\.item.id) == ["1"])
        #expect(plan.unchanged.map(\.id) == ["2"])
        #expect(plan.changes.first?.changedFields == [.tags])
        #expect(plan.title == "Remove “A”")
    }

    @Test func slugApproximation() {
        #expect(Slug.make("Hello World") == "hello-world")
        #expect(Slug.make("#Internal Note") == "hash-internal-note")
        #expect(Slug.make("  Café & Bar!! ") == "cafe-bar")
    }

    func item(_ post: Post) -> ContentItem {
        let store = try! SiteStore.inMemory()
        try! store.upsert([post], kind: .post)
        return try! store.item(id: post.id)!
    }
}
