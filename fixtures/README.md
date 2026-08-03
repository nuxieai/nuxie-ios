# Experience execution fixtures

These language-neutral vectors pin the cross-plane experience-execution contract:

- `journeys/transitions`: a timeline maps to ordered `$journey_transition` facts with exact properties.
- `journeys/effects`: deterministic request ids, server completion facts, result binding, timeout, late-arrival, and offline-delivery semantics.
- `segments/seed-mirror`: profile generations reconcile an authoritative server membership mirror.
- `events/down-facts`: repeated server facts commit once, never upload, and route once to subscribers.
- `events/experience-events`: canonical `$experience_*` names and the
  experience identity/version properties carried by presentation facts and
  their customer/event/delegate/experiment riders.
- `golden-journey`: the minimal synchronous-enrollment journey vocabulary.
- `journeys/handoff`: server→device mailbox claim plus device→server
  `$journey_handoff` property shape, direction, epoch 0/1 encoding,
  destination-region addressing, unknown-version refusal, epoch advancement,
  and transferred terminality.
- `journeys/parking`: background and wait-pause `$journey_parked`
  checkpoints, device-plane tagging, pending deadlines, and epoch stamping.
- `journeys/takeover`: claimable mailbox decoding, stale-checkpoint resume
  metadata, relaunch-equivalent restoration, immediate past-due scheduling,
  and original-device epoch rejection.
- `journeys/seizure-race`: the live device's timeout handoff winning the epoch
  CAS before seizure, with transferred terminality and one effect execution.
- `journeys/handler-host-dispatch`: declaration-strict screen-host routing for
  `$screen_shown`/`$screen_dismissed`, with the legacy journey-host lifecycle
  fallback pinned separately from undeclared handler-only hosts.
- `journeys/ghost`: supersede/ghost accounting suppression.
- `journeys/time-window`: identical Swift/server calendar decisions.
- `journeys/experiment-resolution`: identical Swift/server assignment,
  fallback, freezing, and invalid-assignment decisions.

The Swift contract tests exercise the same behaviors. Consumers in other SDKs can reuse these JSON vectors.

## Native runtime test assets

`animation/`, `flow/`, and `minimal/` hold `.riv` assets consumed by the
`native/nux-apple-runtime` crate tests (and the package validator). They are
vendored byte-for-byte from upstream
[rive-runtime](https://github.com/rive-app/rive-runtime)
`tests/unit_tests/assets` at ref `d788e8ec6e8b598526607d6a1e8818e8b637b60c`,
with the same sha256 pins the nuxie-runtime repo's `tools/fetch-test-assets.sh`
enforces:

- `animation/smi_test.riv` — `51fb2ef2ca7a2014b4f4586df1c0894fef7d92d422a27ac82fef1459407b73f8`
- `flow/component_list_2.riv` — `b1541dfdba9f0a873245838ac560b27c21c181f9745d8052d9133163a530ef6e`
- `flow/data_binding_test.riv` — `c7e61a409945ffc70eb72c35b6efcd9a6115a00de0adc74419360ab88b740308`
- `flow/replace_view_model.riv` — `99a04bd4ff5c0a9b333e83c6a3840861fac6a26237329c7eef6993b26b64e4f5`
- `minimal/two_artboards.riv` — `480472d9942711492ce37cdba9aea6266f254633f5a2ac4a9e30f9d0eca70e8c`
