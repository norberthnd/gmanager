# Atelier (working name)

A native macOS app for bulk content management on Ghost CMS sites:
filter posts and pages precisely, preview changes, apply them, undo them.

See [`docs/MVP.md`](docs/MVP.md) for scope, decisions and architecture.

## Layout

```
Packages/GhostKit   Ghost Admin API client (Swift package, builds on macOS and Linux)
Packages/AppCore    Local store, sync, operations engine (added in milestone 2)
tools/ghost-dev     Docker Ghost 6 for integration tests
docs/               Plan and API notes
```

The Xcode app target is created on a Mac and links these packages.

## Development

```sh
# Unit tests
swift test --package-path Packages/GhostKit

# Local Ghost 6 for integration tests
tools/ghost-dev/up.sh
```
