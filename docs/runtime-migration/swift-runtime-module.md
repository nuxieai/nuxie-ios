# Swift Apple runtime module

Decision date: 2026-08-04

## Decision

The Apple adapter is a Swift module, not a platform-agnostic Rust SDK crate.
The iOS SDK and a future Android SDK may implement their adapters natively in
Swift and Kotlin. They share the Nuxie runtime's behavioral contract and
fixtures, but they do not share an adapter interface or wrapper implementation.

The package dependency direction is:

```text
Nuxie SDK -> NuxieRuntime (Swift) -> NuxieRuntimeFFI (Apple ABI/XCFramework)

nuxie-ios --exact rev--> nuxie-runtime workspace
                          +-- portable baseline crates
                          +-- optional inward-dependent product crates
```

`NuxieRuntimeFFI` is the SDK-owned Apple ABI and binary-distribution seam for
experience/session operations, Metal surfaces, and presentation lifecycle. It
adapts optional product crates from the same pinned runtime workspace; those
crates depend on the portable baseline, never the reverse. The FFI remains an
implementation detail of the final `NuxieRuntime` Swift module; product SDK
code must not import it directly. The portable engine `nux-capi` remains
baseline-only and is not a future home for the Apple interface.

The target state is for `NuxieRuntime` to own the Apple-native interface,
threading, ownership, request/result translation, and runtime lifecycle. The
SDK owns acquisition, persistence, journeys, UIKit presentation, native text,
and platform effects.

There is no cross-platform adapter seam. If Android is implemented, its Kotlin
adapter is a second native module over the runtime FFI appropriate to Android.
Behavioral parity comes from shared contract fixtures, not shared wrapper code.
Likewise, `nuxie-dev` and `nuxie-ios` share runtime contracts and fixtures, not
application-layer source code.

## Current migration state

The Swift module is now the SDK's only runtime dependency. It owns:

- context, session, operation-result, and Apple-surface handle lifetimes;
- the serial executor that confines every native handle and call;
- Swift-native operation encoding and result decoding;
- mapping stable-width C status values to Swift values; and
- lifetime-safe marshalling of package bytes, authorization keys, and external
  assets into one synchronous FFI import call.

The existing `native/nux-apple-runtime` crate exports the complete SDK-owned
Apple ABI. Its continued existence is not a workaround for missing `nux-capi`
features: `nux-capi` deliberately will not gain experience, session, product,
or Apple-surface operations. The Apple crate consumes the needed baseline and
optional product crates from one pinned `nuxie-runtime` checkout; `nuxie-ios`
assembles and qualifies the customer XCFramework.

`NuxieRuntime` does not re-export the C module. Direct FFI imports, raw
`nux_*` calls, C request/result structures, and opaque-handle ownership are
confined to `Sources/NuxieRuntime`. A repository boundary check rejects those
details anywhere under `Sources/Nuxie`.

## Migration sequence

1. **Complete:** move opaque context/session/surface ownership and result
   consumption into `NuxieRuntime` while preserving the current ABI and
   fixtures.
2. **Complete:** move operation encoding and result decoding behind Swift value
   types so no SDK source uses C structs or functions.
3. Keep optional product scripting, ProjectDO, and FlowSession behavior in
   inward-dependent `nuxie-runtime` crates without making the baseline depend
   on them.
4. Keep `.nux` package reading, CAMetalLayer/drawable lifecycle, presentation
   completion and failure disposition, Apple image admission, the complete
   Apple ABI, and XCFramework assembly in `nuxie-ios`.
5. Make the Swift `NuxieRuntime` module the only importer of the FFI module,
   delete superseded legacy bridge code, and keep contract tests at the Swift
   module interface plus binary ABI smoke tests at the C seam.

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
