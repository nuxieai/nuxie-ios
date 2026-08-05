# Swift Apple runtime module

Decision date: 2026-08-04

## Decision

The Apple adapter is a Swift module, not a platform-agnostic Rust SDK crate.
The iOS SDK and a future Android SDK may implement their adapters natively in
Swift and Kotlin. They share the Nuxie runtime's behavioral contract and
fixtures, but they do not share an adapter interface or wrapper implementation.

The package dependency direction is:

```text
Nuxie SDK -> NuxieRuntime (Swift) -> NuxieRuntimeFFI (Rust XCFramework)
```

`NuxieRuntimeFFI` is a C ABI and binary-distribution detail. Product code must
not import it directly. The target state is for `NuxieRuntime` to own the
Apple-native interface, threading, ownership, request/result translation, and
runtime lifecycle. The SDK owns acquisition, persistence, journeys, UIKit
presentation, native text, and platform effects.

There is no cross-platform adapter seam. If Android is implemented, its Kotlin
adapter is a second native module over the runtime FFI appropriate to Android.
Behavioral parity comes from shared contract fixtures, not shared wrapper code.

## Current migration slice

This change establishes the module and makes it the SDK's only declared runtime
dependency. It moves these responsibilities into Swift:

- the serial executor that confines runtime handles and calls;
- mapping stable-width C status values to Swift values; and
- lifetime-safe marshalling of package bytes, authorization keys, and external
  assets into one synchronous FFI import call.

The existing `native/nux-apple-runtime` crate remains temporarily as the FFI
exporter because the pinned core `nux-capi` does not yet expose the
experience-context, screen-session, Apple-surface, typed-value, and ordered
result operations used by the SDK. Its product behavior is migration debt, not
the target interface.

During this slice, `NuxieRuntime` re-exports the C module to the legacy Swift
bridge files that have not moved yet. Those SDK files still encode operations,
manage opaque handles, and decode results using C declarations. Removing that
re-export is the completion condition for steps 1 and 2 below; until then the
FFI is target-isolated but not yet interface-hidden.

## Migration sequence

1. Move opaque context/session/surface ownership and result consumption into
   `NuxieRuntime` while preserving the current ABI and fixtures.
2. Move operation encoding and result decoding behind Swift value types so no
   SDK source uses C structs or functions.
3. Move Apple lifecycle and product policy out of the Rust compatibility crate,
   leaving only panic-contained, memory-safe C exports over core runtime
   capabilities.
4. Replace the SDK-owned compatibility crate with the core runtime's qualified
   FFI artifact once it exposes the required coarse operations.
5. Delete the compatibility crate, its product-semantic Rust tests, and any
   superseded Swift bridge tests. Keep contract tests at the Swift module
   interface and binary ABI smoke tests at the FFI seam.

Each slice must preserve iOS 15 support, structured failure isolation, exact
package authentication, bounded inputs/results, deterministic output ordering,
surface recovery, and customer builds that require neither Cargo nor a Rust
toolchain.
