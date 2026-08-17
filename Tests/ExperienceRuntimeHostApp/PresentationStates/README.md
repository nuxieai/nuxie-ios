# SDK presentation-state fixtures

Signed release fixtures that differ only in their `presentation` block.
They exist so the iOS presentation shell (shimmer, recovery, floating
controls, and every supported presentation mode) can be reviewed on
device through the ordinary authenticate/admit/acquire path.

These are review scenarios, not the cross-SDK renderer contract. The shared
contract corpus lives in `../Fixtures` and is the file to change when
renderer semantics move.

Regenerate from the repository root with:

```sh
node tests/e2e/ios/scripts/refresh-sdk-presentation-state-fixtures.mjs
```
