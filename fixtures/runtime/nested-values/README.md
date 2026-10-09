# Nested SDK values fixture

Generated through `experience_editor_bridge::Pipeline::mounted` and its published document encoder at monorepo `f5ace4c5be`, runtime `32a31b01ba45afa6fb6b3b5cf19fc6a2b32779be`. `generate.rs` includes the exact authored files. No SDK decoder output is used to form expectations.

The shared Experience starts with `profile/minutes = 10`, `profile/settings/minutes = 12`, `profile/name = Ana`, date `2026-10-09`, and `top = 7`. `profile/empty` is absent. Topics are `Reading, writing` and `Travel`; only Travel starts selected.

The checks write minutes to 20 and the deeper date to `2026-10-10`, then persist and restore the native shared instance before the Journey condition `profile/minutes > 15`. The event reads the nested name and date by exact slash key. The checkpoint check also selects the first topic and preserves the present/empty markers. No screen is mounted after restart and no response form is submitted.

`state.json` is handwritten signed-release declaration metadata, without starting values or hidden presence fields. Device tests sign their own v3 envelope with a test-only key. This fixture qualifies values and restart behavior, not pixels.

To regenerate, copy `generate.rs` into the bridge crate as `src/nested_sdk_fixture.rs`, add `#[cfg(test)] mod nested_sdk_fixture;` to its `lib.rs`, then run `NESTED_SDK_FIXTURE_OUT=<screen.riv> cargo test --manifest-path tools/nuxie-editor/Cargo.toml -p experience-editor-bridge --lib nested_sdk_fixture -- --nocapture`. This test-only entry point uses the crate's existing private publication seam and changes no production logic.
