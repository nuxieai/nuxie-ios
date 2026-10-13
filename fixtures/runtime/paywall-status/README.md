# Published paywall operation fixture

The parent repository's `tests/fixtures/paywall-status/generate.mts` publishes the purchase and restore programs through `publishJourneyRoute` and `compileExperiencePlanes`. The purchase follows the purchase-restore recipe, with an empty, omitted, or authored failure program. The authored recovery waits on the paywall. Success dismisses it.

`publish-scene.mts` publishes `snapshot.json` with the real Editor publisher. The scene declares both selection fields and the purchase and restore status enums, error codes, and invocation ids. Its prices and store products are test data. The two plan rows share a product and have distinct placements.

The iOS test opens this published scene in the real engine and runs these compiled actions through JourneyService and ExperiencePresentationService. TransactionService and TransactionObserver are real. The app purchase delegate supplies controlled store outcomes. The test supplies a window shell, drains feedback into the engine, and intercepts event delivery at the event sink.

The surrounding profile is supplied by the SDK's authenticated fixture helper. This is not a complete source-files publication or device UI qualification.
