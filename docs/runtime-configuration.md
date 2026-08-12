# Configuration lifecycle

`NuxieConfiguration` is a setup builder. `NuxieSDK.setup(with:)` snapshots its
values, so mutating the builder after setup does not partially reconfigure a
running SDK.

## Setup-only values

These values are fixed until `shutdown()` followed by a new `setup(with:)`:

- API key, environment, API endpoint, and URL session
- logging and redaction policy
- retry, batching, flushing, and queue limits
- storage and package asset locations
- feature cache TTL
- automatic application lifecycle tracking
- `beforeSend`

## Runtime controls

The supported live settings have explicit propagation semantics:

- `await NuxieSDK.shared.setLocaleIdentifier(...)` changes the locale, fetches
  a new profile immediately, and synchronizes feature state.
- `try NuxieSDK.shared.setPurchaseDelegate(...)` changes the delegate used by
  subsequent purchase and restore calls.
- `try NuxieSDK.shared.setPurchaseHandlingMode(...)` changes whether subsequent
  observed StoreKit transactions are finished by Nuxie.

The locale, purchase delegate, and purchase handling mode supplied on the
configuration builder become the initial runtime values. Later mutation of the
builder is intentionally ignored.
