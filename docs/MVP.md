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

A `BulkOperation` is an *intent* ("remove tag X", "set access to Gold"), not a
set of final values. `Planner` applies it to the selected items' local state to
produce a `Plan` (per item: before/after) for the preview.

`BatchExecutor` then, per item, with bounded parallelism:
re-reads the post → applies the operation to its **fresh** state → sends only the
changed fields with the fresh `updated_at` → stores the server's response →
records actual before/after in the change log (`applied`, or `adjusted` if the
post had changed since the preview). 409 conflicts are re-read and retried.
Runs can be paused, resumed and cancelled; in-flight writes always finish.

Undo is a `restore` operation built from the log: each item's touched fields go
back to their previous values, **only if** they still equal what the batch
wrote; otherwise that item is reported as a conflict and left alone.

Tag merge = replace A→B on every item, then delete A once the server confirms
nothing uses it. Undo recreates A by slug + name.

### Ghost API facts that shape the design

Verified against Ghost 6.65 — details in [`api-notes.md`](api-notes.md).

- Admin API auth: HS256 JWT from the `id:secret` key, 5-minute expiry, `aud: /admin/`.
  Validate a key with an authenticated request (`/site/` needs no auth; `/users/me/` is 404 for integrations).
- `PUT /posts/{id}/` requires `updated_at`; a stale value after a *field* change → 409 `UpdateCollisionError`.
- **Tag-only edits don't bump `updated_at`, so they are not conflict-protected.** Tag operations
  re-read each post right before writing and compute the new list from the fresh tags.
- Page size is capped at 100; browse includes bodies unless `fields=` is set.
- `/posts/bulk/` works with an integration key but has no remove-tag action and no per-post
  conflict checks — not used in v0.1.
- Rate limits vary by host — start at ~3 concurrent requests, back off on 429/5xx.

## Milestones

0. ✅ **API check** — Docker Ghost 6; confirm partial edits, conflict behaviour,
   pagination/field selection, bulk endpoint with integration key → `docs/api-notes.md`.
1. ✅ **GhostKit** — client + models + tests (unit and integration).
2. ✅ **AppCore** — store, sync, filters, operations, change log/undo, tested end-to-end.
3. **App UI** — Xcode target on a Mac; views built on AppCore.
4. **Beta readiness** — licensing, Sparkle, notarization, icon, name, landing page.
