import Foundation
#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import NuxieRuntime
#endif

/// Names owned by the published page contract, never release metadata.
struct NativeExperiencePageHost: Equatable, Sendable {
    enum InitialRows: Equatable, Sendable {
        case requireEmpty
        case clearBeforePlayer
    }

    let artboardName: String
    let listPath: String
    let machineName: String?
    let modelName: String?
    let hasLiveMoves: Bool
    let initialRows: InitialRows
    let stepNames: [String: String]

    // Non-published shapes are constructed by tests, never decoded from a release.
    // Nil machine/model use the inferred names those test shapes rely on.
    init(artboardName: String, listPath: String, machineName: String? = nil,
         modelName: String? = nil, hasLiveMoves: Bool = false,
         initialRows: InitialRows = .requireEmpty, stepNames: [String: String] = [:]) {
        self.artboardName = artboardName
        self.listPath = listPath
        self.machineName = machineName
        self.modelName = modelName
        self.hasLiveMoves = hasLiveMoves
        self.initialRows = initialRows
        self.stepNames = stepNames
    }

    static let published = Self(artboardName: ExperiencePageHostContract.artboardName,
                                listPath: ExperiencePageHostContract.screens,
                                machineName: ExperiencePageHostContract.machineName,
                                modelName: ExperiencePageHostContract.modelName,
                                hasLiveMoves: true)
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
