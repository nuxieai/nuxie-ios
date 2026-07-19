#if canImport(RiveRuntime) && canImport(UIKit)
import Foundation
import RiveRuntime
import UIKit

@MainActor
final class FlowTextInputOverlayBridge: NSObject, UITextFieldDelegate, UITextViewDelegate {
    private final class TextField: UITextField {
        override func textRect(forBounds bounds: CGRect) -> CGRect { bounds }
        override func editingRect(forBounds bounds: CGRect) -> CGRect { bounds }
        override func placeholderRect(forBounds bounds: CGRect) -> CGRect { bounds }
    }

    @MainActor
    private enum Control {
        case field(TextField)
        case textView(UITextView)

        var view: UIView {
            switch self {
            case .field(let field):
                return field
            case .textView(let textView):
                return textView
            }
        }

        var text: String {
            get {
                switch self {
                case .field(let field):
                    return field.text ?? ""
                case .textView(let textView):
                    return textView.text ?? ""
                }
            }
            nonmutating set {
                switch self {
                case .field(let field):
                    field.text = newValue
                case .textView(let textView):
                    textView.text = newValue
                }
            }
        }
    }

    private struct Binding {
        let input: FlowArtifactTextInput
        let control: Control
    }

    private struct RuntimeGeometry {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
        let rotation: CGFloat
        let scaleX: CGFloat
        let scaleY: CGFloat
    }

    private weak var riveView: RiveView?
    private weak var riveViewModel: RiveViewModel?
    private weak var viewModelBridge: FlowViewModelBridge?
    private var activeScreen: FlowArtifactScreen?
    private var bindingsByInputId: [String: Binding] = [:]
    private var textValuesByInputId: [String: String] = [:]
    private var committedTextByInputId: [String: String] = [:]
    private var activeBuildId: String?
    private var fontSHA256ByRiveUniqueName: [String: String] = [:]
    private var hidden = false
    private weak var activeEditingControl: UIView?
    private var keyboardShift: CGFloat = 0
    private var dismissTapRecognizer: UITapGestureRecognizer?

    /// Fired when an editable input ends editing with a value that changed
    /// since its last commit. The host decides what a commit means (response
    /// capture); the bridge only owns the native editing lifecycle.
    var onCommitText: ((FlowArtifactTextInput, String) -> Void)?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    func bind(
        screenId: String,
        artifact: LoadedFlowArtifact,
        riveView: RiveView,
        riveViewModel: RiveViewModel,
        viewModelBridge: FlowViewModelBridge
    ) {
        if activeBuildId != artifact.manifest.buildId {
            textValuesByInputId.removeAll()
            committedTextByInputId.removeAll()
            activeBuildId = artifact.manifest.buildId
        }
        clear()

        self.riveView = riveView
        self.riveViewModel = riveViewModel
        self.viewModelBridge = viewModelBridge
        activeScreen = artifact.manifest.screens.first { $0.screenId == screenId }
        fontSHA256ByRiveUniqueName = artifact.manifest.assets.fonts.reduce(into: [:]) {
            $0[$1.riveUniqueName] = $1.sha256
        }

        guard activeScreen != nil else {
            return
        }

        for input in artifact.manifest.textInputs where input.screenId == screenId && input.editable {
            let control = makeControl(for: input)
            control.view.accessibilityIdentifier = "nuxie-text-input-\(input.inputId)"
            control.view.isAccessibilityElement = true
            control.view.isHidden = hidden
            control.text = textValuesByInputId[input.inputId] ?? input.value
            // Seed the committed baseline so blur-without-change never emits.
            if committedTextByInputId[input.inputId] == nil {
                committedTextByInputId[input.inputId] = control.text
            }
            setRiveTextRunValue(control.text, for: input, using: riveViewModel)

            riveView.addSubview(control.view)
            bindingsByInputId[input.inputId] = Binding(input: input, control: control)
        }

        installDismissTapRecognizer(on: riveView)
        layout()
    }

