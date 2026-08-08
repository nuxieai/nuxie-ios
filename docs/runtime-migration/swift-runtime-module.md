# Swift Apple runtime module

Decision date: 2026-08-07

## Decision

The iOS integration is a pure-Swift module over the released Apple runtime
binary:

```text
Nuxie SDK -> NuxieRuntime (Swift) -> NuxieRuntimeFFI (Apple ABI/XCFramework)
```

`nuxie-runtime` owns the Rust implementation, Apple ABI, native library, and
XCFramework release. `nuxie-ios` does not own a Rust crate. The Swift module
owns the ergonomic Apple interface, serial execution, handle lifetimes,
request/result translation, session lifecycle, Metal surface coordination,
and Swift error/value types used by the SDK.

The product SDK owns acquisition, persistence, journeys, UIKit presentation,
native text editing, platform effects, and telemetry. It depends only on
`NuxieRuntime` and does not know how the binary is produced or pinned.

There is no cross-platform adapter seam. Android may have an independently
designed Kotlin adapter over an appropriate runtime ABI. The editor and iOS
SDK share runtime contracts and fixtures where useful, not application source.

## Enforced boundary

`NuxieRuntime` does not re-export the C module. Direct
`NuxieRuntimeFFI` imports, `nux_*` calls, C request/result structures, and
opaque-handle ownership are confined to `Sources/NuxieRuntime`. Repository
checks reject those details under `Sources/Nuxie` and reject any other source
target importing the low-level module.

The binary dependency remains iOS-only. `Nuxie -> NuxieRuntime` is
unconditional so shared Swift value and lifecycle contracts compile in the
macOS SDK graph, while rendered runtime experiences remain qualified only on
iOS.

## Apple support matrix

| Surface | iOS 15+ | macOS 12+ |
| --- | --- | --- |
| Events, identity, networking, configuration, and non-rendering SDK behavior | Supported | Supported |
| Rendered runtime experiences and UIKit presentation | Supported and qualified | Not supported |
| Swift `NuxieRuntime` values and host lifecycle contracts | Included | Compiled for the non-rendering graph |
| `NuxieRuntimeFFI` binary and concrete Metal adapter | Linked | Not linked |
| Rust compilation in `nuxie-ios` | Never | Never |

A macOS rendered-runtime product requires a separately designed and qualified
host. Successful macOS compilation does not establish rendering support.
