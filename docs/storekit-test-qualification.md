# Native StoreKit qualification

`NuxieSDKStoreKitTests` is the launch-qualification suite for Nuxie's real
StoreKit 2 checkout, restore, transaction-observation, and finishing paths. It
uses the checked-in
`Tests/NuxieStoreKitTests/Fixtures/NuxieNativeCommerce.storekit` catalog and a
dedicated empty application host. No production app target bundles the local
catalog.

The test target loads the catalog programmatically with `SKTestSession`. Keep
the StoreKit configuration for other schemes set to `None`; selecting the
fixture on a production or example-app scheme would replace App Store product
resolution during that run.

## Requirements

- Xcode 26.6 or newer. The suite uses the typed StoreKitTest failure APIs and
  `SKTestSession.buyProduct(identifier:options:)` inspected from that SDK.
- An iOS 17 or newer Simulator runtime whose StoreKitTest daemon is compatible
  with the selected Xcode build.
- The pinned Nuxie runtime staged with `make fetch-runtime-xcframework`.

Run the fail-closed qualification command:

```bash
make test-storekit
```

To select a specific Simulator, use its UDID rather than a mutable device name:

```bash
xcrun simctl list devices available
make test-storekit \
  TEST_DESTINATION='platform=iOS Simulator,id=SIMULATOR_UDID'
```

Each test calls `resetToDefaultState()`, clears transactions, disables dialogs,
and clears every simulated StoreKit error it uses. Teardown finishes any
remaining verified transactions and clears the session again. A manual
Simulator erase should therefore be exceptional. It deletes all data in that
Simulator:

```bash
xcrun simctl shutdown SIMULATOR_UDID
xcrun simctl erase SIMULATOR_UDID
```

For Xcode, run `make generate`, select the `NuxieSDKStoreKitTests` scheme and an
iOS Simulator, then use Product > Test. The generated project is intentionally
derived from `project.yml` and is not committed.

## Covered behavior

| Boundary | Deterministic assertion |
| --- | --- |
| Successful native purchase | A real `Product.purchase` returns verified JWS evidence and its finish closure retires `Transaction.unfinished`. |
| Cancellation | A typed StoreKitTest `StoreKitError.userCancelled` produces Nuxie's cancelled outcome and no transaction. |
| Pending purchase | Ask to Buy returns pending; explicit approval publishes the real unfinished transaction. |
| Restore | A StoreKitTest non-consumable is found through `AppStore.sync` and `Transaction.currentEntitlements`. |
| Revocation | Refunding the non-consumable removes restore/ownership and permits a new purchase. |
| Full mode | `TransactionService` records finishing ownership and finishes the verified native transaction. |
| Observer mode | The same service records no finishing ownership and leaves the transaction unfinished. |
| Unfinished recovery | A transaction left by observer mode is found by a fresh real `TransactionObserver`, synced once, and finished after switching to full mode. |
| Provider coexistence | A signed-provider delegate purchases once; Nuxie's observer neither submits nor finishes the provider-owned transaction. |

The suite uses revocation rather than subscription renewal because the required
acceptance boundary is renewal *or* revocation. The fixture deliberately stays
small and contains no subscription product. Cancellation and Ask to Buy use
StoreKitTest's deterministic controls rather than attempting to automate Apple
system sheets.

## StoreKitTest daemon compatibility

`SKTestSession` can initialize while its Simulator daemon is unusable. In that
state `session.storefront` is empty, product lookup returns an empty catalog,
and direct test purchases fail with `StoreKitError.notEntitled`. Treating that
as "product not found" obscures the infrastructure failure.

On the qualification machine, Xcode 26.6 (17F113) exhibited this Apple runtime
failure with the installed iOS 26.3, 26.4, and 26.5 Simulators. Tests detect the
empty storefront before exercising SDK behavior. `make test-storekit` sets
`NUXIE_STOREKIT_REQUIRE_AVAILABLE=1`, so the gate fails instead of going green
with skipped tests. The Xcode scheme alone reports explicit skips to keep the
diagnostic readable.

To compile the complete suite while investigating a broken runtime, without
claiming qualification, run:

```bash
make test-storekit STOREKIT_REQUIRE_AVAILABLE=0
```

Install or select a compatible Simulator runtime, erase that Simulator once,
and rerun the default fail-closed command.

The trusted macOS workflow contains the same fail-closed command and uploads
`StoreKitTestResults.xcresult` on failure. It is not active for this change yet:
`.github/workflows/test.yml` invokes that reusable workflow at the fixed commit
`28664a30b357298e04242e93773f8c49088fe0e7`. After this change lands, a trusted
maintainer must advance that pin to a commit containing the StoreKit step.
Until then, neither PR nor main CI executes this qualification; use the local
Make target and do not treat the ordinary unit-test job as StoreKit coverage.
