# Migrating to the supported facade API

The SDK's pre-1.0 public surface now matches its documented integration
contract. Applications should use `NuxieSDK.shared` and the types in its
method signatures. The following implementation seams are no longer exported:

- HTTP transports, request/response DTOs, and `NuxieApi`
- event, profile, segment, identity, session, feature, and journey services
- SQLite/event stores, disk caches, date/sleep providers, and query adapters
- IR evaluators and mutable journey persistence/resume state
- StoreKit product/transaction implementation services
- gzip helpers and other implementation utilities

If application code used one of these types for testing, replace it with a
test double around the application's own Nuxie-facing abstraction.
`refreshProfile()` now refreshes SDK state without returning the internal
profile response; release descriptors, segments, facts, mailbox entries,
experiment assignments, and feature wire values are consumed by the SDK
internally.

The supported facade and its semantics are enumerated in
`docs/sdk-api-surface.md`. The exact exported declaration sets are pinned for
macOS and iOS in `api/public-api.txt` and `api/public-api-ios.txt`.
