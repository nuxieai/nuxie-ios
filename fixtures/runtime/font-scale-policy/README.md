# Generated font-scale policy

This production-published fixture has three native text inputs using the bundled Fixture Sans font:

- `bound`: system scaling, authored font size 18 and line height 24.
- `fixed`: fixed scaling, authored font size 18 and line height 24.
- `natural`: system scaling, authored font size 18 and natural line height -1.

`cases.json` supplies repeated root `fontScale` writes and independent expected metrics. The snapshot contains only reverse metric observations; the production compiler must generate all forward scaling bindings. Consumers must advance once, compare effective metrics and captured baselines, render changed pixels, keep the fixed field stable, and restore the original frame at scale 1.

Generate from the parent repository with `bun tools/sdk-fixtures/generate-font-metrics-fixture.mjs sdks/nuxie-ios font-scale-policy`. `provenance.json` records the publisher binary, generator commit, snapshot, font and render hashes. The iOS fixture is canonical; Android must mirror its committed bytes. This fixture alone does not qualify system-preference observation, SDK lifecycle handling or native-overlay alignment.
