# Swift Apple runtime module

Decision date: 2026-08-07

## Decision

The Apple integration is a pure-Swift module over the released Apple runtime
binary:

```text
Nuxie SDK -> NuxieRuntime (Swift) -> NuxieRuntimeC (portable C ABI/XCFramework)
```

`nuxie-runtime` owns the Rust implementation, Apple ABI, native library, and
XCFramework release. `nuxie-ios` does not own a Rust crate. The Swift module
owns the ergonomic Apple interface, a dedicated OS-thread executor, typed and
idempotent handle lifetimes, owned-result copying, Metal surface coordination,
and Sendable Swift error/value types used by the SDK. Swift owns CAMetalLayer,
drawable acquisition, and scheduling; Rust owns the renderer/device domain.

The product SDK owns acquisition, persistence, journeys, UIKit presentation,
native text editing, platform effects, and telemetry. Its runtime behavior
depends only on `NuxieRuntime`. It does not import the low-level C module or
know how the binary is produced or pinned. Product loading authenticates the
package in Swift, opens one `ExperienceInteractiveScreen` per presented
screen, and drives it through the Swift presentation loop.

There is no cross-platform adapter seam. Android may have an independently
designed Kotlin adapter over an appropriate runtime ABI. The editor and iOS
SDK share runtime contracts and fixtures where useful, not application source.

## Enforced boundary

`NuxieRuntime` does not re-export the C module. Direct `NuxieRuntimeC`
imports, `nux_*` calls, C request/result structures, and opaque-handle
ownership are confined to its native wrapper implementation. Repository checks
reject those details under `Sources/Nuxie` and reject any other source target
importing the low-level module.

`NuxieNativeRuntime` owns one file/artboard/player/view-model/renderer graph on
one pinned OS thread. Its actor surface returns only copied Sendable values:
artboard and view-model catalogs, player metadata and step output, mutation
journals, snapshots, diagnostics, and renderer outcomes. Explicit `close()` and
deinitialization both consume every native handle at most once; no borrowed C
view crosses the executor boundary.

The full Apple binary dependency covers iOS and macOS. `Nuxie -> NuxieRuntime`
is unconditional, and both platforms compile the same native ownership facade.

The v0.4.0 migration artifact still contains the retired product-shaped ABI as
a release rollback aid, but no Swift target imports its module or calls those
symbols. The repository guard rejects legacy imports, target edges, result
accessors, and context/session vocabulary from production Swift source.

## Apple support matrix

| Surface | iOS 15+ | macOS 12+ |
| --- | --- | --- |
| Events, identity, networking, configuration, and non-rendering SDK behavior | Supported | Supported |
| Runtime-native C rendering | Supported and qualified | Supported and qualified by native fixture tests |
| UIKit/AppKit product presentation | Supported by the SDK | Not yet a product surface |
| Swift `NuxieRuntime` ownership facade | Included | Included |
| Full Apple XCFramework and Metal renderer | Linked | Linked |
| Legacy product-shaped native adapter | Absent | Absent |
| Rust compilation in `nuxie-ios` | Never | Never |

A macOS rendered-runtime product requires a separately designed and qualified
host. Successful macOS compilation does not establish rendering support.
