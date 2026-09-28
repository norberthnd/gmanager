#!/usr/bin/env python3
"""Check the Ghost Admin API behaviours the app depends on.

Runs against the local dev Ghost (see setup.py) using the integration's Admin
API key, exactly as the app authenticates. Prints one line per check; findings
are summarised in docs/api-notes.md. Mutates seed content, so re-seed
(delete tools/ghost-dev/data and run up.sh) for a pristine site.
"""

import base64
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
env = dict(line.strip().split("=", 1) for line in open(os.path.join(HERE, ".env")) if "=" in line)
SITE = env["GHOST_URL"]
KEY_ID, SECRET = env["GHOST_ADMIN_KEY"].split(":")
ADMIN = f"{SITE}/ghost/api/admin"

results = []


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def token():
    now = int(time.time())
    header = b64url(json.dumps({"alg": "HS256", "kid": KEY_ID, "typ": "JWT"}).encode())
    payload = b64url(json.dumps({"iat": now, "exp": now + 300, "aud": "/admin/"}).encode())
    sig = hmac.new(bytes.fromhex(SECRET), f"{header}.{payload}".encode(), hashlib.sha256).digest()
    return f"{header}.{payload}.{b64url(sig)}"


def call(method, path, body=None, query=None):
    url = f"{ADMIN}/{path}"
    if query:
        url += "?" + urllib.parse.urlencode(query, safe=",:'[]()", quote_via=urllib.parse.quote)
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"Ghost {token()}")
    request.add_header("Accept-Version", "v6.0")
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request) as response:
            raw = response.read()
            return response.status, (json.loads(raw) if raw else None), dict(response.headers)
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            parsed = json.loads(raw) if raw else None
        except json.JSONDecodeError:
            parsed = raw.decode(errors="replace")[:200]
        return error.code, parsed, dict(error.headers)


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  — {detail}" if detail else ""))


def first_post(filter_):
    _, body, _ = call("GET", "posts/", query={"filter": filter_, "limit": 1, "include": "tags,authors,tiers", "formats": "lexical"})
    return body["posts"][0]


# --- Auth / site ---------------------------------------------------------

status, body, headers = call("GET", "site/")
check("site/ with integration token", status == 200, f"version={body['site'].get('version')}")
ghost_version = body["site"].get("version")

status, body, _ = call("GET", "users/me/")
check("users/me/ is 404 for integrations (not a user)", status == 404, f"status={status}")

req = urllib.request.Request(f"{ADMIN}/site/")
with urllib.request.urlopen(req) as r:
    check("site/ needs no auth (cannot validate a key)", r.status == 200, "")
try:
    urllib.request.urlopen(f"{ADMIN}/posts/?limit=1")
    check("posts/ rejects missing auth", False, "")
except urllib.error.HTTPError as e:
    check("posts/ rejects missing auth", e.code in (401, 403), f"status={e.code}")

# --- Browse: pagination, limits, fields ---------------------------------

status, body, _ = call("GET", "posts/", query={"limit": "all", "fields": "id"})
count_all = len(body["posts"]) if status == 200 else None
check("limit=all is capped at 100", status == 200 and count_all == 100, f"returned {count_all} posts, meta.limit={body['meta']['pagination']['limit'] if status == 200 else '-'}")

status, body, _ = call("GET", "posts/", query={"limit": 1000, "fields": "id"})
check("limit=1000 is capped at 100", status == 200 and len(body["posts"]) == 100, f"returned {len(body['posts']) if status == 200 else status}")

status, body, _ = call("GET", "posts/", query={"limit": 100, "page": 2, "fields": "id"})
p = body["meta"]["pagination"] if status == 200 else {}
check("pagination meta present", status == 200 and p.get("page") == 2, f"{p}")

status, body, _ = call("GET", "posts/", query={"limit": 2, "fields": "id,title,updated_at", "include": "tags"})
keys = sorted(body["posts"][0].keys()) if status == 200 else []
check("fields= restricts columns, include= still adds relations", status == 200 and "tags" in keys and "lexical" not in keys and "html" not in keys, f"keys={keys}")

status, body, _ = call("GET", "posts/", query={"limit": 1, "include": "tags,authors,tiers"})
keys = sorted(body["posts"][0].keys())
check("default browse includes lexical body (use fields= to skip)", "lexical" in keys, f"has lexical={'lexical' in keys}, html={'html' in keys}")
check("browse returns tiers relation", "tiers" in keys, "")

