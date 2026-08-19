import Foundation

/// Value-level logic for the experience response form (`set_response_field`,
/// `submit_response`, the `$response_set` Script Verb built-in, and draft
/// abandonment).
///
/// Data-in/data-out: response records, runtime view-model reads, and action
/// payloads in; view-model patches and cache entries out. All API calls and
/// view-model application stay in the runner. This shape is the portable
/// spec for other SDK platforms.
enum ResponseFormController {
    static let rootViewModelName = "vm"
    static let rootPropertyName = "response"
    static let valuesPropertyName = "values"

    // MARK: - Paths

    static var schemaIdPath: VmPathRef { path([rootPropertyName, "schemaId"]) }
    static var schemaVersionPath: VmPathRef { path([rootPropertyName, "schemaVersion"]) }
    static var statePath: VmPathRef { path([rootPropertyName, "state"]) }

    static func valuePath(forKey key: String) -> VmPathRef {
        path([rootPropertyName, valuesPropertyName, key])
    }

    struct Patch {
        let path: VmPathRef
        let value: Any
    }

    struct RuntimeContext {
        let schemaId: String?
        let schemaVersion: Int?
        let state: String?
    }

    static func readRuntimeContext(lookup: (VmPathRef) -> Any?) -> RuntimeContext {
        RuntimeContext(
            schemaId: lookup(schemaIdPath) as? String,
            schemaVersion: (lookup(schemaVersionPath) as? NSNumber)?.intValue
                ?? lookup(schemaVersionPath) as? Int,
            state: lookup(statePath) as? String
        )
    }

    static func contextMatches(
        _ context: RuntimeContext,
        responseSchemaId: String,
        schemaVersion: Int?
    ) -> Bool {
        guard context.schemaId == responseSchemaId else { return false }
        if let schemaVersion,
           let runtimeSchemaVersion = context.schemaVersion,
           runtimeSchemaVersion != schemaVersion { return false }
        return true
    }

    static func draftPatches(key: String, resolvedValue: Any) -> [Patch] {
        [
            Patch(path: valuePath(forKey: key), value: resolvedValue),
            Patch(path: statePath, value: "draft"),
        ]
    }

    static func recordPatches(
        for response: ResponseRecordPayload,
        touchedFieldKey: String? = nil
    ) -> [Patch] {
        var patches = [
            Patch(path: statePath, value: response.state),
            Patch(path: schemaVersionPath, value: response.schemaVersion),
        ]
        if let touchedFieldKey,
           let value = response.values[touchedFieldKey]?.value {
            patches.append(Patch(path: valuePath(forKey: touchedFieldKey), value: value))
        }
        return patches
    }

    static func cacheKey(responseSchemaId: String, schemaVersion: Int) -> String {
        "\(responseSchemaId):\(schemaVersion)"
    }

    static func updatedResponseCache(
        _ existing: [String: Any]?,
        adding response: ResponseRecordPayload
    ) -> [String: Any] {
        var cache = existing ?? [:]
        cache[cacheKey(responseSchemaId: response.responseSchemaId, schemaVersion: response.schemaVersion)] = [
            "responseId": response.id,
            "responseSchemaId": response.responseSchemaId,
            "schemaVersion": response.schemaVersion,
            "state": response.state,
            "values": response.values.mapValues(\.value),
        ]
        return cache
    }

    static func hasDraftResponses(_ responses: [String: Any]?) -> Bool {
        responses?.values.contains { value in
            guard let response = value as? [String: Any],
                  response["state"] as? String == "draft",
                  let values = response["values"] as? [String: Any] else { return false }
            return !values.isEmpty
        } ?? false
    }

    static func path(_ segments: [String]) -> VmPathRef {
        VmPathRef(
            viewModelName: rootViewModelName,
            path: segments.joined(separator: "/")
        )
    }

    // MARK: - $response_set built-in

    /// Synthesizes a `set_response_field` action for the `$response_set`
    /// Script Verb event (`Nuxie.response.set(field, value)` in screen
    /// scripts) against the experience-scoped response schema, so scripts never
    /// carry schema ids. Returns nil when the experience declares no response
    /// schema or the payload is malformed.
    static func synthesizedSetResponseField(
        schemaId: String?,
        eventProperties: [String: Any]
    ) -> SetResponseFieldAction? {
        guard let schemaId,
              !schemaId.isEmpty,
              let field = eventProperties["field"] as? String,
              !field.isEmpty,
              let value = eventProperties["value"]
        else { return nil }

        return SetResponseFieldAction(
            responseSchemaId: schemaId,
            key: field,
            value: AnyCodable(value)
        )
    }
}
