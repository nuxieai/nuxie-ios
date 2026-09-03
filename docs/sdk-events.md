# SDK execution event guidance

The canonical machine contract is [`fixtures/events/catalog.json`](../fixtures/events/catalog.json); [`docs/events-catalog.md`](events-catalog.md) explains its delivery paths. Applications must not emit names beginning with `$`.

## Journey reports

The SDK runs only the Journey release system. A profile supplies an authenticated fact table, armed releases, and signed release envelopes. The runtime does not reconstruct or synchronize a second journey model.

A started run durably reports `$journey_leg_started`. It reports `$journey_leg_completed` before retiring the run, with its outcome and declared buffered outputs. Both reports use stable ids, so storage retries and process restarts cannot duplicate them. Report queue time is the local completion boundary; future continuation arrives as another armed release in a later profile.

Answers produced by response controls stay in the Journey journal until completion. The controls themselves are renderer inputs and never enter EventLog. Screens and milestones emit ordinary observable facts carrying Journey and leg attribution.

## Experiments

The server supplies durable assignments in the profile fact table. Assignment does not mean exposure. `$experiment_exposure` is captured only after the selected variant reaches a visible screen.

Every experiment action has an authored `fallbackVariantId`. If an assignment is absent, malformed, or points to a variant unavailable in the authenticated release, the SDK runs that authored fallback. It still presents the Experience and emits one exposure for the variant actually shown, with `assignment_source: "fallback"` and `is_holdout: false`.

## Purchases

Checkout, transaction updates, startup recovery, and deferred verified outcomes share one transaction committer. It deduplicates by verified transaction identity, so one purchase produces one `$purchase_completed` event even when several StoreKit entry points surface it. The event's `source` records the winning producer. The portable contract is `fixtures/purchases/outcome-commit.json`.

For atomic purchase-backed feature use, transport errors retain scoped receipt evidence and retry with the same command identity. Before evidence is retired, the SDK durably captures `$purchase_synced`. A failed capture retains the evidence for retry; replay acknowledges the same stable id without duplicate delivery. See `fixtures/events/atomic-purchase-sync.json`.

## Product and permission routing

`$products_unavailable` is captured before renderer attachment when required live products cannot be resolved. It is both a Journey routing input and a curated public activity. The authenticated release decides the next branch; an absent route completes the leg with the product-unavailable outcome.

Permission results requested by a visible Journey are captured under that Journey's identity and release attribution before routing. Unscoped host results use ordinary EventLog capture. Both paths obey `beforeSend`.

## Fact evaluation and offline behavior

Entry conditions read only the authenticated profile fact table plus covered local event history. Membership keys are opaque booleans. Missing or incomplete facts remain unknown through negation and fail closed for admission. The SDK does not evaluate server segment definitions.

A live run pins its authenticated release and journal. Offline execution can continue through local controls and effects. Only an explicit park point resumes after process death; an active unparked run is abandoned and reports its buffered outputs. No claim, mailbox, ownership-transfer, checkpoint-event, or response-session protocol exists in the SDK.

See [`fixtures/`](../fixtures/README.md) for portable Journey, event, feature, and purchase vectors.
