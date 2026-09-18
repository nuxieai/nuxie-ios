# Accessibility fixtures

The JSON files are shared native-adapter contracts. They exercise copied state,
collection validation and focus decisions without claiming screen-reader or
published-Experience qualification.

`collections.riv` exercises real runtime import, presentation and native capture.
It contains a list with logical total 10 and only positions 4–6 exposed, a nested
list with position zero, a known empty list, and an unknown-total list with an
unknown-position member. It has no
font assets. It is a capture bridge fixture, not a visual or publishing fixture.

From the parent `nuxie-dev` repository, regenerate using `nuxie-runtime` commit
`906f6cc0e033ba4f001f042cc95bbc5f52709aae` with:

```sh
bash tools/sdk-fixtures/generate-semantic-collection-fixture.sh \
  /absolute/path/to/nuxie-runtime \
  /absolute/path/to/nuxie-ios/fixtures/accessibility/collections.riv
```

The generator uses the runtime's schema and binary fixture encoder. Expected
SHA-256: `d6d237efb10d4b5120beed8a65245ece583f09453630fcc7356a805d36919505`.
Android consumes these same files through `scripts/sync-fixtures.sh` from a
committed iOS revision.
