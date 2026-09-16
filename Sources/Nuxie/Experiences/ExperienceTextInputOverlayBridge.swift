#if canImport(UIKit)
import Foundation
import NuxieRuntime
import UIKit

struct ExperienceTextInputGeometry {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let rotation: Double
    let scaleX: Double
    let scaleY: Double
}

struct ExperienceTextInputMetrics: Equatable {
    let fontSize: Double
    let lineHeight: Double
}

/// Resolves signed geometry paths from a generic native snapshot. This is
/// product policy over plain values.
struct ExperienceTextInputGeometryResolver {
    let snapshot: ExperienceInteractiveViewModelSnapshot

    func geometry(for geometry: NativeExperienceTextInput.Geometry) -> ExperienceTextInputGeometry? {
        guard let x = number(at: geometry.xPath),
              let y = number(at: geometry.yPath),
              let width = number(at: geometry.widthPath),
              let height = number(at: geometry.heightPath),
              let rotation = number(at: geometry.rotationPath),
              let scaleX = number(at: geometry.scaleXPath),
              let scaleY = number(at: geometry.scaleYPath),
              width > 0,
              height > 0 else { return nil }
        return ExperienceTextInputGeometry(
            x: x,
            y: y,
            width: width,
            height: height,
            rotation: rotation,
            scaleX: scaleX,
            scaleY: scaleY
        )
    }

    func metrics(xPath: String, authored: ExperienceTextInputMetrics) -> ExperienceTextInputMetrics? {
        let components = xPath.split(separator: "/").map(String.init).dropLast()
        guard (2...3).contains(components.count), components[components.count - 2] == "nuxieTextInputs" else {
            return authored
        }
        let prefix = components.joined(separator: "/")
        let size = value(at: "\(prefix)/fontSize")
        let height = value(at: "\(prefix)/lineHeight")
        if size == nil && height == nil { return authored }
        guard case .number(let fontSize) = size, fontSize.isFinite, fontSize > 0,
              case .number(let lineHeight) = height, lineHeight.isFinite,
              lineHeight == -1 || lineHeight > 0 else { return nil }
        return .init(fontSize: Double(fontSize), lineHeight: Double(lineHeight))
    }

    func number(at path: String) -> Double? {
        guard case .number(let number) = value(at: path), number.isFinite else { return nil }
        return Double(number)
    }

    private func value(at path: String) -> ExperienceInteractiveViewModelValue? {
        let segments = path.split(separator: "/").map(String.init)
        guard !segments.isEmpty else { return nil }
        return value(segments: segments, allowingLeadingLabel: true)
    }

    private func value(segments: [String], allowingLeadingLabel: Bool) -> ExperienceInteractiveViewModelValue? {
        var owner = snapshot.rootInstanceID
        for (offset, segment) in segments.enumerated() {
            let matches = snapshot.values.filter { $0.ownerInstanceID == owner && $0.name == segment }
            if matches.count != 1 {
                if offset == 0, allowingLeadingLabel, segments.count > 1 {
                    return value(segments: Array(segments.dropFirst()), allowingLeadingLabel: false)
                }
                return nil
            }
            let value = matches[0].value
            if offset == segments.count - 1 { return value }
            guard case .referencedInstance(let child) = value else { return nil }
            owner = child
        }
        return nil
    }

}

