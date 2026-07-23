# Experience execution fixtures

These language-neutral vectors pin the E1 device contract:

- `journeys/transitions`: a timeline maps to ordered `$journey_transition` facts with exact properties.
- `segments/seed-mirror`: profile generations reconcile an authoritative server membership mirror.
- `events/down-facts`: repeated server facts commit once, never upload, and route once to subscribers.
- `golden-journey`: the minimal journey vocabulary after the E1 cutover.

The Swift contract tests exercise the same behaviors. Consumers in other SDKs can reuse these JSON vectors.
