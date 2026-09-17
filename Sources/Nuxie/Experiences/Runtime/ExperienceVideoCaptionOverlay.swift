#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit

/// Captions remain individually addressable for simultaneous video occurrences.
/// Labels use Dynamic Type and VoiceOver text without stealing scene touches.
@MainActor
final class ExperienceVideoCaptionOverlay: UIStackView {
    private var labels: [Int: UILabel] = [:]

    init() {
        super.init(frame: .zero)
        axis = .vertical
        spacing = 4
        alignment = .fill
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityIdentifier = "nuxie-video-captions"
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ captions: [ExperienceInteractiveVideoCaption]) {
        let active = Set(captions.filter { !$0.text.isEmpty }.map(\.componentID))
        for id in Array(labels.keys) where !active.contains(id) {
            labels.removeValue(forKey: id)?.removeFromSuperview()
        }
        for (index, caption) in captions.filter({ !$0.text.isEmpty }).enumerated() {
            let label: UILabel
            if let existing = labels[caption.componentID] { label = existing }
            else {
                label = UILabel()
                label.numberOfLines = 0
                label.textAlignment = .center
                label.font = .preferredFont(forTextStyle: .body)
                label.adjustsFontForContentSizeCategory = true
                label.textColor = .label
                label.backgroundColor = .systemBackground
                label.isAccessibilityElement = true
                label.accessibilityTraits = .staticText
                label.accessibilityIdentifier = "nuxie-video-caption-\(caption.componentID)"
                labels[caption.componentID] = label
                addArrangedSubview(label)
            }
            if arrangedSubviews.firstIndex(of: label) != index {
                removeArrangedSubview(label)
                insertArrangedSubview(label, at: index)
            }
            if label.text != caption.text { label.text = caption.text }
            label.accessibilityLabel = caption.text
            label.accessibilityLanguage = caption.language.isEmpty ? nil : caption.language
        }
        // Do not post announcements for every cue: VoiceOver users can navigate
        // the current text without interrupting their current interaction.
    }
}
#endif
