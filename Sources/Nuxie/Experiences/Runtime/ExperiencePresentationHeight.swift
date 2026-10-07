import Foundation
import NuxieRuntime

/// One platform-owned height instance belongs to one player.
actor ExperiencePresentationHeight {
    private struct Contract: Decodable, Sendable {
        struct Property: Decodable, Sendable {
            struct Values: Decodable, Sendable { let fixed: Float; let hug: Float }
            let name: String
            let type: String
            let values: Values
        }
        let version: Int
        let globalName: String
        let property: Property
    }
    private final class ResourceToken {}
    private static let contract: Result<Contract, Error> = Result {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: ResourceToken.self)
        #endif
        guard let url = bundle.url(forResource: "presentation-schema", withExtension: "json") else {
            throw NSError(domain: "Missing presentation schema resource", code: 1)
        }
        let value = try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))
        guard value.version == 1, value.property.type == "number" else {
            throw NSError(domain: "Unsupported presentation schema", code: 1)
        }
        return value
    }

    private var resolved = false
    private var instance: NuxieNativeViewModelReference?

    func apply(to runtime: NuxieNativeRuntime, fitContent: Bool, width: Float, height: Float) async throws -> Bool {
        let contract = try Self.contract.get()
        if !resolved {
            let catalog = try await runtime.viewModelCatalog()
            if let schema = catalog.schemas.first(where: { $0.isGlobal && $0.name == contract.globalName }),
               catalog.properties.contains(where: {
                   $0.schemaIndex == schema.index && $0.name == contract.property.name && $0.kind == .number
               }) {
                let value = try await runtime.makeViewModel(schemaIndex: schema.index)
                try await runtime.setGlobalViewModel(name: contract.globalName, instance: value)
                instance = value
            }
            resolved = true
        }
        try await runtime.setLayoutSize(width: width, height: height)
        if let instance {
            _ = try await runtime.mutateViewModel([.setNumber(instance: instance,
                path: contract.property.name, value: fitContent ? contract.property.values.hug : contract.property.values.fixed)])
        }
        return instance != nil
    }
}