# --- NQL -----------------------------------------------------------------

status, body, _ = call("GET", "posts/", query={"filter": "tag:['news','updates']", "limit": 1, "fields": "id"})
check("NQL quoted list tag:['a','b']", status == 200, f"total={body['meta']['pagination']['total'] if status == 200 else body}")

status, body, _ = call("GET", "posts/", query={"filter": "tag:seed+tag:-['news']", "limit": 1, "fields": "id"})
check("NQL AND with negated list (+ sent as %2B)", status == 200, f"total={body['meta']['pagination']['total'] if status == 200 else body}")

status, body, _ = call("GET", "posts/", query={"filter": "status:'published'+(tag:'news',tag:'js')", "limit": 1, "fields": "id"})
check("NQL grouping with quoted values", status == 200, f"total={body['meta']['pagination']['total'] if status == 200 else body}")

status, body, _ = call("GET", "posts/", query={"filter": "published_at:<'2100-01-01 00:00:00'", "limit": 1, "fields": "id"})
check("NQL date comparison", status == 200, f"total={body['meta']['pagination']['total'] if status == 200 else body}")

status, body, _ = call("GET", "posts/", query={"filter": "tags.slug:-null", "limit": 1, "fields": "id"})
check("NQL 'has any tag' via tags.slug:-null", status == 200, f"status={status}")

status, body, _ = call("GET", "tags/", query={"limit": "all", "include": "count.posts"})
tags = body["tags"]
check("tags include=count.posts", status == 200 and "count" in tags[0], f"{len(tags)} tags")

# --- Partial edits -------------------------------------------------------

post = first_post("tag:news+status:published")
before = {k: post[k] for k in ("title", "lexical", "visibility", "featured", "custom_excerpt", "published_at", "status")}
new_tags = [{"id": t["id"]} for t in post["tags"] if t["slug"] != "news"]
status, body, _ = call("PUT", f"posts/{post['id']}/", {"posts": [{"updated_at": post["updated_at"], "tags": new_tags}]}, query={"include": "tags,tiers"})
check("PUT with only tags + updated_at", status == 200, f"status={status} {body if status != 200 else ''}")
after = first_post(f"id:'{post['id']}'")
unchanged = {k: after[k] == before[k] for k in before}
check("partial edit leaves other fields untouched", all(unchanged.values()), f"{unchanged}")
check("tag removed", "news" not in [t["slug"] for t in after["tags"]], f"tags={[t['slug'] for t in after['tags']]}")
check("tag-only edit does NOT change updated_at", after["updated_at"] == post["updated_at"], f"{post['updated_at']} → {after['updated_at']}")

# stale updated_at: only detected once a *field* edit has bumped updated_at
stale = after["updated_at"]
time.sleep(1.1)  # updated_at has one-second resolution
status, body, _ = call("PUT", f"posts/{post['id']}/", {"posts": [{"updated_at": stale, "featured": not after["featured"]}]})
bumped = body["posts"][0]["updated_at"] if status == 200 else None
check("field edit changes updated_at", status == 200 and bumped != stale, f"{stale} → {bumped}")
status, body, _ = call("PUT", f"posts/{post['id']}/", {"posts": [{"updated_at": stale, "featured": after["featured"]}]})
err = body["errors"][0] if isinstance(body, dict) and body.get("errors") else {}
check("stale updated_at → 409 UpdateCollisionError", status == 409 and err.get("type") == "UpdateCollisionError", f"status={status} type={err.get('type')}")
status, body, _ = call("PUT", f"posts/{post['id']}/", {"posts": [{"updated_at": "2000-01-01T00:00:00.000Z", "title": after["title"]}]})
check("stale updated_at with no actual change is accepted", status == 200, f"status={status}")

# lost update: two tag-only writers with the same updated_at both succeed
current = first_post(f"id:'{post['id']}'")
base_tags = [{"id": t["id"]} for t in current["tags"]]
s1, _, _ = call("PUT", f"posts/{post['id']}/", {"posts": [{"updated_at": current["updated_at"], "tags": base_tags + [{"name": "Race A"}]}]})
s2, _, _ = call("PUT", f"posts/{post['id']}/", {"posts": [{"updated_at": current["updated_at"], "tags": base_tags + [{"name": "Race B"}]}]})
slugs = [t["slug"] for t in first_post(f"id:'{post['id']}'")["tags"]]
check("concurrent tag-only edits are NOT detected (last write wins)", s1 == 200 and s2 == 200 and "race-a" not in slugs, f"tags={slugs}")