@MainActor
final class ExperienceTextInputOverlayBridge: NSObject,
    UITextFieldDelegate,
    UITextViewDelegate
{
    typealias TextWriter = (
        _ inputID: String,
        _ text: String,
        _ completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) -> Void

    typealias SemanticTextWriter = (
        _ captureID: UUID, _ inputID: String, _ text: String,
        _ completion: @escaping @MainActor @Sendable (ExperienceSemanticTextDraft.Outcome) -> Void
    ) -> Void

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
            case .field(let value): value
            case .textView(let value): value
            }
        }

        var hasMarkedText: Bool {
            switch self {
            case .field(let field): field.markedTextRange != nil
            case .textView(let textView): textView.markedTextRange != nil
            }
        }

        var text: String {
            get {
                switch self {
                case .field(let value): value.text ?? ""
                case .textView(let value): value.text ?? ""
                }
            }
            nonmutating set {
                switch self {
                case .field(let value): value.text = newValue
                case .textView(let value): value.text = newValue
                }
            }
        }
    }

    private struct Binding {
        let input: NativeExperienceTextInput
        let control: Control
    }

    private weak var surfaceView: UIView?
    private var artboardBounds: CGRect = .zero
    private var textWriter: TextWriter?
    private var semanticTextWriter: SemanticTextWriter?
    private var semanticDrafts: [String: ExperienceSemanticTextDraft] = [:]
    private var bindingsByInputID: [String: Binding] = [:]
    private var geometriesByInputID: [String: ExperienceTextInputGeometry] = [:]
    private var metricsByInputID: [String: ExperienceTextInputMetrics] = [:]
    private var invalidMetricIDs = Set<String>()
    private var lastAppliedMetrics: [String: ExperienceTextInputMetrics] = [:]
    private var textValuesByInputID: [String: String] = [:]
    private var committedTextByInputID: [String: String] = [:]
    private var fontSHA256ByRiveUniqueName: [String: String] = [:]
    private var failedInputIDs = Set<String>()
    private var semanticFields: [String: NuxieNativeSemanticNode]?
    private var activeBuildID: String?
    private var generation: UInt64 = 0
    private var hidden = false
    private weak var activeEditingControl: UIView?
    private var keyboardShift: CGFloat = 0
    private var latestKeyboardFrame: CGRect?
    private var dismissTapRecognizer: UITapGestureRecognizer?
    private var lastAppliedFrames: [String: CGRect] = [:]
    private var lastAppliedRotations: [String: CGFloat] = [:]

    var onCommitText: ((NativeExperienceTextInput, String) -> Void)?

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
        screenID: String,
        renderPlan: NativeExperienceRenderPlan,
        surfaceView: UIView,
        artboardBounds: CGRect,
        semanticTextWriter: SemanticTextWriter? = nil,
        textWriter: @escaping TextWriter
    ) {
        if activeBuildID != renderPlan.identity.buildId {
            textValuesByInputID.removeAll()
            committedTextByInputID.removeAll()
            activeBuildID = renderPlan.identity.buildId
        }
        clear()
        self.surfaceView = surfaceView
        self.artboardBounds = artboardBounds
        self.textWriter = textWriter
        self.semanticTextWriter = semanticTextWriter
        if semanticTextWriter != nil { semanticFields = [:] }
        fontSHA256ByRiveUniqueName = renderPlan.fonts.reduce(into: [:]) {
            $0[$1.riveUniqueName] = $1.sha256
        }

        let declared = renderPlan.textInputs.filter {
            $0.screenId == screenID && $0.editable
        }
        let counts = Dictionary(grouping: declared, by: \.inputId).mapValues(\.count)
        for input in declared where counts[input.inputId] == 1 {
            let control = makeControl(for: input)
            control.view.accessibilityIdentifier = "nuxie-text-input-\(input.inputId)"
            control.view.isAccessibilityElement = true
            control.text = textValuesByInputID[input.inputId] ?? input.value
            committedTextByInputID[input.inputId] =
                committedTextByInputID[input.inputId] ?? control.text
            surfaceView.addSubview(control.view)
            bindingsByInputID[input.inputId] = Binding(input: input, control: control)
            if semanticTextWriter != nil {
                semanticDrafts[input.inputId] = ExperienceSemanticTextDraft(text: control.text, needsInitialWrite: true)
            } else {
                write(control.text, for: input)
            }
        }
        installDismissTapRecognizer(on: surfaceView)
        layout()
    }

    func invalidateLayout() {
        geometriesByInputID.removeAll()
        metricsByInputID.removeAll()
        lastAppliedMetrics.removeAll()
        invalidMetricIDs = Set(bindingsByInputID.keys)
        layout()
    }

    func update(snapshot: ExperienceInteractiveViewModelSnapshot) {
        let resolver = ExperienceTextInputGeometryResolver(snapshot: snapshot)
        metricsByInputID = bindingsByInputID.compactMapValues {
            resolver.metrics(xPath: $0.input.geometry.xPath,
                authored: .init(fontSize: $0.input.style.fontSize, lineHeight: $0.input.style.lineHeight))
        }
        invalidMetricIDs = Set(bindingsByInputID.keys).subtracting(metricsByInputID.keys)
        for inputID in invalidMetricIDs { lastAppliedMetrics.removeValue(forKey: inputID) }
        geometriesByInputID = bindingsByInputID.compactMapValues {
            resolver.geometry(for: $0.input.geometry)
        }
        layout()
    }

    /// Exact runtime text-run association keeps each real editor in the scene tree once.
    func applySemantics(_ capture: NuxieNativeSemanticCapture) -> [UInt32: UIView] {
        let fields = bindingsByInputID.compactMapValues { binding in
            capture.fieldsByTextRun[binding.input.riveTextRunName]
        }
        let counts = Dictionary(grouping: Array(fields.values), by: \.id).mapValues(\.count)
        let unique = fields.filter { counts[$0.value.id] == 1 }
        if semanticTextWriter == nil, semanticFields != unique { generation &+= 1 }
        semanticFields = unique
        var controls: [UInt32: UIView] = [:]
        for (inputID, binding) in bindingsByInputID {
            let node = unique[inputID]
            let editable = allowsEditing(binding)
            if editable {
                semanticDrafts[inputID]?.present(captureID: capture.id)
            } else {
                semanticDrafts[inputID]?.withdraw()
            }
            switch binding.control {
            case .field(let field): field.isEnabled = allowsInteraction(binding)
            case .textView(let textView):
                textView.isEditable = editable
                textView.isSelectable = allowsInteraction(binding)
            }
            binding.control.view.accessibilityLabel = node?.label
            binding.control.view.accessibilityHint = node?.hint
            if !editable {
                restoreAcceptedText(binding)
                if !allowsInteraction(binding) { binding.control.view.resignFirstResponder() }
            }
            if let node, node.stateFlags & NuxieNativeSemanticNode.hidden == 0 {
                controls[node.id] = binding.control.view
            }
        }
        for inputID in bindingsByInputID.keys { drainSemanticWrite(inputID) }
        layout()
        return controls
    }

    private func restoreAcceptedText(_ binding: Binding) {
        binding.control.text = semanticDrafts[binding.input.inputId]?.acceptedText
            ?? textValuesByInputID[binding.input.inputId]
            ?? committedTextByInputID[binding.input.inputId] ?? binding.input.value
    }

    private func allowsInteraction(_ binding: Binding) -> Bool {
        guard !invalidMetricIDs.contains(binding.input.inputId) else { return false }
        guard let semanticFields else { return true }
        guard !hidden, let surfaceView,
              ExperienceSemanticAccessibilityElement.allowsInteraction(in: surfaceView),
              let node = semanticFields[binding.input.inputId] else { return false }
        return node.stateFlags & (NuxieNativeSemanticNode.disabled | NuxieNativeSemanticNode.hidden) == 0
    }

    private func allowsEditing(_ binding: Binding) -> Bool {
        guard allowsInteraction(binding) else { return false }
        guard let semanticFields else { return true }
        guard let node = semanticFields[binding.input.inputId] else { return false }
        return node.stateFlags & NuxieNativeSemanticNode.readOnly == 0
    }

    private func isSemanticallyHidden(_ inputID: String) -> Bool {
        guard let semanticFields else { return false }
        guard let node = semanticFields[inputID] else { return true }
        return node.stateFlags & NuxieNativeSemanticNode.hidden != 0
    }

    func clear() {
        generation &+= 1
        bindingsByInputID.values.forEach { $0.control.view.removeFromSuperview() }
        bindingsByInputID.removeAll()
        semanticFields = nil
        semanticDrafts.removeAll()
        semanticTextWriter = nil
        geometriesByInputID.removeAll()
        metricsByInputID.removeAll()
        invalidMetricIDs.removeAll()
        lastAppliedMetrics.removeAll()
        failedInputIDs.removeAll()
        lastAppliedFrames.removeAll()
        lastAppliedRotations.removeAll()
        if let dismissTapRecognizer {
            dismissTapRecognizer.view?.removeGestureRecognizer(dismissTapRecognizer)
        }
        dismissTapRecognizer = nil
        activeEditingControl = nil
        applyKeyboardShift(0, animationDuration: 0)
        textWriter = nil
        surfaceView = nil
    }

    func setHidden(_ value: Bool) {
        hidden = value
        if value, semanticTextWriter != nil {
            for (inputID, binding) in bindingsByInputID {
                semanticDrafts[inputID]?.withdraw()
                restoreAcceptedText(binding)
            }
        }
        layout()
    }

    func layout() {
        guard let surfaceView,
              let transform = ExperienceContainCenterTransform(
                  artboardBounds: artboardBounds,
                  viewportBounds: surfaceView.bounds
              ) else {
            bindingsByInputID.values.forEach { $0.control.view.isHidden = true }
            return
        }
        for (inputID, binding) in bindingsByInputID {
            switch binding.control {
            case .field(let field): field.isEnabled = allowsInteraction(binding)
            case .textView(let textView):
                textView.isEditable = allowsEditing(binding)
                textView.isSelectable = allowsInteraction(binding)
            }
            guard let geometry = geometriesByInputID[inputID], let metrics = metricsByInputID[inputID] else {
                if invalidMetricIDs.contains(inputID) { binding.control.view.resignFirstResponder() }
                binding.control.view.isHidden = true
                continue
            }
            binding.control.view.isHidden = hidden || failedInputIDs.contains(inputID) || isSemanticallyHidden(inputID)
            var frame = transform.viewportRect(fromArtboard: CGRect(
                x: CGFloat(geometry.x),
                y: CGFloat(geometry.y),
                width: CGFloat(geometry.width),
                height: CGFloat(geometry.height)
            ))
            frame.size.width *= max(0, CGFloat(geometry.scaleX))
            frame.size.height *= max(0, CGFloat(geometry.scaleY))
            let rotation = CGFloat(geometry.rotation)
            guard lastAppliedFrames[inputID] != frame
                    || lastAppliedRotations[inputID] != rotation
                    || lastAppliedMetrics[inputID] != metrics else { continue }
            lastAppliedFrames[inputID] = frame
            lastAppliedRotations[inputID] = rotation
            lastAppliedMetrics[inputID] = metrics
            applyStyle(
                binding.input.style,
                metrics: metrics,
                to: binding.control,
                fontScale: transform.scale * max(0, CGFloat(geometry.scaleY)),
                horizontalScale: transform.scale * max(0, CGFloat(geometry.scaleX)),
                secure: binding.input.secureTextEntry == true
            )
            UIView.performWithoutAnimation {
                binding.control.view.transform = .identity
                binding.control.view.bounds = CGRect(origin: .zero, size: frame.size)
                binding.control.view.center = CGPoint(x: frame.midX, y: frame.midY)
                if rotation != 0 {
                    binding.control.view.transform = CGAffineTransform(rotationAngle: rotation)
                }
            }
        }
    }

    private func makeControl(for input: NativeExperienceTextInput) -> Control {
        if input.multiline == true && input.secureTextEntry != true {
            let value = UITextView(frame: .zero)
            value.delegate = self
            value.backgroundColor = .clear
            value.textContainerInset = .zero
            value.textContainer.lineFragmentPadding = 0
            value.keyboardType = Self.keyboardType(input.keyboardType)
            return .textView(value)
        }
        let value = TextField(frame: .zero)
        value.delegate = self
        value.borderStyle = .none
        value.backgroundColor = .clear
        value.placeholder = input.placeholder
        value.keyboardType = Self.keyboardType(input.keyboardType)
        value.isSecureTextEntry = input.secureTextEntry == true
        value.returnKeyType = .done
        value.addTarget(
            self,
            action: #selector(textFieldEditingChanged(_:)),
            for: .editingChanged
        )
        return .field(value)
    }

    private func applyStyle(
        _ style: NativeExperienceTextInput.Style,
        metrics: ExperienceTextInputMetrics,
        to control: Control,
        fontScale: CGFloat,
        horizontalScale: CGFloat,
        secure: Bool
    ) {
        let fontSize = max(1, CGFloat(metrics.fontSize) * fontScale)
        let font = Self.font(
            for: style,
            contentSHA256: fontSHA256ByRiveUniqueName[style.fontAssetRiveUniqueName],
            size: fontSize
        )
        let color = UIColor(nuxieARGB: style.color)
        let textColor: UIColor = secure ? color : .clear
        let alignment = Self.textAlignment(style.textAlign)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        // A -1 line height is font-natural. UIKit represents that with zero
        // paragraph constraints; explicit height is a scaled baseline interval.
        if metrics.lineHeight > 0 {
            let height = CGFloat(metrics.lineHeight) * fontScale
            paragraph.minimumLineHeight = height
            paragraph.maximumLineHeight = height
        }
        switch control {
        case .field(let field):
            field.font = font
            field.textAlignment = alignment
            field.textColor = textColor
            field.tintColor = color
            var attributes = field.defaultTextAttributes
            attributes[.font] = font
            attributes[.foregroundColor] = textColor
            attributes[.kern] = CGFloat(style.letterSpacing) * horizontalScale
            attributes[.paragraphStyle] = paragraph
            field.defaultTextAttributes = attributes
        case .textView(let textView):
            textView.font = font
            textView.textAlignment = alignment
            textView.textColor = textColor
            textView.tintColor = color
            textView.typingAttributes[.kern] = CGFloat(style.letterSpacing) * horizontalScale
            textView.typingAttributes[.paragraphStyle] = paragraph
            let range = NSRange(location: 0, length: textView.textStorage.length)
            var needsParagraph = false
            textView.textStorage.enumerateAttribute(.paragraphStyle, in: range) { value, _, _ in
                if (value as? NSParagraphStyle) != paragraph { needsParagraph = true }
            }
            if needsParagraph {
                // Edit attributes in place, retaining text, selection and any
                // marked range rather than replacing the attributed string.
                textView.textStorage.addAttribute(.paragraphStyle, value: paragraph, range: range)
            }
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
        beginEditing(control: textField)
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        beginEditing(control: textView)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        endEditing(control: textField)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        endEditing(control: textView)
    }

    private func beginEditing(control: UIView) {
        activeEditingControl = control
        avoidKeyboardIfNeeded(animationDuration: 0.25)
    }

    private func endEditing(control: UIView) {
        if activeEditingControl === control { activeEditingControl = nil }
        commitTextIfChanged(for: control)
    }

    func commitTextIfChanged(for control: UIView) {
        guard let binding = binding(for: control) else { return }
        guard allowsEditing(binding) else { restoreAcceptedText(binding); return }
        propagateTextChange(from: control)
        guard !binding.control.hasMarkedText else { return }
        if semanticTextWriter != nil {
            if let text = semanticDrafts[binding.input.inputId]?.requestCommit() {
                commitSemanticText(text, input: binding.input)
            }
            return
        }
        let text = binding.control.text
        guard committedTextByInputID[binding.input.inputId] != text else { return }
        committedTextByInputID[binding.input.inputId] = text
        onCommitText?(binding.input, text)
    }

    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        shouldAllowChange(textField.text ?? "", range, string, textField)
    }

    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        shouldAllowChange(textView.text ?? "", range, text, textView)
    }

    private func shouldAllowChange(
        _ current: String,
        _ range: NSRange,
        _ replacement: String,
        _ control: UIView
    ) -> Bool {
        guard let binding = binding(for: control), allowsEditing(binding) else { return false }
        guard let maximum = binding.input.maxLength,
              maximum > 0,
              let textRange = Range(range, in: current) else { return true }
        let candidate = current.replacingCharacters(
            in: textRange,
            with: replacement
        )
        return ExperienceTextInputLimit.fits(candidate, maximum: maximum)
    }

    private func propagateTextChange(from control: UIView) {
        guard let binding = binding(for: control) else { return }
        guard allowsEditing(binding) else {
            restoreAcceptedText(binding)
            return
        }
        let text = binding.control.text
        if semanticTextWriter != nil {
            semanticDrafts[binding.input.inputId]?.replaceText(text, isComposing: binding.control.hasMarkedText)
            drainSemanticWrite(binding.input.inputId)
            return
        }
        textValuesByInputID[binding.input.inputId] = text
        write(text, for: binding.input)
    }

    private func commitSemanticText(_ text: String, input: NativeExperienceTextInput) {
        committedTextByInputID[input.inputId] = text
        onCommitText?(input, text)
    }

    private func drainSemanticWrite(_ inputID: String) {
        guard !hidden, let writer = semanticTextWriter,
              let binding = bindingsByInputID[inputID], allowsEditing(binding),
              let write = semanticDrafts[inputID]?.takeWrite() else { return }
        let currentGeneration = generation
        let rendered = binding.input.secureTextEntry == true ? "" : write.text
        writer(write.captureID, inputID, rendered) { [weak self] outcome in
            guard let self, self.generation == currentGeneration else { return }
            guard self.allowsEditing(binding) else {
                self.semanticDrafts[inputID]?.withdraw()
                self.restoreAcceptedText(binding)
                return
            }
            // UIKit may change marked text before delivering its change notification.
            // Completion must compare against the editor's current provisional draft.
            self.semanticDrafts[inputID]?.replaceText(binding.control.text,
                isComposing: binding.control.hasMarkedText)
            let commit = self.semanticDrafts[inputID]?.finish(write, outcome: outcome)
            self.textValuesByInputID[inputID] = self.semanticDrafts[inputID]?.acceptedText
            if let commit { self.commitSemanticText(commit, input: binding.input) }
            if case .rejected = outcome { self.restoreAcceptedText(binding) }
            self.drainSemanticWrite(inputID)
        }
    }

    private func write(_ text: String, for input: NativeExperienceTextInput) {
        guard let textWriter else { return }
        let rendered = input.secureTextEntry == true ? "" : text
        let currentGeneration = generation
        textWriter(input.inputId, rendered) { [weak self] result in
            guard let self, self.generation == currentGeneration else { return }
            switch result {
            case .success:
                self.failedInputIDs.remove(input.inputId)
            case .failure(let error):
                self.failedInputIDs.insert(input.inputId)
                LogWarning(
                    "ExperienceTextInputOverlayBridge: failed to update '\(input.inputId)': \(error)"
                )
            }
            self.layout()
        }
    }

    private func binding(for control: UIView) -> Binding? {
        bindingsByInputID.values.first { $0.control.view === control }
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
            as? CGRect else { return }
        latestKeyboardFrame = frame
        avoidKeyboardIfNeeded(animationDuration: animationDuration(notification))
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        latestKeyboardFrame = nil
        applyKeyboardShift(0, animationDuration: animationDuration(notification))
    }

    private func animationDuration(_ notification: Notification) -> TimeInterval {
        notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
            as? TimeInterval ?? 0.25
    }

    private func avoidKeyboardIfNeeded(animationDuration: TimeInterval) {
        guard let control = activeEditingControl,
              let keyboardFrame = latestKeyboardFrame,
              let window = control.window else { return }
        let controlFrame = control.convert(control.bounds, to: nil)
        let keyboardMinY = window.convert(keyboardFrame, from: nil).minY
        applyKeyboardShift(
            Self.keyboardShift(
                controlFrameInWindow: controlFrame,
                currentShift: keyboardShift,
                keyboardMinY: keyboardMinY,
                padding: 12
            ),
            animationDuration: animationDuration
        )
    }

    static func keyboardShift(
        controlFrameInWindow: CGRect,
        currentShift: CGFloat,
        keyboardMinY: CGFloat,
        padding: CGFloat
    ) -> CGFloat {
        max(0, controlFrameInWindow.maxY + currentShift + padding - keyboardMinY)
    }

    private func applyKeyboardShift(_ value: CGFloat, animationDuration: TimeInterval) {
        guard keyboardShift != value else { return }
        keyboardShift = value
        guard let surfaceView else { return }
        let transform = value == 0
            ? CGAffineTransform.identity
            : CGAffineTransform(translationX: 0, y: -value)
        if animationDuration <= 0 {
            surfaceView.transform = transform
        } else {
            UIView.animate(
                withDuration: animationDuration,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseOut]
            ) { surfaceView.transform = transform }
        }
    }

    private func installDismissTapRecognizer(on view: UIView) {
        let recognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleDismissTap(_:))
        )
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        view.addGestureRecognizer(recognizer)
        dismissTapRecognizer = recognizer
    }

    @objc private func handleDismissTap(_ recognizer: UITapGestureRecognizer) {
        surfaceView?.endEditing(true)
    }

    private static func font(
        for style: NativeExperienceTextInput.Style,
        contentSHA256: String?,
        size: CGFloat
    ) -> UIFont {
        if let contentSHA256,
           let font = ExperienceRuntimeFontRegistry.font(
               forRiveUniqueName: style.fontAssetRiveUniqueName,
               contentSHA256: contentSHA256,
               size: size
           ) { return font }
        return .systemFont(ofSize: size, weight: fontWeight(style.fontWeight))
    }

    private static func fontWeight(_ value: String) -> UIFont.Weight {
        switch Int(value) ?? 400 {
        case ..<250: .ultraLight
        case 250..<350: .light
        case 350..<450: .regular
        case 450..<550: .medium
        case 550..<650: .semibold
        case 650..<750: .bold
        case 750..<850: .heavy
        default: .black
        }
    }

    private static func textAlignment(_ value: String?) -> NSTextAlignment {
        switch value?.lowercased() {
        case "center": .center
        case "right", "end": .right
        case "justified": .justified
        default: .left
        }
    }

    private static func keyboardType(_ value: String?) -> UIKeyboardType {
        switch value?.lowercased() {
        case "email", "email-address": .emailAddress
        case "number", "number-pad", "numeric": .numberPad
        case "decimal", "decimal-pad": .decimalPad
        case "phone", "phone-pad", "tel": .phonePad
        case "url": .URL
        case "web-search": .webSearch
        default: .default
        }
    }
}

extension ExperienceTextInputOverlayBridge: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { true }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard gestureRecognizer === dismissTapRecognizer,
              let touched = touch.view else { return true }
        return !bindingsByInputID.values.contains {
            touched === $0.control.view || touched.isDescendant(of: $0.control.view)
        }
    }
}

private extension UIColor {
    convenience init(nuxieARGB value: UInt32) {
        self.init(
            red: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: CGFloat((value >> 24) & 0xff) / 255
        )
    }
}
#endif