    func clear() {
        for binding in bindingsByInputId.values {
            binding.control.view.removeFromSuperview()
        }
        bindingsByInputId.removeAll()
        if let dismissTapRecognizer {
            dismissTapRecognizer.view?.removeGestureRecognizer(dismissTapRecognizer)
        }
        dismissTapRecognizer = nil
        activeEditingControl = nil
        applyKeyboardShift(0, animationDuration: 0)
        activeScreen = nil
        fontSHA256ByRiveUniqueName.removeAll()
        riveView = nil
        riveViewModel = nil
        viewModelBridge = nil
    }

    func setHidden(_ isHidden: Bool) {
        hidden = isHidden
        for binding in bindingsByInputId.values {
            binding.control.view.isHidden = isHidden
        }
    }

    func layout() {
        guard let riveView,
              let screen = activeScreen else {
            return
        }

        let metrics = Self.contentMetrics(
            viewBounds: riveView.bounds,
            screenWidth: screen.width,
            screenHeight: screen.height
        )

        for binding in bindingsByInputId.values {
            guard let geometry = runtimeGeometry(for: binding.input) else {
                binding.control.view.isHidden = true
                continue
            }
            binding.control.view.isHidden = hidden
            let frame = Self.frame(
                for: geometry,
                metrics: metrics
            )
            let styleScaleX = metrics.scale * max(0, geometry.scaleX)
            let styleScaleY = metrics.scale * max(0, geometry.scaleY)
            applyStyle(
                binding.input.style,
                to: binding.control,
                fontScale: styleScaleY,
                horizontalScale: styleScaleX,
                secure: binding.input.secureTextEntry == true
            )

            UIView.performWithoutAnimation {
                binding.control.view.transform = .identity
                binding.control.view.bounds = CGRect(origin: .zero, size: frame.size)
                binding.control.view.center = CGPoint(x: frame.midX, y: frame.midY)
                if geometry.rotation != 0 {
                    binding.control.view.transform = CGAffineTransform(rotationAngle: geometry.rotation)
                }
            }
        }
    }

    static func contentMetrics(
        viewBounds: CGRect,
        screenWidth: Double,
        screenHeight: Double
    ) -> (origin: CGPoint, scale: CGFloat) {
        guard screenWidth > 0,
              screenHeight > 0,
              viewBounds.width > 0,
              viewBounds.height > 0 else {
            return (.zero, 1)
        }

        let scale = min(
            viewBounds.width / CGFloat(screenWidth),
            viewBounds.height / CGFloat(screenHeight)
        )
        let contentWidth = CGFloat(screenWidth) * scale
        let contentHeight = CGFloat(screenHeight) * scale
        return (
            CGPoint(
                x: viewBounds.minX + (viewBounds.width - contentWidth) / 2,
                y: viewBounds.minY + (viewBounds.height - contentHeight) / 2
            ),
            scale
        )
    }

    private static func frame(
        for geometry: RuntimeGeometry,
        metrics: (origin: CGPoint, scale: CGFloat)
    ) -> CGRect {
        let scaleX = max(0, geometry.scaleX)
        let scaleY = max(0, geometry.scaleY)
        return CGRect(
            x: metrics.origin.x + geometry.x * metrics.scale,
            y: metrics.origin.y + geometry.y * metrics.scale,
            width: geometry.width * metrics.scale * scaleX,
            height: geometry.height * metrics.scale * scaleY
        )
    }

    private func runtimeGeometry(for input: FlowArtifactTextInput) -> RuntimeGeometry? {
        guard let viewModelBridge,
              let x = try? viewModelBridge.numberValue(path: input.geometry.xPath),
              let y = try? viewModelBridge.numberValue(path: input.geometry.yPath),
              let width = try? viewModelBridge.numberValue(path: input.geometry.widthPath),
              let height = try? viewModelBridge.numberValue(path: input.geometry.heightPath),
              let rotation = try? viewModelBridge.numberValue(path: input.geometry.rotationPath),
              let scaleX = try? viewModelBridge.numberValue(path: input.geometry.scaleXPath),
              let scaleY = try? viewModelBridge.numberValue(path: input.geometry.scaleYPath),
              width > 0,
              height > 0 else {
            return nil
        }

        return RuntimeGeometry(
            x: CGFloat(x),
            y: CGFloat(y),
            width: CGFloat(width),
            height: CGFloat(height),
            rotation: CGFloat(rotation),
            scaleX: CGFloat(scaleX),
            scaleY: CGFloat(scaleY)
        )
    }

