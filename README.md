# Atelier (working name)

A native macOS app for bulk content management on Ghost CMS sites:
filter posts and pages precisely, preview changes, apply them, undo them.

See [`docs/MVP.md`](docs/MVP.md) for scope, decisions and architecture.

## Layout

```
Packages/GhostKit   Ghost Admin API client (Swift package, builds on macOS and Linux)
Packages/AppCore    Local store (SQLite/GRDB), sync, filters, bulk operations, change log, undo
tools/ghost-dev     Docker Ghost 6 for integration tests
tools/swift-dev     Docker image with Swift + SQLite for running tests on Linux
docs/               Plan and API notes
```

The Xcode app target is created on a Mac and links these packages.

## Development

```sh
# Unit tests (on a Mac with Xcode, or any machine with Swift 6)
swift test --package-path Packages/GhostKit

# Local Ghost 6 for integration tests (writes tools/ghost-dev/.env)
tools/ghost-dev/up.sh

# API behaviour checks against it
python3 tools/ghost-dev/api_check.py

# Unit + live tests against it
set -a; . tools/ghost-dev/.env; set +a
swift test --package-path Packages/GhostKit
```

Without a local Swift toolchain, the tests run in Docker:

```sh
docker build -t atelier-swift tools/swift-dev
docker run --rm --network host --env-file tools/ghost-dev/.env \
  -v "$PWD":/src -w /src/Packages/AppCore atelier-swift swift test
```

Live tests (`LiveGhostTests`, `LiveSessionTests`) run only when `GHOST_URL` and
`GHOST_ADMIN_KEY` are set; they edit `seed`-tagged posts and clean up after themselves.
