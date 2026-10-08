# Two independent native text inputs

Published from 8cd72f0d43bdfa41c881580a9dc5eab4c5c1e479 (codex/text-field-clip), the fixed F3 line based on 09081fd6591bb5f24c33693d0b06a7c3a207ea65. The publisher's runtime source is 32a31b01ba45afa6fb6b3b5cf19fc6a2b32779be. This does not change either SDK's staged runtime.

The source follows F3: System font; experience string bindings; focus, blur and input handlers; compilation through RepoCore, buildPublishSource and riveCompilerBackend. The compiler keeps the text field viewport in layout flow. This publisher line includes the no-caret/selection publication pin and the padded-field inset and intrinsic-height fixes. Native overlay screenshots qualify the combined paint separately.

Handwritten oracle: name starts as Ada, surname starts as Hopper. Native editing field 2 sends a Rive focus tap. Replacing its text with Grace must leave name as Ada and set surname to Grace. Tests compare the native controls, occurrence-checked Rive field reads and Journey-bound values. Handler timing follows Rive; no SDK-forced early input handler.

text-inputs.json and locations.json are compiler metadata, not behavior expectations. release-entry.json is a version 3 envelope signed with the existing test-only development key (public seed 0x42 repeated 32 times). profile.json admits it through the normal SDK catalog/acquisition path. The signed descriptor contains the exact scene hash and system-font declaration. The content-addressed nux copy and screen.riv are identical.

Reproduction and exact command outcomes: /Users/levi/dev/nuxie-codex/thread4-combined-base-evidence/typing-two-fields (fixture-publisher.test.ts, vitest.config.mts, sign-fixture.mjs, materialize-fixture.py), and ../commands.jsonl. Platform test: ExperienceTextInputSemanticsTests.testNativeEditingSecondPublishedFieldKeepsFirstValue on iOS; PublishedTextInputDeviceTest.nativeEditingSecondPublishedFieldKeepsFirstValue on Android.
