# Apple runtime distribution

`nuxie-ios` owns the Apple FFI crate, XCFramework packaging, and release
hosting. It builds `NuxieRuntime.xcframework` from
`native/nux-apple-runtime` against the exact engine revision pinned in
`third_party/nuxie-runtime`. The engine repository remains platform-independent
runtime and format source.

The customer-facing Swift package and the XcodeGen development project
deliberately use one qualified archive, but reach it through two distribution
paths. Customers never invoke Cargo or initialize submodules.

## Swift Package Manager

When `.artifacts/NuxieRuntime.xcframework` exists, `Package.swift` declares it
as a local binary target. This path is ignored and is intended for SDK/runtime
development and qualification.

Without a staged artifact, SwiftPM declares a public binary target pinned to a
release asset of this repository.

The runtime artifact carries no version of its own. Each SDK release
(`vX.Y.Z`) builds `NuxieRuntime.xcframework` from whatever state
`native/nux-apple-runtime` and the nested `third_party/nuxie-runtime`
submodule are in at the released commit — that SDK version *is* the runtime
version. The release workflow (`.github/workflows/release.yml`,
dispatch-driven with an `X.Y.Z` input) builds and validates the archive,
computes the SwiftPM checksum, rewrites the `Package.swift` binary pin to the
release it is about to create, commits and tags `vX.Y.Z`, and publishes the
immutable GitHub release with the archive attached. Release notes carry the
checksum and the nested engine revision.

`Package.swift` is the only place the released URL and checksum are written;
the Makefile parses them from there. Until the first SDK release is cut, the
pin retains the immutable legacy `apple-runtime-v0.3.0` asset (checksum
`8bfb82c5da220cf7c2184f14e19941b962924a010493452a0cea1d58cb8fee54`), the last
artifact published under the retired independent runtime-versioning scheme.

Changing any hosted archive requires a new immutable SDK release, URL, and
checksum; replacing bytes at an existing URL is not an accepted update path.

## Local Xcode builds

Initialize the engine source and build the SDK-owned runtime with:

```sh
git submodule update --init
make build-runtime-xcframework
```

This builds iOS device and universal simulator slices, runs the C/Swift header
and linkage smoke checks, validates the XCFramework, and stages it at
`.artifacts/NuxieRuntime.xcframework`.

An externally supplied XCFramework can still be staged independently with:

```sh
make stage-runtime-xcframework \
  NUXIE_RUNTIME_XCFRAMEWORK=/absolute/path/to/NuxieRuntime.xcframework
```

The staging operation copies through a temporary directory, then validates:

- a parseable XCFramework `Info.plist` declaring device and simulator slices;
- the device and universal simulator static archives;
- Mach-O platform load commands with no object requiring newer than iOS 15;
- the public wrapper/generated headers and module maps for both slices; and
- `LICENSE` and `THIRD_PARTY_NOTICES.md`.

All iOS Make targets fail early unless the staged artifact passes the same
checks. Project generation and macOS targets remain usable without it.
`make fetch-runtime-xcframework` preserves the exact-checksum fallback path for
clean-room qualification, downloading whatever release asset `Package.swift`
currently pins.

`make verify-customer-framework` audits the final `Nuxie.framework` produced by
an iOS build. It requires representative runtime-binding, experience-context,
and screen-session symbols, rejects Rive-named artifacts/dependencies and
`rive` C++ namespace symbols, and byte-compares the packaged privacy manifest
with the SDK source declaration. A normal system `libc++.1.dylib` dependency
remains allowed.

## Apple platform contract

- Minimum deployment target: iOS 15.
- Mac Catalyst is unsupported for this runtime and disabled in generated iOS
  targets.
- The static runtime links Foundation, QuartzCore, Metal, CoreGraphics, and
  Security.
- `Sources/Nuxie/PrivacyInfo.xcprivacy` declares tracking disabled and no
  tracking domains. It declares the SDK's linked collection of configured
  name/email/phone traits, user and anonymous device identifiers, purchase
  history, product interaction and other usage data, memory performance data,
  other technical diagnostics, flow-response content, and arbitrary
  application-supplied properties for analytics, product personalization, and
  app functionality.
- Required-reason API coverage is System Boot Time `35F9.1` for frame timing,
  User Defaults `CA92.1` for SDK-owned lifecycle keys, and File Timestamp
  `C617.1` for SDK cache files inside the app container.

`make check-privacy-manifest` enforces that exact inventory. The application
integrator remains responsible for adding any more-specific semantic data
types it sends through Nuxie's generic user-property, event-property, or
response-value surfaces and for keeping its App Store privacy answers aligned.

The `.riv` wire-format names remain during this migration. Packaging them into
the future `.nux` superset is a separate phase.