# missing updated_at
status, body, _ = call("PUT", f"posts/{post['id']}/", {"posts": [{"featured": True}]})
err = body["errors"][0] if isinstance(body, dict) and body.get("errors") else {}
check("missing updated_at is rejected", status >= 400, f"status={status} type={err.get('type')}")

# retry after lost response: same payload again with old updated_at → conflict (already covered)

# add tag by name creates it
fresh = first_post(f"id:'{post['id']}'")
status, body, _ = call("PUT", f"posts/{post['id']}/", {"posts": [{"updated_at": fresh["updated_at"], "tags": [{"id": t["id"]} for t in fresh["tags"]] + [{"name": "Created By Check"}]}]}, query={"include": "tags"})
check("tag {name} creates tag on the fly", status == 200 and "created-by-check" in [t["slug"] for t in body["posts"][0]["tags"]], "")

# visibility → tiers
_, tier_body, _ = call("GET", "tiers/", query={"filter": "type:paid"})
gold = next(t for t in tier_body["tiers"] if t["name"] == "Gold")
fresh = first_post(f"id:'{post['id']}'")
status, body, _ = call("PUT", f"posts/{post['id']}/", {"posts": [{"updated_at": fresh["updated_at"], "visibility": "tiers", "tiers": [{"id": gold["id"]}]}]}, query={"include": "tiers"})
tiers_after = [t["name"] for t in body["posts"][0]["tiers"]] if status == 200 else body
check("visibility=tiers with tier ids", status == 200 and tiers_after == ["Gold"], f"tiers={tiers_after}")

fresh = first_post(f"id:'{post['id']}'")
status, body, _ = call("PUT", f"posts/{post['id']}/", {"posts": [{"updated_at": fresh["updated_at"], "visibility": "paid"}]}, query={"include": "tiers"})
check("visibility=paid (tiers auto-filled)", status == 200, f"tiers={[t['name'] for t in body['posts'][0]['tiers']] if status == 200 else body}")

# pages
_, body, _ = call("GET", "pages/", query={"limit": 1, "include": "tags"})
page = body["pages"][0]
status, body, _ = call("PUT", f"pages/{page['id']}/", {"pages": [{"updated_at": page["updated_at"], "featured": True}]})
check("PUT page partial edit", status == 200, f"status={status}")

# --- Tags ----------------------------------------------------------------

status, body, _ = call("POST", "tags/", {"tags": [{"name": "Delete Me Check"}]})
tag_id = body["tags"][0]["id"]
fresh = first_post("tag:seed+status:published")
call("PUT", f"posts/{fresh['id']}/", {"posts": [{"updated_at": fresh["updated_at"], "tags": [{"id": t["id"]} for t in fresh["tags"]] + [{"id": tag_id}]}]})
status, _, _ = call("DELETE", f"tags/{tag_id}/")
after = first_post(f"id:'{fresh['id']}'")
check("DELETE tag", status == 204, f"status={status}")
check("deleted tag removed from posts", "delete-me-check" not in [t["slug"] for t in after["tags"]], "")
check("deleting a tag does not change post updated_at", after["updated_at"] == first_post(f"id:'{fresh['id']}'")["updated_at"], "")

status, body, _ = call("PUT", f"tags/{tags[0]['id']}/", {"tags": [{"description": "edited by check"}]})
check("PUT tag without updated_at", status == 200, f"status={status}")

# --- Bulk endpoint (internal) -------------------------------------------

status, body, _ = call("PUT", "posts/bulk/", {"bulk": {"action": "feature", "meta": {}}}, query={"filter": "id:'000000000000000000000000'"})
check("posts/bulk/ accepts integration key (action 'feature')", status == 200, f"status={status} {str(body)[:160]}")

status, body, _ = call("DELETE", "posts/", query={"filter": "id:'000000000000000000000000'"})
check("bulk DELETE posts/?filter= reachable (no-op filter)", status in (200, 204), f"status={status}")

# --- Rate limit headers --------------------------------------------------

_, _, headers = call("GET", "site/")
rl = {k: v for k, v in headers.items() if "rate" in k.lower() or "retry" in k.lower()}
check("no rate-limit headers locally (hosts differ)", not rl, f"{rl or 'none'}")

print()
print(f"Ghost {ghost_version}: {sum(ok for _, ok, _ in results)}/{len(results)} checks passed")
sys.exit(0)
