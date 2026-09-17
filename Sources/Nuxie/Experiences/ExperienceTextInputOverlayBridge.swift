#if canImport(UIKit)
import Foundation
import NuxieRuntime
import UIKit

/// A native control stays in field-local units; UIKit applies the complete
/// runtime transform to its drawing, caret, accessibility and hit testing.
struct ExperienceTextInputPlacement: Equatable {
    let size: CGSize
    let transform: CGAffineTransform
    let firstBaseline: CGPoint?
    let textOrigin: CGPoint

    init?(geometry: NuxieNativeTextRunGeometry, viewport: ExperienceContainCenterTransform) {
        guard geometry.renderRevision != 0, let layout = geometry.layout,
              layout.bounds.width > 0, layout.bounds.height > 0,
              Self.isFinite(layout.transform), Self.isFinite(geometry.contentTransform),
              [layout.bounds.minX, layout.bounds.minY, layout.bounds.width, layout.bounds.height].allSatisfy(\.isFinite),
              Self.isInvertible(layout.transform) else { return nil }
        let localToArtboard = CGAffineTransform(translationX: layout.bounds.minX, y: layout.bounds.minY)
            .concatenating(layout.transform)
        let artboardToViewport = CGAffineTransform(a: viewport.scale, b: 0, c: 0, d: viewport.scale,
            tx: viewport.contentBounds.minX - viewport.artboardBounds.minX * viewport.scale,
            ty: viewport.contentBounds.minY - viewport.artboardBounds.minY * viewport.scale)
        let projected = localToArtboard.concatenating(artboardToViewport)
        guard Self.isFinite(projected), Self.isInvertible(projected) else { return nil }
        let contentToLocal = geometry.contentTransform.concatenating(localToArtboard.inverted())
        let origin = CGPoint.zero.applying(contentToLocal)
        let baseline = geometry.firstBaseline.map { CGPoint(x: 0, y: $0).applying(contentToLocal) }
        guard origin.x.isFinite, origin.y.isFinite,
              baseline.map({ $0.x.isFinite && $0.y.isFinite }) ?? true else { return nil }
        size = layout.bounds.size
        transform = projected
        firstBaseline = baseline
        textOrigin = origin
    }

    @MainActor
    func apply(to view: UIView) {
        // Setting frame while transformed loses shear/reflection and makes
        // UIKit's inverse touch projection disagree with the painted field.
        view.bounds = CGRect(origin: .zero, size: size)
        view.center = CGPoint(x: size.width / 2, y: size.height / 2).applying(transform)
        view.transform = CGAffineTransform(a: transform.a, b: transform.b, c: transform.c, d: transform.d, tx: 0, ty: 0)
    }

    private static func isFinite(_ t: CGAffineTransform) -> Bool {
        [t.a, t.b, t.c, t.d, t.tx, t.ty].allSatisfy(\.isFinite)
    }

    private static func isInvertible(_ t: CGAffineTransform) -> Bool {
        let determinant = t.a * t.d - t.b * t.c
        return determinant.isFinite && determinant != 0
    }
}

struct ExperienceTextInputMetrics: Equatable {
    let fontSize: Double
    let lineHeight: Double
}

/// Resolves effective typography from the snapshot captured with a native frame.
struct ExperienceTextInputMetricsResolver {
    let snapshot: ExperienceInteractiveViewModelSnapshot

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
        private var textOffset = CGPoint.zero
        private var presentationLineHeight: CGFloat?
        private var measuredLine: (metrics: ExperienceTextInputMetrics, height: CGFloat, baseline: CGFloat)?
        private var capturedBaseline: (metrics: ExperienceTextInputMetrics, offset: CGFloat)?

