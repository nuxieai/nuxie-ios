#if canImport(NuxieRuntime)
import Foundation
import NuxieRuntime

/// Swift names for the fixed-width status values in the C ABI.
enum NuxieRuntimeStatus: Equatable, Sendable {
    case ok
    case nullArgument
    case importError
    case notFound
    case runtimeError
    case invalidArgument
    case abiMismatch
    case surfaceError
    case unknown(UInt32)
}

func copyNuxieRuntimeResult(
    callStatus: UInt32,
    result: inout OpaquePointer?,
    renderRequested: Bool
) throws -> FlowRuntimeOperationResult {
    try copyNuxieRuntimeResultSnapshot(
        callStatus: callStatus,
        result: &result,
        renderRequested: renderRequested
    ).operationResult
}

struct NuxieRuntimeResultSnapshot {
    let operationResult: FlowRuntimeOperationResult
    let scriptAuthorization: FlowRuntimeScriptAuthorization?
}

func copyNuxieRuntimeResultSnapshot(
    callStatus: UInt32,
    result: inout OpaquePointer?,
    renderRequested: Bool
) throws -> NuxieRuntimeResultSnapshot {
    guard let ownedResult = result else {
        if callStatus != NUX_STATUS_OK {
            throw NuxieRuntimeAdapterError.callFailed(
                status: nuxieRuntimeStatus(callStatus),
                diagnostic: nuxieRuntimeDiagnostic(
                    status: callStatus,
                    message: "native runtime returned no diagnostic result"
                )
            )
        }
        throw NuxieRuntimeAdapterError.missingOperationResult
    }
    result = nil
    defer { nux_operation_result_free(ownedResult) }

    let resultStatus = nux_operation_result_status(ownedResult)
    let structuredDiagnostics = try copyNuxieRuntimeDiagnostics(from: ownedResult)
    let diagnosticMessage = copyNuxieRuntimeDiagnostic(from: ownedResult)
    let failureStatus = callStatus != NUX_STATUS_OK ? callStatus : resultStatus
    if failureStatus != NUX_STATUS_OK {
        throw NuxieRuntimeAdapterError.callFailed(
            status: nuxieRuntimeStatus(failureStatus),
            diagnostic: structuredDiagnostics.first
                ?? nuxieRuntimeDiagnostic(
                    status: failureStatus,
                    message: diagnosticMessage.isEmpty
                        ? "native runtime operation failed"
                        : diagnosticMessage
                )
        )
    }

    let disposition = nuxieRuntimeSurfaceDisposition(
        nux_operation_result_surface_disposition(ownedResult)
    )
    let changed = nux_operation_result_changed(ownedResult)
    let renderOutcome: FlowRuntimeRenderOutcome
    if !renderRequested {
        renderOutcome = .notRequested
    } else if disposition == .presented {
        renderOutcome = .presented
    } else {
        renderOutcome = .skipped
    }
    var diagnostics = structuredDiagnostics
    if diagnostics.isEmpty, !diagnosticMessage.isEmpty {
        diagnostics = [
            FlowRuntimeDiagnostic(
                severity: .debug,
                code: "nux_runtime.ok",
                message: diagnosticMessage
            )
        ]
    }

    return NuxieRuntimeResultSnapshot(
        operationResult: FlowRuntimeOperationResult(
            renderOutcome: renderOutcome,
            surfaceDisposition: disposition,
            isDirty: changed,
            isSettled: !changed,
            orderedOutputs: [],
            diagnostics: diagnostics
        ),
        scriptAuthorization: try copyNuxieRuntimeScriptAuthorization(
            from: ownedResult
        )
    )
}

private func copyNuxieRuntimeScriptAuthorization(
    from result: OpaquePointer
) throws -> FlowRuntimeScriptAuthorization? {
    switch nux_operation_result_script_authorization(result) {
    case UInt32(NUX_SCRIPT_AUTHORIZATION_NOT_APPLICABLE):
        return nil
    case UInt32(NUX_SCRIPT_AUTHORIZATION_VISUAL_ONLY):
        return .visualOnly
    case UInt32(NUX_SCRIPT_AUTHORIZATION_AUTHENTICATED):
        var keyIdView = NuxByteView(data: nil, len: 0)
        guard nux_operation_result_authenticated_key_id(result, &keyIdView)
            == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "authenticated import omitted its key ID"
            )
        }
        let keyId = try copyNuxieRuntimeUTF8(
            keyIdView,
            label: "authenticated key ID"
        )
        guard !keyId.isEmpty else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "authenticated import returned an empty key ID"
            )
        }
        return .authorized(keyId: keyId)
    case let value:
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "unknown script authorization value \(value)"
        )
    }
}

