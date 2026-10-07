import Foundation

/// Native geometry for one modal layer. Content-height sheets await the root Hug seam.
struct ExperienceLayerPresentation: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case sheet, fullscreen }
    enum Height: String, Codable, Sendable { case large, medium; case fitContent = "fit-content" }
    enum ClosedBy: String, Codable, Sendable { case any, none }

    var kind: Kind = .sheet
    var height: Height = .large
    var closedBy: ClosedBy = .any
    var dismissible: Bool { closedBy == .any }
    var isAvailable: Bool { kind != .sheet || height != .fitContent }

    static let modalDefault = Self()

}

#if canImport(UIKit)
import UIKit

@MainActor
final class ExperienceLayerPresentationConfigurator {
    private let presentation: ExperienceLayerPresentation

    init(presentation: ExperienceLayerPresentation) {
        self.presentation = presentation
    }

    func configure(_ controller: UIViewController) {
        precondition(presentation.isAvailable, "Content-height sheets await the runtime root Hug seam")
        controller.isModalInPresentation = !presentation.dismissible
        switch presentation.kind {
        case .sheet:
            controller.modalPresentationStyle = .pageSheet
            controller.sheetPresentationController?.detents = presentation.height == .medium
                ? [.medium()] : [.large()]
            controller.sheetPresentationController?.prefersGrabberVisible = presentation.dismissible
        case .fullscreen:
            controller.modalPresentationStyle = .fullScreen
        }
    }
}
#endif
