import Foundation
#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import NuxieRuntime
#endif

/// Names owned by the published page contract, never release metadata.
struct NativeExperiencePageHost: Equatable, Sendable {
    let artboardName: String
    let listPath: String
    static let published = Self(artboardName: ExperiencePageHostContract.artboardName,
                                listPath: ExperiencePageHostContract.screens)
}

enum ExperiencePageHostContract {
    static let artboardName = "$nuxie.page"
    static let machineName = "$nuxie.page"
    static let modelName = "$nuxie.Page"
    static let screens = "screens"

    struct Transition: Decodable {
        struct Endpoint: Decodable { let completeEventName: String }
        struct Reverse: Decodable {
            let durationMs: Int
            let source: Endpoint
            let destination: Endpoint
        }
        let id: String
        private enum PublishedKind: String, Decodable { case page }
        private let kind: PublishedKind
        private let defaultPair: Bool?
        var isDefaultPair: Bool { defaultPair == true }
        var planKind: NativeExperienceTransition.Kind { .page }
        let sourceScreenId: String
        let destinationScreenId: String
        let durationMs: Int
        let source: Endpoint
        let destination: Endpoint
        let reverse: Reverse?
    }

    #if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
    /// Host commands have no source instance in this ABI. Deliver each result once through the active row.
    static func hostCommands(_ commands: [NuxieNativeHostCommand], row: String, active: String?) -> [NuxieNativeHostCommand] {
        row == active ? commands : []
    }

    static func requirePage(in artboards: [NuxieNativeArtboardInfo]) throws {
        guard artboards.contains(where: { $0.name == artboardName && $0.stateMachines.contains(machineName) }) else {
            throw ExperienceInteractiveScreenError.stateContract("Published release requires the page artboard and machine")
        }
    }
    #endif
}
