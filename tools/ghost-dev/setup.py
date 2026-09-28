#!/usr/bin/env python3
"""Prepare a fresh local Ghost for testing.

Creates the owner account, a custom integration (writing its Admin API key to
.env) and a set of sample tags, tiers, posts and pages. Safe to re-run: steps
that are already done are skipped.

Uses only the Python standard library.
"""

import http.cookiejar
import json
import os
import sys
import time
import urllib.error
import urllib.request

SITE = os.environ.get("GHOST_URL", "http://localhost:2368")
ADMIN = f"{SITE}/ghost/api/admin"
EMAIL = "owner@example.com"
PASSWORD = "atelier-dev-password-1"
ENV_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")

cookies = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookies))


def call(method, path, body=None, expect_ok=True):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(f"{ADMIN}/{path}", data=data, method=method)
    request.add_header("Content-Type", "application/json")
    request.add_header("Accept-Version", "v6.0")
    request.add_header("Origin", SITE)  # Ghost requires Origin for session auth
    try:
        with opener.open(request) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        raw = error.read()
        if expect_ok:
            sys.exit(f"{method} {path} failed: {error.code} {raw.decode(errors='replace')}")
        return error.code, json.loads(raw) if raw else None


def wait_for_ghost():
    for _ in range(90):
        try:
            with urllib.request.urlopen(f"{ADMIN}/site/") as response:
                if response.status == 200:
                    return
        except Exception:
            pass
        time.sleep(2)
    sys.exit("Ghost did not become ready")


def setup_owner():
    _, status = call("GET", "authentication/setup/")
    if status["setup"][0]["status"]:
        print("owner: already set up")
        return
    call("POST", "authentication/setup/", {"setup": [{
        "name": "Dev Owner", "email": EMAIL, "password": PASSWORD, "blogTitle": "Atelier Dev",
    }]})
    print("owner: created")


def login():
    call("POST", "session/", {"username": EMAIL, "password": PASSWORD})


def ensure_integration():
    _, body = call("GET", "integrations/?include=api_keys")
    integration = next((i for i in body["integrations"] if i["name"] == "Atelier Dev"), None)
    if integration is None:
        _, body = call("POST", "integrations/?include=api_keys", {"integrations": [{"name": "Atelier Dev"}]})
        integration = body["integrations"][0]
        print("integration: created")
    admin_key = next(k for k in integration["api_keys"] if k["type"] == "admin")
    key = f"{admin_key['id']}:{admin_key['secret']}"
    with open(ENV_FILE, "w") as f:
        f.write(f"GHOST_URL={SITE}\nGHOST_ADMIN_KEY={key}\n")
    print(f"integration: key written to {ENV_FILE}")


def ensure_tiers():
    _, body = call("GET", "tiers/?limit=all")
    existing = {t["name"] for t in body["tiers"]}
    for name, price in [("Gold", 500), ("Silver", 300)]:
        if name in existing:
            continue
        call("POST", "tiers/", {"tiers": [{
            "name": name, "currency": "usd", "monthly_price": price, "yearly_price": price * 10,
            "visibility": "public",
        }]})
        print(f"tier: {name} created")


def seed_content():
    _, body = call("GET", "posts/?limit=1&filter=tag:seed")
    if body["posts"]:
        print("content: already seeded")
        return
    tags = ["News", "Updates", "Tutorials", "Javascript", "JS", "javascript-2", "#internal-note", "Archive"]
    visibilities = ["public", "members", "paid"]
    for i in range(1, 121):
        post_tags = [{"name": "seed"}, {"name": tags[i % len(tags)]}]
        if i % 3 == 0:
            post_tags.append({"name": tags[(i + 3) % len(tags)]})
        call("POST", "posts/", {"posts": [{
            "title": f"Sample post {i}",
            "status": "published" if i % 5 else "draft",
            "visibility": visibilities[i % len(visibilities)],
            "featured": i % 10 == 0,
            "tags": post_tags,
            "lexical": json.dumps({"root": {"children": [{"children": [{"detail": 0, "format": 0, "mode": "normal", "style": "", "text": f"Body of post {i}.", "type": "extended-text", "version": 1}], "direction": "ltr", "format": "", "indent": 0, "type": "paragraph", "version": 1}], "direction": "ltr", "format": "", "indent": 0, "type": "root", "version": 1}}),
        }]})
    for i in range(1, 11):
        call("POST", "pages/", {"pages": [{
            "title": f"Sample page {i}",
            "status": "published",
            "tags": [{"name": "seed"}, {"name": tags[i % len(tags)]}],
        }]})
    call("POST", "tags/", {"tags": [{"name": "Unused tag"}]}, expect_ok=False)
    print("content: 120 posts, 10 pages seeded")


if __name__ == "__main__":
    wait_for_ghost()
    setup_owner()
    login()
    ensure_integration()
    ensure_tiers()
    seed_content()
