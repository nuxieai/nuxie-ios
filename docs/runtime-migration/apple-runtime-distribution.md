# Apple runtime distribution

`nuxie-ios` consumes the Rust runtime as `NuxieRuntime.xcframework`. The
customer-facing Swift package and the XcodeGen development project deliberately
use one qualified archive, but reach it through two distribution paths.

## Swift Package Manager

When `.artifacts/NuxieRuntime.xcframework` exists, `Package.swift` declares it
as a local binary target. This path is ignored and is intended for SDK/runtime
development and qualification.

Without a staged artifact, SwiftPM declares the public binary target at:

```text
https://github.com/nuxieai/nuxie-runtime/releases/download/apple-runtime-v0.1.0/NuxieRuntime.xcframework.zip
```

The exact SwiftPM checksum is:

```text
02f1083cfe7490c5d2d06f2fbd5aeb7e589ece42ce33ccc99ecd84166447f717
```

The archive must be published from the protected runtime release and verified
through the anonymous public URL before the cutover can merge. Changing the
archive requires a new immutable version, URL, and checksum; replacing bytes at
an existing URL is not an accepted update path.

## Local Xcode builds

Stage a runtime built by `nuxie-runtime` with:

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
checks. Project generation and macOS targets remain usable without it. Once the
release exists, CI stages it with `make fetch-runtime-xcframework`, which
verifies the archive checksum before extraction. CI then links and audits both
the simulator framework and an unsigned Release framework for a generic iOS
device.

`make verify-customer-framework` audits the final `Nuxie.framework` produced by
an iOS build. It requires the two public Rust ABI symbols, rejects Rive-named
artifacts/dependencies and `rive` C++ namespace symbols, and byte-compares the
packaged privacy manifest with the SDK source declaration. A normal system
`libc++.1.dylib` dependency remains allowed.

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
