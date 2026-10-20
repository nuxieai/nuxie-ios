import Foundation
#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import NuxieRuntime
#endif

/// Provisional publish metadata until UNIV-5113 supplies the final contract.
struct NativeExperienceLayerHost: Equatable, Sendable {
    let artboardName: String
    let listPath: String
}

enum ExperienceLayerHostContract {
    private struct Host: Decodable {
        let artboardName: String
        let list: String
    }

    private enum CodingKeys: String, CodingKey { case layerHost }

    static func decode(from decoder: Decoder) throws -> NativeExperienceLayerHost? {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        return try fields.decodeIfPresent(Host.self, forKey: .layerHost).map {
            NativeExperienceLayerHost(artboardName: $0.artboardName, listPath: $0.list)
        }
    }

    struct Transition: Decodable {
        struct Endpoint: Decodable { let completeEventName: String }
        struct Reverse: Decodable {
            let durationMs: Int?
            let incomingOnTop: Bool?
            let source: Endpoint
            let destination: Endpoint
        }

        let id: String
        private enum PublishedKind: String, Decodable { case layer, choreographed }
        private let kind: PublishedKind
        private let defaultPair: Bool?
        var isDefaultPair: Bool { defaultPair == true }
        var planKind: NativeExperienceTransition.Kind {
            switch kind {
            case .layer: .layer
            case .choreographed: .choreographed
            }
        }
        let sourceScreenId: String
        let destinationScreenId: String
        let durationMs: Int
        let incomingOnTop: Bool
        let source: Endpoint
        let destination: Endpoint
        let reverse: Reverse?
    }

    #if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
    struct RowSelection {
        let schemaIndex: Int
        let authoredInstanceIndex: Int?
    }

    /// Each Screen has one distinct type whose schema default is its authored root.
    /// The publisher should supply the schema and artboard-default instance indices.
    static func rowSelection(screen: JourneyScreen, catalog: NuxieNativeViewModelCatalog)
        throws -> RowSelection {
        let matches = catalog.schemas.filter { $0.name == screen.defaultViewModelName }
        guard matches.count == 1, let schema = matches.first else {
            throw ExperienceInteractiveScreenError.stateContract("Layer row requires a unique Screen root type")
        }
        // Catalog defaults index the flat table; allocation takes a schema-local index.
        let authoredIndex: Int?
        if let index = schema.defaultAuthoredInstance {
            guard catalog.authoredInstances.indices.contains(index),
                  catalog.authoredInstances[index].schemaIndex == schema.index else {
                throw ExperienceInteractiveScreenError.stateContract("Layer row has an invalid authored default")
            }
            authoredIndex = catalog.authoredInstances[index].index
        } else {
            authoredIndex = nil
        }
        return .init(schemaIndex: schema.index, authoredInstanceIndex: authoredIndex)
    }
    #endif
}
