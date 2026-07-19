# Nuxie Flow Runtime Reference App

Standalone native iOS host for the Slice 1 Rust runtime. This target compiles
the narrow Swift runtime seam directly and intentionally does not depend on
`NuxieSDK`, `rive-ios`, or `RiveRuntime`.

It loads current published `.riv` fixtures through `NuxieRuntime.xcframework`:

- `layout-paint`
- `pressable-interaction`

Build and install it with a locally verified runtime artifact:

```sh
make build-reference-app \
  NUXIE_RUNTIME_XCFRAMEWORK=/absolute/path/to/NuxieRuntime.xcframework
make install-reference-app \
  NUXIE_RUNTIME_XCFRAMEWORK=/absolute/path/to/NuxieRuntime.xcframework
make test-runtime-reference-ui \
  NUXIE_RUNTIME_XCFRAMEWORK=/absolute/path/to/NuxieRuntime.xcframework
```

The UI gate waits for `presented:layout-paint`, which is published only after
the Rust operation returns its first positive presentation result, and retains
an XCTest screenshot in the result bundle.

The local path is a qualification input only. SDK distribution still requires
the same archive to be hosted at an immutable URL and checksum-pinned as a
SwiftPM binary target.
