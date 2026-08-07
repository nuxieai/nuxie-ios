# Swift Apple runtime module

Decision date: 2026-08-04

## Decision

The Apple adapter is a Swift module, not a platform-agnostic Rust SDK crate.
The iOS SDK and a future Android SDK may implement their adapters natively in
Swift and Kotlin. They share the Nuxie runtime's behavioral contract and
fixtures, but they do not share an adapter interface or wrapper implementation.

The package dependency direction is:

```text
Nuxie SDK -> NuxieRuntime (Swift) -+-> NuxieProductFFI (product ABI)
                                  +-> NuxieRuntimeFFI (Apple ABI/XCFramework)

nuxie-ios --exact rev--> nuxieai/nuxie-product
                              --exact rev--> nuxie-runtime baseline
```

`NuxieProductFFI` is the separately named upper-layer ABI for authenticated
`.nux` import, experience contexts, product sessions, typed values, and ordered
product results. It is owned by the dedicated
[`nuxieai/nuxie-product`](https://github.com/nuxieai/nuxie-product) repository.
`NuxieRuntimeFFI` remains the SDK-owned Apple ABI and binary-distribution seam
for Metal surfaces and presentation lifecycle. Both are implementation details
of the final `NuxieRuntime` Swift module; product SDK code must import neither
FFI module directly. The portable engine `nux-capi` remains baseline-only and
is not a future home for either interface.

The target state is for `NuxieRuntime` to own the Apple-native interface,
threading, ownership, request/result translation, and runtime lifecycle. The
SDK owns acquisition, persistence, journeys, UIKit presentation, native text,
and platform effects.

There is no cross-platform adapter seam. If Android is implemented, its Kotlin
adapter is a second native module over the runtime FFI appropriate to Android.
Behavioral parity comes from shared contract fixtures, not shared wrapper code.

## Current migration state

The Swift module is now the SDK's only runtime dependency. It owns:

- context, session, operation-result, and Apple-surface handle lifetimes;
- the serial executor that confines every native handle and call;
- Swift-native operation encoding and result decoding;
- mapping stable-width C status values to Swift values; and
- lifetime-safe marshalling of package bytes, authorization keys, and external
  assets into one synchronous FFI import call.

The existing `native/nux-apple-runtime` crate currently exports a combined ABI
while repository extraction is in progress. Its continued existence is not a
workaround for missing `nux-capi` features: `nux-capi` deliberately will not
gain experience, session, product, or Apple-surface operations. The combined
crate is split by ownership into `NuxieProductFFI` supplied by
`nuxie-product` and the SDK-owned Apple ABI; `nuxie-ios` continues to assemble
and qualify the customer XCFramework.

`NuxieRuntime` no longer re-exports either C module. Direct FFI imports, raw
`nux_*` calls, C request/result structures, and opaque-handle ownership are
confined to `Sources/NuxieRuntime`. A repository boundary check rejects those
details anywhere under `Sources/Nuxie`.

## Migration sequence

1. **Complete:** move opaque context/session/surface ownership and result
   consumption into `NuxieRuntime` while preserving the current ABI and
   fixtures.
2. **Complete:** move operation encoding and result decoding behind Swift value
   types so no SDK source uses C structs or functions.
3. Move `.nux`, product scripting, ProjectDO, FlowSession, and their
   panic-contained product C exports to `nuxieai/nuxie-product` as
   `NuxieProductFFI`.
4. Keep CAMetalLayer/drawable lifecycle, presentation completion and failure
   disposition, Apple image admission, and XCFramework assembly in
   `nuxie-ios`; do not move them into the product ABI or `nux-capi`.
5. Make the Swift `NuxieRuntime` module the only importer of both FFI modules,
   delete superseded legacy bridge code, and keep contract tests at the Swift
   module interface plus binary ABI smoke tests at each C seam.

Each slice must preserve iOS 15 support, structured failure isolation, exact
package authentication, bounded inputs/results, deterministic output ordering,
surface recovery, and customer builds that require neither Cargo nor a Rust
toolchain.

## Apple support matrix

| Surface | iOS 15+ | macOS 12+ |
| --- | --- | --- |
| `Nuxie` package: events, identity, networking, configuration, and other non-rendering SDK behavior | Supported | Supported |
| Rendered runtime experiences and UIKit presentation | Supported and qualified | Not supported |
| Swift `NuxieRuntime` values and host lifecycle contracts | Included | Compiled for the non-rendering SDK graph |
| `NuxieRuntimeFFI` binary dependency and concrete Metal surface adapter | Included | Not linked |
| Rust builds/tests run by SDK contributors | Qualification input | Development evidence only; not a customer product host |

`Nuxie -> NuxieRuntime` is unconditional so the shared Swift value and lifecycle
contracts compile with the existing macOS SDK. `NuxieRuntime ->
NuxieRuntimeFFI` remains conditional on iOS. A macOS rendered-runtime product
requires a separately designed and qualified macOS host; successful macOS
compilation or offscreen Metal tests do not establish that support.
