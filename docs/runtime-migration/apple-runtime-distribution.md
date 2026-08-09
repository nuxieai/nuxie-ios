# Apple runtime distribution

Decision date: 2026-08-07

## Ownership

`nuxie-runtime` owns the Apple ABI, native adapter, XCFramework build,
verification, release, and provenance. It publishes a versioned
`NuxieRuntime.xcframework.zip` release containing iOS device, iOS simulator,
and universal macOS slices.

`nuxie-ios` is a binary consumer. It owns the pure-Swift `NuxieRuntime`
adapter, Swift lifecycle and result translation, application behavior, and
consumer-side artifact qualification. It contains no Cargo workspace, Rust
source, runtime source submodule, native compiler workflow, or committed
XCFramework.

The dependency direction is:

```text
Nuxie SDK -> NuxieRuntime (Swift) -> NuxieRuntimeBinary (released XCFramework)
```

Only `NuxieNativeRuntime.swift` may import the portable `NuxieRuntimeC`
module. Product SDK code uses Swift values and has no knowledge of opaque
handles, C structs, low-level function calls, or artifact provenance. No
Swift source imports the retired compatibility module still carried inside
the immutable v0.4 artifact.

## Immutable SwiftPM pin

`Runtime/artifact.json` records the exact runtime release tag, HTTPS
release-asset URL, and SwiftPM SHA-256 checksum. `Package.swift` declares the
same URL and checksum as the `NuxieRuntimeBinary` binary target. The literals stay
in the manifest so changing a pin necessarily invalidates SwiftPM's manifest
cache; CI rejects any disagreement between the two files.

`make fetch-runtime-xcframework` downloads that same asset, checks its
checksum before extraction, verifies its slices and ABI, and stages it at the
ignored `.artifacts/NuxieRuntime.xcframework` path used by XcodeGen builds.

Runtime development has an explicit local override:

```sh
make stage-runtime-xcframework \
  NUXIE_RUNTIME_XCFRAMEWORK=/absolute/path/to/NuxieRuntime.xcframework
NUXIE_RUNTIME_USE_LOCAL=1 make test
```

The staged path is ignored. `Package.swift` uses it only when
`NUXIE_RUNTIME_USE_LOCAL=1`; otherwise it always uses the immutable release
URL/checksum even if a stale local cache exists. Makefile consumers likewise
bind the staged archive and XCFramework to `Runtime/artifact.json` unless that
explicit local-development opt-in is present.
Local artifacts are for development only and cannot qualify distribution.

## Consumer qualification

CI downloads the immutable release and verifies, without compiling Rust:

- the declared archive checksum;
- an `ios-arm64` device slice and an
  `ios-arm64_x86_64-simulator` slice;
- a `macos-arm64_x86_64` slice;
- arm64 device plus arm64/x86_64 simulator and macOS architectures;
- iOS 15.0 and macOS 12.0 load commands;
- identical allowlisted headers and the `NuxieRuntimeFFI` module map;
- the complete generated-header/exported-symbol contract;
- C header layout compilation and Swift import/link smoke tests; and
- customer framework linkage, privacy manifest, and absence of Rive artifacts.

`check-runtime-consumer-boundary` prevents the iOS repository from regaining
Rust build ownership, a runtime gitlink, or a committed native artifact.
`check-runtime-package-pin` evaluates the manifest in release mode and proves
its remote binary URL and checksum exactly match `Runtime/artifact.json`, even
when a local artifact happens to be staged.
