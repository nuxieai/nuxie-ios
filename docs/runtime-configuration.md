# Configuration lifecycle

`NuxieConfiguration` is a setup builder. `NuxieSDK.setup(with:)` snapshots its
values, so mutating the builder after setup does not partially reconfigure a
running SDK.

## Setup-only values

These values are fixed until `shutdown()` followed by a new `setup(with:)`:

- API key and environment (`.production` or `.development`)
- logging and redaction policy
- Test Store enablement
- `beforeSend`

Application lifecycle events are always captured. To exclude one, return
`nil` for it from `beforeSend` before setup.

## Runtime controls

The supported live settings have explicit propagation semantics:

- `try await NuxieSDK.shared.setLocaleIdentifier(...)` changes the locale,
  fetches a new profile immediately, and synchronizes feature state. It
  completes with `Void`.
- `try NuxieSDK.shared.setPurchaseDelegate(...)` changes the delegate used by
  subsequent purchase and restore calls.
- `try NuxieSDK.shared.setPurchaseHandlingMode(...)` changes whether subsequent
  observed StoreKit transactions are finished by Nuxie.

The locale, purchase delegate, and purchase handling mode supplied on the
configuration builder become the initial runtime values. Later mutation of the
builder is intentionally ignored.