        func align(firstBaseline: CGFloat?, origin: CGPoint, metrics: ExperienceTextInputMetrics) {
            contentVerticalAlignment = .top
            if measuredLine?.metrics != metrics {
                // UIKit baseline anchors describe intrinsic-height controls,
                // not an editor stretched to the authored field's touch box.
                // Measure native typography without copying entered text.
                let probe = UITextField()
                probe.borderStyle = .none
                probe.contentVerticalAlignment = .top
                probe.defaultTextAttributes = defaultTextAttributes
                probe.isSecureTextEntry = isSecureTextEntry
                probe.text = " "
                probe.frame = CGRect(x: 0, y: 0, width: bounds.width, height: probe.intrinsicContentSize.height)
                let guide = UILayoutGuide()
                probe.addLayoutGuide(guide)
                NSLayoutConstraint.activate([
                    guide.topAnchor.constraint(equalTo: probe.firstBaselineAnchor),
                    guide.leadingAnchor.constraint(equalTo: probe.leadingAnchor),
                    guide.widthAnchor.constraint(equalToConstant: 0),
                    guide.heightAnchor.constraint(equalToConstant: 0),
                ])
                probe.setNeedsLayout()
                probe.layoutIfNeeded()
                measuredLine = (metrics, probe.bounds.height, guide.layoutFrame.minY)
            }
            guard let measuredLine else { return }
            if let firstBaseline { capturedBaseline = (metrics, firstBaseline - origin.y) }
            let target = firstBaseline ?? capturedBaseline.flatMap {
                $0.metrics == metrics ? origin.y + $0.offset : nil
            }
            presentationLineHeight = measuredLine.height
            textOffset = CGPoint(x: origin.x, y: target.map { $0 - measuredLine.baseline } ?? origin.y)
            setNeedsLayout()
            layoutIfNeeded()
        }

        private func contentRect(_ bounds: CGRect) -> CGRect {
            guard let presentationLineHeight else { return bounds }
            return CGRect(x: bounds.minX + textOffset.x, y: bounds.minY + textOffset.y,
                width: bounds.width - textOffset.x, height: presentationLineHeight)
        }

        override func textRect(forBounds bounds: CGRect) -> CGRect { contentRect(bounds) }
        override func editingRect(forBounds bounds: CGRect) -> CGRect { contentRect(bounds) }
        override func placeholderRect(forBounds bounds: CGRect) -> CGRect { contentRect(bounds) }
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
    private var runtimeGeometryByRun: [String: NuxieNativeTextRunGeometry] = [:]
    private var invalidGeometryIDs = Set<String>()
    private var lastAppliedPlacements: [String: ExperienceTextInputPlacement] = [:]
    private var baselineCorrections: [String: (metrics: ExperienceTextInputMetrics, offset: CGFloat)] = [:]
    private var metricsByInputID: [String: ExperienceTextInputMetrics] = [:]
    private var invalidMetricIDs = Set<String>()
    private var lastAppliedMetrics: [String: ExperienceTextInputMetrics] = [:]
    private var textValuesByInputID: [String: String] = [:]
    private var notifiedTextByInputID: [String: String] = [:]
    private var fontSHA256ByRiveUniqueName: [String: String] = [:]
    private var systemFontWeightsByRiveUniqueName: [String: String] = [:]
    private var failedInputIDs = Set<String>()
    private var semanticFields: [String: NuxieNativeSemanticNode]?
    private var activeBuildID: String?
    private var generation: UInt64 = 0
    private var hidden = false
    private weak var activeEditingControl: UIView?
    private var keyboardShift: CGFloat = 0
    private var latestKeyboardFrame: CGRect?
    private var dismissTapRecognizer: UITapGestureRecognizer?

    var onAcceptedTextChange: ((NativeExperienceTextInput, String) -> Void)?
    var onEditingEvent: ((NativeExperienceTextInput, ExperienceTextInputEvent) -> Void)?

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
            notifiedTextByInputID.removeAll()
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
        systemFontWeightsByRiveUniqueName = renderPlan.systemFonts.reduce(into: [:]) {
            $0[$1.riveUniqueName] = $1.weight
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
            notifiedTextByInputID[input.inputId] =
                notifiedTextByInputID[input.inputId] ?? control.text
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
        runtimeGeometryByRun.removeAll()
        metricsByInputID.removeAll()
        lastAppliedMetrics.removeAll()
        invalidMetricIDs = Set(bindingsByInputID.keys)
        layout()
    }

