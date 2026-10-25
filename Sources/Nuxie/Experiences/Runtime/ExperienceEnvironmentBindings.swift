#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import NuxieRuntime

/// Resolves only slots declared by an artifact, preserving older env schemas.
struct ExperienceEnvironmentBindings: Sendable {
    /// The global whose authored `light` and `dark` instances carry an Experience's themed colors.
    static let themeGlobalName = "Theme"

    private let properties: [String: NuxieNativeViewModelCatalog.Property]
    private let themeSelections: [ExperienceColorScheme: NuxieNativeAuthoredGlobalSelection]

    init(catalog: NuxieNativeViewModelCatalog) {
        var themes: [ExperienceColorScheme: NuxieNativeAuthoredGlobalSelection] = [:]
        for scheme in ExperienceColorScheme.allCases {
            themes[scheme] = catalog.authoredGlobalSelection(named: Self.themeGlobalName,
                instanceNamed: scheme.label)
        }
        themeSelections = themes
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
                   fontScale: Double? = nil,
                   safeArea: ExperienceSafeAreaInsets? = nil,
                   viewport: ExperienceViewportEnvironment? = nil,
                   fold: ExperienceFoldEnvironment? = nil,
                   colorScheme: ExperienceColorScheme? = nil) -> [NuxieNativeViewModelMutation] {
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
        // Enums are written by the index of their label in the artifact's own label order.
        func enumeration(_ path: String, _ label: String) {
            if let property = properties[path], property.kind == .enumeration,
               let index = property.enumLabels.firstIndex(of: label) {
                result.append(.setEnumeration(instance: reference, path: path, value: UInt64(index)))
            }
        }
        if let reduceMotion { boolean("reduceMotion", reduceMotion) }
        if let fontScale { number("fontScale", Float(fontScale)) }
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
            enumeration("fold/state", fold.state.label)
        }
        if let colorScheme { enumeration("colorScheme", colorScheme.label) }
        return result
    }

    /// The `Theme` instance to bind for this appearance, or nil when the artifact has no theme.
    func themeSelection(for colorScheme: ExperienceColorScheme) -> NuxieNativeAuthoredGlobalSelection? {
        themeSelections[colorScheme]
    }
}
#endif
