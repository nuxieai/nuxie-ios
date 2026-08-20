import Foundation

/// Canonical view-model paths used to project the persisted response session
/// into the active screen runtime.
enum ResponseProjectionPaths {
    static let state = VmPathRef(viewModelName: "vm", path: "response/state")

    static func value(field: String) -> VmPathRef {
        VmPathRef(viewModelName: "vm", path: "response/values/\(field)")
    }
}