    func update(frame: ExperienceInteractiveTextFrame) {
        guard let snapshot = frame.snapshot else { invalidateLayout(); return }
        if case .captured(let captured) = frame.geometry {
            runtimeGeometryByRun = captured
        } else {
            runtimeGeometryByRun.removeAll()
        }
        let resolver = ExperienceTextInputMetricsResolver(snapshot: snapshot)
        metricsByInputID = bindingsByInputID.compactMapValues {
            resolver.metrics(xPath: $0.input.geometry.xPath,
                authored: .init(fontSize: $0.input.style.fontSize, lineHeight: $0.input.style.lineHeight))
        }
        invalidMetricIDs = Set(bindingsByInputID.keys).subtracting(metricsByInputID.keys)
        for inputID in invalidMetricIDs { lastAppliedMetrics.removeValue(forKey: inputID) }
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
            binding.control.view.accessibilityLabel = node.map { ExperienceAccessibilityStateDescription.fieldLabel(for: $0) }
            binding.control.view.accessibilityUserInputLabels = node.flatMap { $0.label.isEmpty ? nil : [$0.label] }
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
            ?? notifiedTextByInputID[binding.input.inputId] ?? binding.input.value
    }

    private func allowsInteraction(_ binding: Binding) -> Bool {
        guard !invalidMetricIDs.contains(binding.input.inputId),
              !invalidGeometryIDs.contains(binding.input.inputId) else { return false }
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
        runtimeGeometryByRun.removeAll()
        metricsByInputID.removeAll()
        invalidMetricIDs.removeAll()
        invalidGeometryIDs.removeAll()
        lastAppliedPlacements.removeAll()
        baselineCorrections.removeAll()
        lastAppliedMetrics.removeAll()
        failedInputIDs.removeAll()
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
            invalidGeometryIDs = Set(bindingsByInputID.keys)
            for (inputID, binding) in bindingsByInputID {
                layoutRuntimeField(binding, inputID: inputID, placement: nil)
            }
            return
        }
        let placements = bindingsByInputID.compactMapValues { binding in
            runtimeGeometryByRun[binding.input.riveTextRunName].flatMap {
                ExperienceTextInputPlacement(geometry: $0, viewport: transform)
            }
        }
        invalidGeometryIDs = Set(bindingsByInputID.keys).subtracting(placements.keys)
        for (inputID, binding) in bindingsByInputID {
            layoutRuntimeField(binding, inputID: inputID, placement: placements[inputID])
        }
    }

    private func layoutRuntimeField(_ binding: Binding, inputID: String,
        placement: ExperienceTextInputPlacement?) {
        switch binding.control {
        case .field(let field): field.isEnabled = allowsInteraction(binding)
        case .textView(let textView):
            textView.isEditable = allowsEditing(binding)
            textView.isSelectable = allowsInteraction(binding)
        }
        guard let placement, let metrics = metricsByInputID[inputID] else {
            // Fence delegate callbacks before resigning a composing editor.
            binding.control.view.isHidden = true
            binding.control.view.resignFirstResponder()
            lastAppliedPlacements.removeValue(forKey: inputID)
            return
        }
        binding.control.view.isHidden = hidden || failedInputIDs.contains(inputID) || isSemanticallyHidden(inputID)
        guard lastAppliedPlacements[inputID] != placement || lastAppliedMetrics[inputID] != metrics else { return }
        lastAppliedPlacements[inputID] = placement
        lastAppliedMetrics[inputID] = metrics
        applyStyle(binding.input.style, metrics: metrics, to: binding.control,
            secure: binding.input.secureTextEntry == true)
        UIView.performWithoutAnimation {
            placement.apply(to: binding.control.view)
            alignBaseline(binding, placement: placement, metrics: metrics)
        }
    }

    private func alignBaseline(_ binding: Binding, placement: ExperienceTextInputPlacement,
        metrics: ExperienceTextInputMetrics) {
        if case .field(let field) = binding.control {
            field.align(firstBaseline: placement.firstBaseline?.y, origin: placement.textOrigin, metrics: metrics)
            return
        }
        guard case .textView(let editor) = binding.control else { return }
        let manager = editor.layoutManager
        manager.ensureLayout(for: editor.textContainer)
        guard manager.numberOfGlyphs > 0 else { return }
        let firstGlyph = manager.glyphIndexForCharacter(at: 0)
        let fragment = manager.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
        let nativeBaseline = fragment.minY + manager.location(forGlyphAt: firstGlyph).y
        let correction: CGFloat
        if let baseline = placement.firstBaseline {
            correction = baseline.y - placement.textOrigin.y - nativeBaseline
            baselineCorrections[binding.input.inputId] = (metrics, correction)
        } else if let previous = baselineCorrections[binding.input.inputId], previous.metrics == metrics {
            // A blank runtime run can coexist with retained native text, such
            // as secure entry. Preserve the offset without retaining text.
            correction = previous.offset
        } else {
            correction = 0
        }
        let top = placement.textOrigin.y + correction
        let insets = UIEdgeInsets(top: top, left: placement.textOrigin.x, bottom: 0, right: 0)
        if editor.textContainerInset != insets { editor.textContainerInset = insets }
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
        secure: Bool
    ) {
        let fontSize = CGFloat(metrics.fontSize)
        let font = Self.font(
            for: style,
            contentSHA256: fontSHA256ByRiveUniqueName[style.fontAssetRiveUniqueName],
            systemWeight: systemFontWeightsByRiveUniqueName[style.fontAssetRiveUniqueName],
            size: fontSize
        )
        let color = UIColor(nuxieARGB: style.color)
        let textColor: UIColor = secure ? color : .clear
        let alignment = Self.textAlignment(style.textAlign)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        // A -1 line height is font-natural. UIKit represents that with zero
        // paragraph constraints; the view transform scales the baseline interval.
        if metrics.lineHeight > 0 {
            let height = CGFloat(metrics.lineHeight)
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
            attributes[.kern] = CGFloat(style.letterSpacing)
            attributes[.paragraphStyle] = paragraph
            field.defaultTextAttributes = attributes
        case .textView(let textView):
            textView.font = font
            textView.textAlignment = alignment
            textView.textColor = textColor
            textView.tintColor = color
            textView.typingAttributes[.kern] = CGFloat(style.letterSpacing)
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
        flushTextChange(for: sender)
    }

    func textViewDidChange(_ textView: UITextView) {
        flushTextChange(for: textView)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard let binding = binding(for: textField), allowsEditing(binding),
              !binding.control.hasMarkedText else { return false }
        emitEditingEvent(.returnPressed, for: textField)
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
        emitEditingEvent(.editingEnded, for: control)
    }

    private func emitEditingEvent(_ kind: ExperienceTextInputEventKind, for control: UIView) {
        guard let binding = binding(for: control), allowsEditing(binding),
              !binding.control.hasMarkedText else { return }
        flushTextChange(for: control)
        if semanticTextWriter != nil {
            let events = semanticDrafts[binding.input.inputId]?.requestEvent(kind) ?? []
            for event in events { onEditingEvent?(binding.input, event) }
        } else {
            onEditingEvent?(binding.input, .init(kind: kind, text: binding.control.text))
        }
    }

    func flushTextChange(for control: UIView) {
        guard let binding = binding(for: control) else { return }
        guard allowsEditing(binding) else { restoreAcceptedText(binding); return }
        propagateTextChange(from: control)
        guard !binding.control.hasMarkedText else { return }
        if semanticTextWriter != nil {
            if let text = semanticDrafts[binding.input.inputId]?.requestValueChange() {
                notifyAcceptedTextChange(text, input: binding.input)
            }
            return
        }
        let text = binding.control.text
        guard notifiedTextByInputID[binding.input.inputId] != text else { return }
        notifiedTextByInputID[binding.input.inputId] = text
        onAcceptedTextChange?(binding.input, text)
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

    private func notifyAcceptedTextChange(_ text: String, input: NativeExperienceTextInput) {
        notifiedTextByInputID[input.inputId] = text
        onAcceptedTextChange?(input, text)
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
            if let commit { self.notifyAcceptedTextChange(commit, input: binding.input) }
            let events = self.semanticDrafts[inputID]?.takeReadyEvents() ?? []
            for event in events { self.onEditingEvent?(binding.input, event) }
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
        systemWeight: String?,
        size: CGFloat
    ) -> UIFont {
        if let systemWeight, let weight = Int(systemWeight) {
            return .systemFont(ofSize: size, weight: ExperienceRuntimeSystemFontProvider.uiWeight(weight))
        }
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
