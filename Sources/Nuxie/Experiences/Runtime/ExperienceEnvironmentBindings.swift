#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import NuxieRuntime

/// Resolves only slots declared by an artifact, preserving older env schemas.
struct ExperienceEnvironmentBindings: Sendable {
    private let properties: [String: NuxieNativeViewModelCatalog.Property]

    init(catalog: NuxieNativeViewModelCatalog) {
        var resolved: [String: NuxieNativeViewModelCatalog.Property] = [:]
        func walk(_ schema: Int, prefix: String, ancestors: Set<Int>) {
            guard !ancestors.contains(schema) else { return }
            for property in catalog.properties where property.schemaIndex == schema {
                let path = prefix + property.name
                resolved[path] = property
                if let child = property.referencedSchemaIndex {
                    walk(child, prefix: path + "/", ancestors: ancestors.union([schema]))
                }
            }
        }
        if let env = catalog.schemas.first(where: { $0.name == "env" && $0.isGlobal }) {
            walk(env.index, prefix: "", ancestors: [])
        }
        properties = resolved
    }

    func mutations(reference: NuxieNativeViewModelReference, reduceMotion: Bool? = nil,
                   safeArea: ExperienceSafeAreaInsets? = nil,
                   viewport: ExperienceViewportEnvironment? = nil,
                   fold: ExperienceFoldEnvironment? = nil) -> [NuxieNativeViewModelMutation] {
        var result: [NuxieNativeViewModelMutation] = []
        func number(_ path: String, _ value: Float) {
            if properties[path]?.kind == .number {
                result.append(.setNumber(instance: reference, path: path, value: value))
            }
        }
        func boolean(_ path: String, _ value: Bool) {
            if properties[path]?.kind == .bool {
                result.append(.setBool(instance: reference, path: path, value: value))
            }
        }
        if let reduceMotion { boolean("reduceMotion", reduceMotion) }
        if let safeArea {
            for (edge, value) in [("top", safeArea.top), ("right", safeArea.right),
                                  ("bottom", safeArea.bottom), ("left", safeArea.left)] {
                number("safeArea/" + edge, Float(value))
            }
        }
        if let viewport {
            number("width", viewport.width)
            number("height", viewport.height)
        }
        if let fold {
            boolean("fold/available", fold.available)
            number("fold/openProgress", fold.openProgress)
            number("fold/foldProgress", fold.foldProgress)
            if let property = properties["fold/state"], property.kind == .enumeration,
               let index = property.enumLabels.firstIndex(of: fold.state.label) {
                result.append(.setEnumeration(instance: reference, path: "fold/state", value: UInt64(index)))
            }
        }
        return result
    }
}
#endif
