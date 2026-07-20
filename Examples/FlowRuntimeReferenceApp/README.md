# Nuxie Flow Runtime Reference App

Standalone native iOS host for the Slice 1 Rust runtime. This target compiles
the narrow Swift runtime seam directly and intentionally does not depend on
`NuxieSDK` or a legacy renderer SDK.

It loads current published `.riv` fixtures through `NuxieRuntime.xcframework`:

- `layout-paint`
- `pressable-interaction`

Build and install it with a locally verified runtime artifact:

```sh
make stage-runtime-xcframework \
  NUXIE_RUNTIME_XCFRAMEWORK=/absolute/path/to/NuxieRuntime.xcframework
make build-reference-app
make install-reference-app
make test-runtime-reference-ui
```

The UI gate waits for `presented:layout-paint`, which is published only after
the Rust operation returns its first positive presentation result, and retains
an XCTest screenshot in the result bundle.

The staged `.artifacts` directory is ignored. Once the protected runtime
release is published, `make fetch-runtime-xcframework` downloads and validates
the same URL and checksum declared by the SwiftPM binary target.
