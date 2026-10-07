import Foundation
import NuxieRuntime

/// One platform-owned height instance belongs to one player.
actor ExperiencePresentationHeight {
    // Temporary shared-contract constants authorized by the coordinator.
    // Replace with the named presentation-schema.json revision when supplied.
    static let globalName = "$nuxie.presentation"
    static let propertyName = "heightMode"
    static let fixed: Float = 0
    static let hug: Float = 2

    private var resolved = false
    private var instance: NuxieNativeViewModelReference?

    func apply(to runtime: NuxieNativeRuntime, fitContent: Bool, width: Float, height: Float) async throws -> Bool {
        if !resolved {
            let catalog = try await runtime.viewModelCatalog()
            if let schema = catalog.schemas.first(where: { $0.isGlobal && $0.name == Self.globalName }),
               catalog.properties.contains(where: {
                   $0.schemaIndex == schema.index && $0.name == Self.propertyName && $0.kind == .number
               }) {
                let value = try await runtime.makeViewModel(schemaIndex: schema.index)
                try await runtime.setGlobalViewModel(name: Self.globalName, instance: value)
                instance = value
            }
            resolved = true
        }
        try await runtime.setLayoutSize(width: width, height: height)
        if let instance {
            _ = try await runtime.mutateViewModel([.setNumber(instance: instance,
                path: Self.propertyName, value: fitContent ? Self.hug : Self.fixed)])
        }
        return instance != nil
    }
}