private func copyNuxieRuntimeDiagnostics(
    from result: OpaquePointer
) throws -> [FlowRuntimeDiagnostic] {
    let count = nux_operation_result_diagnostic_count(result)
    guard count <= 1_024, count <= UInt64(Int.max) else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned too many diagnostics"
        )
    }
    var diagnostics: [FlowRuntimeDiagnostic] = []
    diagnostics.reserveCapacity(Int(count))
    var aggregateUTF8Bytes = 0
    for index in 0..<count {
        var view = NuxDiagnosticView(
            struct_size: UInt32(MemoryLayout<NuxDiagnosticView>.size),
            severity: UInt32(NUX_DIAGNOSTIC_SEVERITY_DEBUG),
            code: NuxByteView(data: nil, len: 0),
            message: NuxByteView(data: nil, len: 0)
        )
        guard nux_operation_result_diagnostic_at(result, index, &view)
            == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime diagnostic \(index) could not be read"
            )
        }
        let severity: FlowRuntimeDiagnostic.Severity
        switch view.severity {
        case UInt32(NUX_DIAGNOSTIC_SEVERITY_DEBUG):
            severity = .debug
        case UInt32(NUX_DIAGNOSTIC_SEVERITY_WARNING):
            severity = .warning
        case UInt32(NUX_DIAGNOSTIC_SEVERITY_FATAL):
            severity = .fatal
        default:
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime diagnostic \(index) has an unknown severity"
            )
        }
        let code = try copyNuxieRuntimeUTF8(view.code, label: "diagnostic code")
        guard !code.isEmpty else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime diagnostic \(index) has an empty code"
            )
        }
        let message = try copyNuxieRuntimeUTF8(
            view.message,
            label: "diagnostic message"
        )
        let (nextAggregate, overflowed) = aggregateUTF8Bytes.addingReportingOverflow(
            code.utf8.count + message.utf8.count
        )
        guard !overflowed, nextAggregate <= 8_388_608 else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime returned oversized aggregate diagnostics"
            )
        }
        aggregateUTF8Bytes = nextAggregate
        diagnostics.append(
            FlowRuntimeDiagnostic(
                severity: severity,
                code: code,
                message: message
            )
        )
    }
    return diagnostics
}

private func copyNuxieRuntimeUTF8(
    _ view: NuxByteView,
    label: String
) throws -> String {
    guard view.len <= UInt64(Int.max), view.len <= 4_194_304 else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned an oversized \(label)"
        )
    }
    guard view.len > 0 else { return "" }
    guard let bytes = view.data else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned a null \(label)"
        )
    }
    let data = Data(bytes: bytes, count: Int(view.len))
    guard let value = String(data: data, encoding: .utf8) else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned non-UTF-8 \(label)"
        )
    }
    return value
}

/// Copies the borrowed result view before `copyNuxieRuntimeResult` frees it.
private func copyNuxieRuntimeDiagnostic(from result: OpaquePointer) -> String {
    var view = NuxByteView(data: nil, len: 0)
    let status = nux_operation_result_diagnostic(result, &view)
    guard status == NUX_STATUS_OK else {
        return "native runtime diagnostic could not be read"
    }
    guard view.len > 0 else { return "" }
    guard let bytes = view.data,
          view.len <= UInt64(Int.max),
          view.len <= 4_194_304 else {
        return "native runtime returned an invalid diagnostic view"
    }
    let copiedBytes = Data(bytes: bytes, count: Int(view.len))
    return String(decoding: copiedBytes, as: UTF8.self)
}

private func nuxieRuntimeDiagnostic(
    status: UInt32,
    message: String
) -> FlowRuntimeDiagnostic {
    FlowRuntimeDiagnostic(
        severity: .fatal,
        code: "nux_runtime.\(nuxieRuntimeStatusCode(status))",
        message: message
    )
}

func nuxieRuntimeStatus(_ rawValue: UInt32) -> NuxieRuntimeStatus {
    switch rawValue {
    case NUX_STATUS_OK: .ok
    case NUX_STATUS_NULL_ARGUMENT: .nullArgument
    case NUX_STATUS_IMPORT_ERROR: .importError
    case NUX_STATUS_NOT_FOUND: .notFound
    case NUX_STATUS_RUNTIME_ERROR: .runtimeError
    case NUX_STATUS_INVALID_ARGUMENT: .invalidArgument
    case NUX_STATUS_ABI_MISMATCH: .abiMismatch
    case NUX_STATUS_SURFACE_ERROR: .surfaceError
    default: .unknown(rawValue)
    }
}

private func nuxieRuntimeStatusCode(_ rawValue: UInt32) -> String {
    switch nuxieRuntimeStatus(rawValue) {
    case .ok: "ok"
    case .nullArgument: "null_argument"
    case .importError: "import_error"
    case .notFound: "not_found"
    case .runtimeError: "runtime_error"
    case .invalidArgument: "invalid_argument"
    case .abiMismatch: "abi_mismatch"
    case .surfaceError: "surface_error"
    case .unknown(let value): "unknown_\(value)"
    }
}

func nuxieRuntimeSurfaceDisposition(
    _ rawValue: UInt32
) -> FlowRuntimeSurfaceDisposition {
    switch rawValue {
    case NUX_SURFACE_DISPOSITION_NONE: .none
    case NUX_SURFACE_DISPOSITION_PRESENTED: .presented
    case NUX_SURFACE_DISPOSITION_SKIPPED_ZERO_SIZE: .skippedZeroSize
    case NUX_SURFACE_DISPOSITION_SKIPPED_TIMEOUT: .skippedTimeout
    case NUX_SURFACE_DISPOSITION_SKIPPED_OCCLUDED: .skippedOccluded
    case NUX_SURFACE_DISPOSITION_RECONFIGURED: .reconfigured
    case NUX_SURFACE_DISPOSITION_RECREATED: .recreated
    case NUX_SURFACE_DISPOSITION_DEVICE_LOST: .deviceLost
    case NUX_SURFACE_DISPOSITION_OUT_OF_MEMORY: .outOfMemory
    case NUX_SURFACE_DISPOSITION_FATAL: .fatal
    default: .unknown(rawValue)
    }
}

#endif
