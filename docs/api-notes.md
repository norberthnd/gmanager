# Ghost Admin API notes

Verified against **Ghost 6.65** (Docker `ghost:6`, MySQL 8) on 2026-09-28 using a
custom integration's Admin API key, exactly as the app authenticates.

Reproduce: `tools/ghost-dev/up.sh`, then `python3 tools/ghost-dev/api_check.py`
(36 checks, each asserting the behaviour below) and the live Swift tests:
`docker run … --env-file tools/ghost-dev/.env swift:latest swift test` (see README).

## Findings that change the design

### 1. Tag-only edits bypass conflict detection ⚠️

- `PUT /posts/{id}/` with only `tags` (a relation) **does not change `updated_at`**.
- Ghost's collision check compares the submitted `updated_at` with the stored one,
  so two writers who read the same post can both change its tags: **both get 200
  and the last write wins**. Verified: writer A adds `race-a`, writer B (same
  `updated_at`) adds `race-b` → post ends with `race-b` only.
- Field edits (`featured`, `visibility`, `title`, …) do bump `updated_at`, and a
  later write with the old value gets **409 `UpdateCollisionError`**.
- A stale `updated_at` is accepted if the request changes nothing.
- `updated_at` has **one-second resolution**.

**Design consequence:** tag operations must be read-modify-write *per post, at
execution time*: re-read the post (`GET posts/{id}/?include=tags`) immediately
before the `PUT`, recompute the tag list from the fresh tags (e.g. "fresh minus
X"), not from the plan-time snapshot, and compare fresh tags with the plan's
"before" tags; if they differ, treat it as a conflict and show it in the
results. The remaining race window is the few ms between GET and PUT. The change
log records the fresh "before" value, so undo is accurate.

### 2. Page size is capped at 100

`limit=all` and `limit=1000` both return 100 items. Sync must paginate (`meta.pagination.next`).

### 3. Browse returns post bodies by default

Admin browse includes `lexical` unless `fields=` is given. `fields=` works
together with `include=tags,authors,tiers`. Sync uses `GhostClient.postSyncFields`.

### 4. Validating a key needs an authenticated endpoint

- `GET /site/` answers **without auth**, so it cannot validate a key.
- `GET /users/me/` is **404 for integrations** (they are not users).
- `GhostClient.verifyAccess()` uses `GET posts/?limit=1&fields=id` (403 without auth).

## Other confirmed behaviour

| Area | Behaviour |
|---|---|
| Auth | HS256 JWT, `kid` = key id, `aud: /admin/`, 5-min expiry; `Accept-Version: v6.0` accepted |
| Integration key | The integrations API returns the full `id:secret` in the admin key's `secret` field |
| Partial edits | `PUT` with only `updated_at` + changed fields leaves title, body, status, dates, visibility untouched |
| `updated_at` missing | 422 `ValidationError` |
| Tags by name | `tags: [{"name": "New"}]` creates the tag on the fly |
| Visibility | `visibility: "tiers"` + `tiers: [{id}]` works; `visibility: "paid"` auto-fills all paid tiers (response also lists the free tier) |
| Pages | Same edit semantics as posts (`pages/{id}/`, root key `pages`) |
| Tag delete | `DELETE tags/{id}/` → 204, removes it from all posts, does **not** change their `updated_at` |
| Tag edit | `PUT tags/{id}/` works without `updated_at` (no conflict protection) |
| Tag counts | `GET tags/?include=count.posts` |
| NQL | Quoted values and lists (`tag:['a','b']`, `tag:-['a']`), groups `(a,b)+c`, dates `published_at:<'YYYY-MM-DD HH:mm:ss'`, `tags.slug:-null` all work; `+` must be sent as `%2B` |
| Rate limits | No rate-limit headers on local Ghost; hosted Ghost(Pro) and proxies differ → rely on 429/`Retry-After` handling |

## Internal bulk endpoints (undocumented)

Reachable with an integration key:

- `PUT posts/bulk/?filter=…` with `{"bulk": {"action": …, "meta": {…}}}`.
  Accepted actions: `feature`, `unfeature`, `unpublish`, `addTag` (needs `meta.tags`),
  `access` (needs `meta.visibility`/`tiers`). Rejected as unsupported: `removeTag`,
  `publish`, `delete`. **There is no remove-tag action.**
  Response: `{"bulk": {"meta": {"stats": {"successful", "unsuccessful"}, …}}}`.
- `DELETE posts/?filter=…` **bulk-deletes every matching post.**

Decision: v0.1 does not use the bulk endpoints. They skip per-post conflict
checks and give no per-post before/after, which the preview/undo design needs;
per-post `PUT` at ~3 concurrent requests is fast enough for thousands of posts.
Revisit as an opt-in speed-up for field-only actions later.

**Safety rule:** GhostKit must never send `DELETE posts/` or `DELETE pages/`
without an id; a filter mistake there deletes content irrecoverably.

## Not yet verified

- Editing posts that were already sent as email (needs a mail setup).
- Rate-limit behaviour on Ghost(Pro) and managed hosts (needs a real hosted site).
- Very large sites (thousands of posts): sync timing and memory.
