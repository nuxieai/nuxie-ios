#if os(iOS) && !targetEnvironment(macCatalyst)
@_exported import NuxieRuntimeFFI
#endif

/// The Swift-native Apple adapter module for the Nuxie runtime.
///
/// Product SDK code depends on this module. The binary target beneath it is a
/// C FFI implementation detail and is intentionally not part of the SDK seam.
public enum NuxieRuntimeModule: Sendable {}
