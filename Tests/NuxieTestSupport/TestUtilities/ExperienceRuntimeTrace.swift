import Foundation
import NuxieRuntime

/// Canonical runtime trace envelope for fixture parity checks.
/// This stays renderer-neutral so native runtime fixtures can share assertions.
struct ExperienceRuntimeTrace: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let fixtureId: String
    let runtime: String
    let entries: [ExperienceRuntimeTraceEntry]

    init(
        fixtureId: String,
        runtime: String,
        entries: [ExperienceRuntimeTraceEntry]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.fixtureId = fixtureId
        self.runtime = runtime
        self.entries = entries
    }
}

struct ExperienceRuntimeTraceEntry: Codable, Equatable {
    enum Kind: String, Codable {
        case event
        case navigation
        case binding
    }

    let step: Int
    let kind: Kind
    let name: String
    let screenId: String?
    let output: String?
    let metadata: [String: String]?
}

final class ExperienceRuntimeTraceRecorder {
    private let lock = NSLock()
    private var nextStep: Int = 1
    private var entries: [ExperienceRuntimeTraceEntry] = []

    func recordNavigation(screenId: String?, name: String = "navigate") {
        append(
            kind: .navigation,
            name: name,
            screenId: screenId,
            output: screenId,
            metadata: nil
        )
    }

    func recordRendererScreenChanged(screenId: String?) {
        recordNavigation(screenId: screenId, name: "screen_changed")
    }

    func recordRendererBindingChange(
        screenId: String?,
        path: String?,
        value: Any,
        source: String?,
        instanceId: String?
    ) {
        var bindingOutput: [String: Any] = ["value": value]
        if let path {
            bindingOutput["path"] = path
        }

        var metadata: [String: String] = [:]
        if let source {
            metadata["source"] = source
        }
        if let instanceId {
            metadata["instance_id"] = instanceId
        }

        append(
            kind: .binding,
            name: "did_set",
            screenId: screenId,
            output: Self.canonicalJSONString(from: bindingOutput),
            metadata: metadata.isEmpty ? nil : metadata
        )
    }

    func recordEvent(name: String, properties: [String: Any]?) {
        append(
            kind: .event,
            name: name,
            screenId: properties?["screen_id"] as? String,
            output: properties.map(Self.canonicalJSONString(from:)),
            metadata: nil
        )
    }

    func ingestTrackedEvents(_ trackedEvents: [(name: String, properties: [String: Any]?)]) {
        for trackedEvent in trackedEvents {
            recordEvent(name: trackedEvent.name, properties: trackedEvent.properties)
        }
    }

    func trace(
        fixtureId: String,
        runtime: String
    ) -> ExperienceRuntimeTrace {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        return ExperienceRuntimeTrace(
            fixtureId: fixtureId,
            runtime: runtime,
            entries: snapshot
        )
    }

    private func append(
        kind: ExperienceRuntimeTraceEntry.Kind,
        name: String,
        screenId: String?,
        output: String?,
        metadata: [String: String]?
    ) {
        lock.lock()
        entries.append(
            ExperienceRuntimeTraceEntry(
                step: nextStep,
                kind: kind,
                name: name,
                screenId: screenId,
                output: output,
                metadata: metadata
            )
        )
        nextStep += 1
        lock.unlock()
    }

    private static func canonicalJSONString(from value: Any) -> String {
        let normalized = normalizeJSONValue(value)
        if let object = normalized as? [String: Any], JSONSerialization.isValidJSONObject(object) {
            if
                let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                let string = String(data: data, encoding: .utf8)
            {
                return string
            }
        }

        if let array = normalized as? [Any], JSONSerialization.isValidJSONObject(array) {
            if
                let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys]),
                let string = String(data: data, encoding: .utf8)
            {
                return string
            }
        }

        return String(describing: normalized)
    }

    private static func normalizeJSONValue(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            var normalized: [String: Any] = [:]
            for key in dictionary.keys.sorted() {
                normalized[key] = normalizeJSONValue(dictionary[key] as Any)
            }
            return normalized

        case let array as [Any]:
            return array.map(normalizeJSONValue)

        case let number as NSNumber:
            return number

        case let string as String:
            return string

        case let bool as Bool:
            return bool

        case _ as NSNull:
            return NSNull()

        case let date as Date:
            return ISO8601DateFormatter().string(from: date)

        default:
            return String(describing: value)
        }
    }
}
