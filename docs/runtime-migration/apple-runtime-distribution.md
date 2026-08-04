# Apple runtime distribution

`nuxie-ios` owns the Apple FFI crate and XCFramework packaging. It builds
`NuxieRuntime.xcframework` from
`native/nux-apple-runtime` against the exact engine revision pinned in
`third_party/nuxie-runtime`. The engine repository remains platform-independent
runtime and format source.

The qualified archive is committed at
`Runtime/NuxieRuntime.xcframework.zip`. Customers never invoke Cargo or
initialize submodules.

## Swift Package Manager

When `.artifacts/NuxieRuntime.xcframework` exists, `Package.swift` declares it
as a local binary target. This path is ignored and is intended for SDK/runtime
development and qualification.

Without a staged artifact, SwiftPM uses the committed archive directly. The
artifact carries no version of its own: the SDK commit a consumer checks out
*is* the runtime version. The deleted `apple-runtime-v*` releases and tags are
not used, and the SDK has no version tags. Consumers point SwiftPM at a branch
or commit SHA.

`make package-runtime-xcframework` rebuilds and validates the XCFramework,
updates `Runtime/NuxieRuntime.xcframework.zip`, and records its source inputs in
`Runtime/provenance.json`. The dispatch-only
`.github/workflows/refresh-runtime.yml` runs that command in CI and opens a pull
request when `Runtime/` changes; it never pushes directly to `main`. Because
pull requests created with `GITHUB_TOKEN` do not trigger `pull_request`
workflows, the refresh workflow explicitly dispatches `test.yml` for the new
branch. If required status checks are tied to `pull_request` events, the
generated PR needs a GitHub App or PAT instead to become mergeable.

The refresh workflow decides whether to rebuild *before* building: if
`check-runtime-provenance` already passes, the committed artifact matches its
inputs and the job stops without building or opening a PR. This cannot be done
after the fact. The build embeds the SDK `HEAD` as `sourceRevision`, so
rebuilding at any new commit always produces different bytes even when the
runtime is unchanged — neither normalized archive metadata nor an
unpacked-payload comparison can see through that. Without the up-front check,
every dispatch would commit another ~45 MB blob for an identical runtime.
Dispatch with `force: true` to rebuild anyway, for example after a toolchain
change that the hashed inputs do not cover.

`make check-runtime-provenance` validates the artifact chain without building
Rust:

- `buildInputsHash` covers the committed `LICENSE`, the `native` tree (crate,
  `Cargo.toml`, `Cargo.lock`), the engine gitlink, and
  `scripts/build-runtime-xcframework.sh` and
  `scripts/package-runtime-archive.sh`. The build script computes this hash from
  the Makefile's committed-tree manifest and embeds it in clean-build binaries.
  The validation and verification scripts are deliberately excluded: they
  inspect the artifact rather than produce it, so including them would fail the
  guard on a comment-only edit and train people to bypass it.
  `THIRD_PARTY_NOTICES.md` is likewise omitted — it comes from the engine
  submodule, which the gitlink already covers;
- the archive-embedded `buildInputsHash`, the value recorded in
  `Runtime/provenance.json`, and the hash of the current checkout's committed
  input trees must all match. This content-addressed binding means provenance
  cannot be rewritten to describe an archive built from different inputs;
- `archiveSha256` matches the committed archive in full, covering headers, the
  bundled license, and the simulator slice rather than one embedded string;
- `nuxieRuntimeRevision` matches the committed engine gitlink; and
- `sourceRevision` matches the build provenance embedded in the device archive.
  It is informational-only: rebase-merging orphans the build commit, so no gate
  resolves it as a Git object.

The guard reads only `HEAD`'s committed objects and the archive bytes. It needs
no Git history or submodule checkout and works in a shallow single-branch clone.

The `runtime-artifact` test job runs this guard on every pull request, so a
runtime input or archive change requires refreshing the committed artifact.

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
`make unpack-runtime-xcframework` stages and validates the committed archive for
CI and clean-room qualification.

`make fetch-runtime-xcframework` is a temporary compatibility alias for that
target because `test.yml` SHA-pins a reusable `_trusted-macos.yml` workflow from
before the target was renamed. Delete the alias after the pin moves to a commit
containing the updated workflow.

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
