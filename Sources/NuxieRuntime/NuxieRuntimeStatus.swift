#if os(iOS) && !targetEnvironment(macCatalyst)
import NuxieRuntimeFFI

/// Swift names for the fixed-width status values in the runtime C ABI.
package enum NuxieRuntimeStatus: Equatable, Sendable {
    case ok
    case nullArgument
    case importError
    case notFound
    case runtimeError
    case invalidArgument
    case runtimeIdentityMismatch
    case surfaceError
    case unknown(UInt32)
}

package func nuxieRuntimeStatus(_ rawValue: UInt32) -> NuxieRuntimeStatus {
    switch rawValue {
    case NUX_STATUS_OK: .ok
    case NUX_STATUS_NULL_ARGUMENT: .nullArgument
    case NUX_STATUS_IMPORT_ERROR: .importError
    case NUX_STATUS_NOT_FOUND: .notFound
    case NUX_STATUS_RUNTIME_ERROR: .runtimeError
    case NUX_STATUS_INVALID_ARGUMENT: .invalidArgument
    case NUX_STATUS_RUNTIME_IDENTITY_MISMATCH: .runtimeIdentityMismatch
    case NUX_STATUS_SURFACE_ERROR: .surfaceError
    default: .unknown(rawValue)
    }
}
#endif
