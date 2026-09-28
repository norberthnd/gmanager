# CLAUDE.md

Native macOS app (working name **Atelier**) for bulk content management on
Ghost CMS 6+ sites: filter posts/pages precisely, preview a change, apply it,
undo it. Commercial, sold directly (not Mac App Store). "Ghost" must not
appear in the product name.

Read first: `docs/MVP.md` (scope, decisions, architecture) and
`docs/api-notes.md` (verified Ghost Admin API behaviour).

## Layout

- `Packages/GhostKit` — Ghost Admin API client (JWT auth, NQL builder, request
  limiter + retries, models). No UI; builds on macOS and Linux.
- `Packages/AppCore` — per-site SQLite store (GRDB), `SyncEngine`,
  `ContentQuery` (local filters), `BulkOperation`/`Planner`, `BatchExecutor`,
  change log + undo, `SiteSession`, `SiteCatalog`, `SiteConnector`,
  `KeychainCredentialStore`.
- `tools/ghost-dev` — Docker Ghost 6 + MySQL, `setup.py` (owner, integration
  key → `.env`, seed content), `api_check.py` (36 API behaviour checks).
- `tools/swift-dev` — Docker image for running the Swift tests on Linux.
- The macOS app target does not exist yet (next task, below).

## Commands

```sh
swift test --package-path Packages/GhostKit
swift test --package-path Packages/AppCore

# Live tests need a Ghost: start it, then export its key
tools/ghost-dev/up.sh
set -a; . tools/ghost-dev/.env; set +a
swift test --package-path Packages/AppCore   # now includes LiveSessionTests
python3 tools/ghost-dev/api_check.py
```

Live tests only touch `seed`-tagged posts and clean up after themselves.

## Rules that matter

- **Tag-only edits don't bump `updated_at`, so Ghost can't detect conflicting
  tag edits.** Never write tags from a stale read: `BatchExecutor` re-reads
  each post and applies the operation to its fresh state. Keep it that way.
- Operations are *intents* (`BulkOperation`), re-applied at execution time;
  every batch is logged with actual before/after; undo only restores items
  unchanged since the batch.
- Send only changed fields (`PostPatch`). Reference tags by id when known to
  exist, otherwise slug + name (an unknown id fails the whole edit).
- Never send `DELETE posts/` or `DELETE pages/` without an id (bulk delete by filter).
- Page size is capped at 100; browse returns bodies unless `fields=` is set.
- `SiteSession` is per site; views get a session, never globals (multi-site later).
- Keys live in the Keychain only; no telemetry; content never leaves the Mac.
- Swift 6 language mode, macOS 14+. Prefer system SwiftUI styles and controls.

## Next task: the macOS app (milestone 3)

- Create the app target. Suggested: XcodeGen (`brew install xcodegen`) with a
  committed `project.yml` so the project is reproducible from the CLI
  (`xcodegen generate && xcodebuild -scheme Atelier build`). Bundle id
  placeholder: `com.example.atelier`.
- Screens: connect site (URL + Admin API key via `SiteConnector`), sidebar
  (site, Posts/Pages, saved filters, Tags, History), `Table` of items with
  multi-select + filter bar (`ContentQuery`), bulk action menu → preview sheet
  (`Plan`: before/after per item) → progress (`BatchRun` events,
  pause/cancel) → results; History (batches, undo); Tags screen (counts,
  unused, rename, merge).
- Use `@Observable` view models that wrap a `SiteSession`.
