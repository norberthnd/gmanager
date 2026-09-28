# MVP plan

Working name: **Atelier** (placeholder — the shipped name is only the display
name in `Info.plist`; "Ghost" will not appear in the product name).

A native macOS app for managing content on a Ghost CMS site in bulk:
find exactly the right posts, preview what will change, apply it, undo it.

## Decisions

| Topic | Decision |
|---|---|
| Platform | macOS 14+, SwiftUI, built with the latest Xcode/SDK |
| Ghost | v6+, any host (Ghost(Pro), self-hosted, managed hosts) |
| Sites | One site in the UI for v0.1; architecture is multi-site from day one |
| Distribution | Direct download: signed + notarized, Sparkle updates, Paddle or Lemon Squeezy licensing |
| Business | Commercial, private repo |
| Bundle ID | `com.example.atelier` placeholder — pick a neutral, permanent one before first release |
| Privacy | Content and keys never leave the Mac; no telemetry |

## v0.1 scope

1. **Connect a site** — API URL + Admin API key from a Ghost custom integration.
   Validate via `/site/` and `/users/me/`; key in Keychain; show name, icon, Ghost version.
2. **Sync** — posts, pages, tags, tiers, authors, newsletters into a per-site SQLite
   store (no post bodies). Paginated first sync, incremental by `updated_at`,
   full refresh detects deletions.
3. **Browse** — posts and pages in a sortable, configurable `Table`, search field.
4. **Filters** — status, visibility/tier, author, featured, date ranges,
   tags (any / all / none / untagged), title/slug text; saved filters in the sidebar.
5. **Bulk actions** (all via preview → apply → log):
   add tags, remove tags, replace tag A→B, set visibility/tiers, set/unset featured.
6. **Tags screen** — post counts, unused tags, rename, merge, delete unused.
7. **Change log** — per batch, per post before/after; undo any batch (with preview).
8. **Robust execution** — per-post progress, pause/cancel, conflict retry
   (re-fetch, re-check the change still applies, re-apply), failures list.

### Not in v0.1

Multi-site UI, post-body editing / find & replace, SEO fields, content health
checks, scheduling calendar, members, licensing, auto-update.
SEO fields and health checks are the natural v0.2 and reuse the same engine.

## Architecture

```
App (Xcode target, SwiftUI)              ← created on a Mac
Packages/
  GhostKit   Ghost Admin API client: token signing, HTTP, request limits +
             backoff, typed models, NQL filter builder. No UI; builds on Linux.
  AppCore    Per-site store (GRDB/SQLite), SyncEngine, local query builder,
             Operation → Plan → Executor → ChangeLog / Undo.
tools/ghost-dev  Docker Ghost 6 for integration tests and API checks.
```

### Multi-site readiness

- `Site` is a first-class model; each site has its own SQLite file plus an app-wide site list.
- A `SiteSession` owns that site's client, store, sync engine and executor.
  Views receive a session, never a global.
- Keychain entries are keyed by site ID.

### Operations engine

An `Operation` turns (selected items + parameters) into a `Plan`: a list of
per-item changes, each carrying the item's `updated_at`, fields before and
fields after. Preview renders the plan; the executor applies it with bounded
concurrency; the change log stores it; undo builds and runs the inverse plan.

### Ghost API facts that shape the design

- Admin API auth: HS256 JWT from the `id:secret` key, 5-minute expiry, `aud: /admin/`.
- `PUT /posts/{id}/` requires the current `updated_at`; stale values are rejected
  (conflict) → re-fetch and retry.
- Tags on an edit replace the whole list — tag operations are read-modify-write per post.
- `/posts/bulk/` is used by Ghost Admin but not publicly documented — optional speed-up only.
- Rate limits vary by host — start at ~3 concurrent requests, back off on 429/5xx.

## Milestones

0. **API check** — Docker Ghost 6; confirm partial edits, conflict behaviour,
   pagination/field selection, bulk endpoint with integration key → `docs/api-notes.md`.
1. **GhostKit** — client + models + tests (unit and integration).
2. **AppCore** — store, sync, filters, operations, change log/undo, tested end-to-end.
3. **App UI** — Xcode target on a Mac; views built on AppCore.
4. **Beta readiness** — licensing, Sparkle, notarization, icon, name, landing page.