    private func makeControl(for input: FlowArtifactTextInput) -> Control {
        if input.multiline == true && input.secureTextEntry != true {
            let textView = UITextView(frame: .zero)
            textView.delegate = self
            textView.backgroundColor = .clear
            textView.textContainerInset = .zero
            textView.textContainer.lineFragmentPadding = 0
            textView.isScrollEnabled = true
            textView.keyboardType = Self.keyboardType(input.keyboardType)
            textView.autocorrectionType = .default
            textView.spellCheckingType = .default
            return .textView(textView)
        }

        let field = TextField(frame: .zero)
        field.delegate = self
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.placeholder = input.placeholder
        field.keyboardType = Self.keyboardType(input.keyboardType)
        field.isSecureTextEntry = input.secureTextEntry == true
        field.returnKeyType = .done
        field.autocorrectionType = .default
        field.spellCheckingType = .default
        field.addTarget(self, action: #selector(textFieldEditingChanged(_:)), for: .editingChanged)
        return .field(field)
    }

    private func applyStyle(
        _ style: FlowArtifactTextInputStyle,
        to control: Control,
        fontScale: CGFloat,
        horizontalScale: CGFloat,
        secure: Bool
    ) {
        let fontSize = max(1, CGFloat(style.fontSize) * fontScale)
        let font = Self.font(
            for: style,
            contentSHA256: fontSHA256ByRiveUniqueName[style.fontAssetRiveUniqueName],
            size: fontSize
        )
        let color = UIColor(nuxieARGB: style.color)
        let textColor: UIColor = secure ? color : .clear
        let alignment = Self.textAlignment(style.textAlign)

        switch control {
        case .field(let field):
            field.font = font
            field.textAlignment = alignment
            field.textColor = textColor
            field.tintColor = color
            field.adjustsFontSizeToFitWidth = false

            var attributes = field.defaultTextAttributes
            attributes[.font] = font
            attributes[.foregroundColor] = textColor
            if style.letterSpacing != 0 {
                attributes[.kern] = CGFloat(style.letterSpacing) * horizontalScale
            } else {
                attributes.removeValue(forKey: .kern)
            }
            if style.lineHeight > 0 {
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = CGFloat(style.lineHeight) * fontScale
                paragraph.maximumLineHeight = CGFloat(style.lineHeight) * fontScale
                paragraph.alignment = alignment
                attributes[.paragraphStyle] = paragraph
            } else {
                attributes.removeValue(forKey: .paragraphStyle)
            }
            field.defaultTextAttributes = attributes

            if let placeholder = field.placeholder, !placeholder.isEmpty {
                field.attributedPlaceholder = NSAttributedString(
                    string: placeholder,
                    attributes: [
                        .font: font,
                        .foregroundColor: color.withAlphaComponent(0.45),
                    ]
                )
            }

        case .textView(let textView):
            textView.font = font
            textView.textAlignment = alignment
            textView.textColor = textColor
            textView.tintColor = color

            var attributes = textView.typingAttributes
            attributes[.font] = font
            attributes[.foregroundColor] = textColor
            if style.letterSpacing != 0 {
                attributes[.kern] = CGFloat(style.letterSpacing) * horizontalScale
            } else {
                attributes.removeValue(forKey: .kern)
            }
            if style.lineHeight > 0 {
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = CGFloat(style.lineHeight) * fontScale
                paragraph.maximumLineHeight = CGFloat(style.lineHeight) * fontScale
                paragraph.alignment = alignment
                attributes[.paragraphStyle] = paragraph
            } else {
                attributes.removeValue(forKey: .paragraphStyle)
            }
            textView.typingAttributes = attributes
        }
    }

    @objc private func textFieldEditingChanged(_ sender: UITextField) {
        propagateTextChange(from: sender)
    }

    func textViewDidChange(_ textView: UITextView) {
        propagateTextChange(from: textView)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return false
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        beginEditingSession(for: textField)
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        beginEditingSession(for: textView)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        endEditingSession(for: textField)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        endEditingSession(for: textView)
    }

    private func beginEditingSession(for control: UIView) {
        activeEditingControl = control
        avoidKeyboardIfNeeded(animationDuration: Self.defaultKeyboardAnimationDuration)
    }

    private func endEditingSession(for control: UIView) {
        if activeEditingControl === control {
            activeEditingControl = nil
        }
        commitTextIfChanged(for: control)
    }

    /// Commit = end of an editing session with a changed value. Return
    /// resigns single-line fields (so it lands here) and multiline text views
    /// commit on blur, matching the editor preview semantics.
    func commitTextIfChanged(for control: UIView) {
        guard let binding = binding(for: control) else {
            return
        }
        // Re-propagate the final value: keystrokes already did, but
        // programmatic/autofill text changes bypass .editingChanged.
        propagateTextChange(from: control)
        let text = binding.control.text
        guard committedTextByInputId[binding.input.inputId] != text else {
            return
        }
        committedTextByInputId[binding.input.inputId] = text
        onCommitText?(binding.input, text)
    }

    // MARK: Keyboard avoidance

    private static let defaultKeyboardAnimationDuration: TimeInterval = 0.25
    private static let keyboardPadding: CGFloat = 12

    private var latestKeyboardFrame: CGRect?

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }
        latestKeyboardFrame = frame
        avoidKeyboardIfNeeded(animationDuration: animationDuration(from: notification))
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        latestKeyboardFrame = nil
        applyKeyboardShift(0, animationDuration: animationDuration(from: notification))
    }

    private func animationDuration(from notification: Notification) -> TimeInterval {
        (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval)
            ?? Self.defaultKeyboardAnimationDuration
    }

    private func avoidKeyboardIfNeeded(animationDuration: TimeInterval) {
        guard let control = activeEditingControl,
              let keyboardFrame = latestKeyboardFrame,
              let window = control.window else {
            return
        }
        let controlFrame = control.convert(control.bounds, to: nil)
        let keyboardMinY = window.convert(keyboardFrame, from: nil).minY
        let shift = Self.keyboardShift(
            controlFrameInWindow: controlFrame,
            currentShift: keyboardShift,
            keyboardMinY: keyboardMinY,
            padding: Self.keyboardPadding
        )
        applyKeyboardShift(shift, animationDuration: animationDuration)
    }

    /// Pure shift math: how far the surface must translate up so the focused
    /// control clears the keyboard. `controlFrameInWindow` reflects the
    /// current (already shifted) render, so the current shift is undone
    /// before comparing against the keyboard's top edge.
    static func keyboardShift(
        controlFrameInWindow: CGRect,
        currentShift: CGFloat,
        keyboardMinY: CGFloat,
        padding: CGFloat
    ) -> CGFloat {
        let unshiftedMaxY = controlFrameInWindow.maxY + currentShift
        return max(0, unshiftedMaxY + padding - keyboardMinY)
    }

    private func applyKeyboardShift(_ shift: CGFloat, animationDuration: TimeInterval) {
        guard keyboardShift != shift else {
            return
        }
        keyboardShift = shift
        guard let riveView else {
            return
        }
        let transform: CGAffineTransform = shift == 0
            ? .identity
            : CGAffineTransform(translationX: 0, y: -shift)
        guard animationDuration > 0 else {
            riveView.transform = transform
            return
        }
        UIView.animate(withDuration: animationDuration, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
            riveView.transform = transform
        }
    }

    // MARK: Tap-outside dismissal

    private func installDismissTapRecognizer(on riveView: RiveView) {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDismissTap(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delegate = self
        riveView.addGestureRecognizer(recognizer)
        dismissTapRecognizer = recognizer
    }

    @objc private func handleDismissTap(_ recognizer: UITapGestureRecognizer) {
        riveView?.endEditing(true)
    }

    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        shouldAllowChange(currentText: textField.text ?? "", range: range, replacement: string, control: textField)
    }

    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        shouldAllowChange(currentText: textView.text ?? "", range: range, replacement: text, control: textView)
    }

    private func shouldAllowChange(
        currentText: String,
        range: NSRange,
        replacement: String,
        control: UIView
    ) -> Bool {
        guard let input = binding(for: control)?.input,
              let maxLength = input.maxLength,
              maxLength > 0,
              let textRange = Range(range, in: currentText) else {
            return true
        }

        let nextText = currentText.replacingCharacters(in: textRange, with: replacement)
        return nextText.count <= maxLength
    }

    private func propagateTextChange(from control: UIView) {
        guard let binding = binding(for: control),
              let riveViewModel else {
            return
        }

        let nextText = binding.control.text
        textValuesByInputId[binding.input.inputId] = nextText
        setRiveTextRunValue(nextText, for: binding.input, using: riveViewModel)
    }

    private func setRiveTextRunValue(
        _ text: String,
        for input: FlowArtifactTextInput,
        using riveViewModel: RiveViewModel
    ) {
        let renderedText = input.secureTextEntry == true ? "" : text

        do {
            try riveViewModel.setTextRunValue(input.riveTextRunName, textValue: renderedText)
        } catch {
            LogWarning("FlowTextInputOverlayBridge: failed to update text run \(input.riveTextRunName): \(error)")
        }
    }

    private func binding(for control: UIView) -> Binding? {
        bindingsByInputId.values.first { $0.control.view === control }
    }

    private static func font(
        for style: FlowArtifactTextInputStyle,
        contentSHA256: String?,
        size: CGFloat
    ) -> UIFont {
        if let contentSHA256,
           let font = FlowRuntimeFontRegistry.font(
               forRiveUniqueName: style.fontAssetRiveUniqueName,
               contentSHA256: contentSHA256,
               size: size
           ) {
            return font
        }

        let traits: UIFontDescriptor.SymbolicTraits = style.fontStyle == "italic" ? .traitItalic : []
        let descriptor = UIFont.systemFont(ofSize: size, weight: fontWeight(style.fontWeight))
            .fontDescriptor
            .withSymbolicTraits(traits)
        if let descriptor {
            return UIFont(descriptor: descriptor, size: size)
        }
        return UIFont.systemFont(ofSize: size, weight: fontWeight(style.fontWeight))
    }

    private static func fontWeight(_ value: String) -> UIFont.Weight {
        guard let weight = Int(value) else {
            return .regular
        }

        switch weight {
        case ..<250:
            return .ultraLight
        case 250..<350:
            return .light
        case 350..<450:
            return .regular
        case 450..<550:
            return .medium
        case 550..<650:
            return .semibold
        case 650..<750:
            return .bold
        case 750..<850:
            return .heavy
        default:
            return .black
        }
    }

    private static func textAlignment(_ value: String?) -> NSTextAlignment {
        switch value?.lowercased() {
        case "center":
            return .center
        case "right", "end":
            return .right
        case "justify":
            return .justified
        default:
            return .left
        }
    }

    private static func keyboardType(_ value: String?) -> UIKeyboardType {
        switch value?.lowercased() {
        case "email", "email-address":
            return .emailAddress
        case "number", "number-pad", "numeric":
            return .numberPad
        case "decimal", "decimal-pad":
            return .decimalPad
        case "phone", "phone-pad", "tel":
            return .phonePad
        case "url":
            return .URL
        case "web-search":
            return .webSearch
        default:
            return .default
        }
    }
}

extension FlowTextInputOverlayBridge: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Never steal from Rive's own touch handling (pressables).
        true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard gestureRecognizer === dismissTapRecognizer,
              let touchedView = touch.view else {
            return true
        }
        // Taps on the native input controls focus them; only taps outside
        // dismiss the keyboard.
        for binding in bindingsByInputId.values {
            if touchedView === binding.control.view
                || touchedView.isDescendant(of: binding.control.view) {
                return false
            }
        }
        return true
    }
}

private extension UIColor {
    convenience init(nuxieARGB value: UInt32) {
        let alpha = CGFloat((value >> 24) & 0xff) / 255
        let red = CGFloat((value >> 16) & 0xff) / 255
        let green = CGFloat((value >> 8) & 0xff) / 255
        let blue = CGFloat(value & 0xff) / 255
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}
#endif
