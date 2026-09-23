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
        self.init(renderRevision: geometry.renderRevision, layout: geometry.layout,
            contentTransform: geometry.contentTransform, firstBaseline: geometry.firstBaseline, viewport: viewport)
    }

    init?(nativeInput geometry: NuxieNativeTextInputGeometry, viewport: ExperienceContainCenterTransform) {
        self.init(renderRevision: geometry.renderRevision, layout: geometry.layout,
            contentTransform: geometry.worldTransform, firstBaseline: geometry.firstBaseline, viewport: viewport)
    }

    private init?(renderRevision: UInt64, layout: NuxieNativeTextLayout?,
                  contentTransform: CGAffineTransform, firstBaseline: CGFloat?,
                  viewport: ExperienceContainCenterTransform) {
        guard renderRevision != 0, let layout,
              layout.bounds.width > 0, layout.bounds.height > 0,
              Self.isFinite(layout.transform), Self.isFinite(contentTransform),
              [layout.bounds.minX, layout.bounds.minY, layout.bounds.width, layout.bounds.height].allSatisfy(\.isFinite),
              Self.isInvertible(layout.transform) else { return nil }
        let localToArtboard = CGAffineTransform(translationX: layout.bounds.minX, y: layout.bounds.minY)
            .concatenating(layout.transform)
        let artboardToViewport = CGAffineTransform(a: viewport.scale, b: 0, c: 0, d: viewport.scale,
            tx: viewport.contentBounds.minX - viewport.artboardBounds.minX * viewport.scale,
            ty: viewport.contentBounds.minY - viewport.artboardBounds.minY * viewport.scale)
        let projected = localToArtboard.concatenating(artboardToViewport)
        guard Self.isFinite(projected), Self.isInvertible(projected) else { return nil }
        let contentToLocal = contentTransform.concatenating(localToArtboard.inverted())
        let origin = CGPoint.zero.applying(contentToLocal)
        let baseline = firstBaseline.map { CGPoint(x: 0, y: $0).applying(contentToLocal) }
        guard origin.x.isFinite, origin.y.isFinite,
              baseline.map({ $0.x.isFinite && $0.y.isFinite }) ?? true else { return nil }
        size = layout.bounds.size
        transform = projected
        self.firstBaseline = baseline
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

    struct InputTarget: Hashable, Sendable {
        let inputID: String
        var nodeID: UInt32? = nil
    }

    typealias SemanticTextWriter = (
        _ captureID: UUID, _ target: InputTarget, _ text: String,
        _ completion: @escaping @MainActor @Sendable (ExperienceSemanticTextDraft.Outcome) -> Void
    ) -> Void

    typealias SemanticTextReader = (
        _ captureID: UUID, _ target: InputTarget,
        _ completion: @escaping @MainActor @Sendable (Result<ExperienceTextInputSource, Error>) -> Void
    ) -> Void

    typealias SemanticContentOffsetWriter = (
        _ captureID: UUID, _ target: InputTarget, _ offset: CGPoint,
        _ completion: @escaping @MainActor @Sendable (ExperienceSemanticTextDraft.Outcome) -> Void
    ) -> Void

    private final class TextField: UITextField {
        var onViewportChange: (() -> Void)?

        var nativeContentOffset: CGPoint {
            let origin = textInputView.convert(CGPoint.zero, to: self)
            return CGPoint(x: editingRect(forBounds: bounds).minX - origin.x, y: 0)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            onViewportChange?()
        }

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

    /// A hint is presentation, never textStorage or a value sent to the runtime.
    private final class TextView: UITextView {
        let placeholderLabel = UILabel()

        override init(frame: CGRect, textContainer: NSTextContainer?) {
            super.init(frame: frame, textContainer: textContainer)
            placeholderLabel.numberOfLines = 0
            placeholderLabel.isUserInteractionEnabled = false
            placeholderLabel.isAccessibilityElement = false
            addSubview(placeholderLabel)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var text: String! {
            didSet { updatePlaceholder() }
        }

        func updatePlaceholder() {
            placeholderLabel.isHidden = !(text ?? "").isEmpty || markedTextRange != nil
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let inset = textContainerInset
            let x = inset.left + textContainer.lineFragmentPadding
            let width = max(0, bounds.width - x - inset.right - textContainer.lineFragmentPadding)
            let height = placeholderLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            placeholderLabel.frame = CGRect(x: x, y: inset.top, width: width, height: height)
        }
    }

    @MainActor
    private enum Control {
        case field(TextField)
        case textView(TextView)

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

    private final class Binding {
        let target: InputTarget
        let input: NativeExperienceTextInput
        let control: Control
        var nativeGeometry: NuxieNativeTextInputGeometry?
        var readCaptureID: UUID?
        var readRenderRevision: UInt64?
        var sourceReadID: UUID?
        var sourceWriteGeneration = UUID()
        var ownerInstanceID: UInt64?
        var sourceReady = false
        var textWriteInFlight = false
        var offsetWriteInFlight = false
        var lastOffset: CGPoint? = .zero
        var offsetAttemptCaptureID: UUID?

        init(target: InputTarget, input: NativeExperienceTextInput, control: Control) {
            self.target = target
            self.input = input
            self.control = control
        }
    }

    private weak var surfaceView: UIView?
    private var artboardBounds: CGRect = .zero
    private var textWriter: TextWriter?
    private var semanticTextWriter: SemanticTextWriter?
    private var semanticContentOffsetWriter: SemanticContentOffsetWriter?
    private var semanticTextReader: SemanticTextReader?
    private var nativeInputs: [NativeExperienceTextInput] = []
    private var metricsSnapshot: ExperienceInteractiveViewModelSnapshot?
    private var semanticDrafts: [InputTarget: ExperienceSemanticTextDraft] = [:]
    private var bindingsByTarget: [InputTarget: Binding] = [:]
    private var runtimeGeometryByRun: [String: NuxieNativeTextRunGeometry] = [:]
    private var invalidGeometryIDs = Set<InputTarget>()
    private var lastAppliedPlacements: [InputTarget: ExperienceTextInputPlacement] = [:]
    private var baselineCorrections: [InputTarget: (metrics: ExperienceTextInputMetrics, offset: CGFloat)] = [:]
    private var metricsByTarget: [InputTarget: ExperienceTextInputMetrics] = [:]
    private var invalidMetricIDs = Set<InputTarget>()
    private var lastAppliedMetrics: [InputTarget: ExperienceTextInputMetrics] = [:]
    private var textValuesByTarget: [InputTarget: String] = [:]
    private var notifiedTextByTarget: [InputTarget: String] = [:]
    private var fontSHA256ByUniqueName: [String: String] = [:]
    private var systemFontWeightsByUniqueName: [String: String] = [:]
    private var failedInputIDs = Set<InputTarget>()
    private var semanticFields: [InputTarget: NuxieNativeSemanticNode]?
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
        semanticContentOffsetWriter: SemanticContentOffsetWriter? = nil,
        semanticTextReader: SemanticTextReader? = nil,
        textWriter: @escaping TextWriter
    ) {
        if activeBuildID != renderPlan.identity.buildId {
            textValuesByTarget.removeAll()
            notifiedTextByTarget.removeAll()
            activeBuildID = renderPlan.identity.buildId
        }
        clear()
        self.surfaceView = surfaceView
        self.artboardBounds = artboardBounds
        self.textWriter = textWriter
        self.semanticTextWriter = semanticTextWriter
        self.semanticContentOffsetWriter = semanticContentOffsetWriter
        self.semanticTextReader = semanticTextReader
        if semanticTextWriter != nil { semanticFields = [:] }
        fontSHA256ByUniqueName = renderPlan.fonts.reduce(into: [:]) {
            $0[$1.assetUniqueName] = $1.sha256
        }
        systemFontWeightsByUniqueName = renderPlan.systemFonts.reduce(into: [:]) {
            $0[$1.assetUniqueName] = $1.weight
        }

        let declared = renderPlan.textInputs.filter {
            $0.screenId == screenID && $0.editable
        }
        let counts = Dictionary(grouping: declared, by: \.inputId).mapValues(\.count)
        for input in declared where counts[input.inputId] == 1 {
            if input.editableValueName != nil {
                if semanticTextWriter != nil, semanticTextReader != nil { nativeInputs.append(input) }
                continue
            }
            let target = InputTarget(inputID: input.inputId)
            let control = makeControl(for: input)
            control.view.accessibilityIdentifier = "nuxie-text-input-\(input.inputId)"
            control.view.isAccessibilityElement = true
            control.text = textValuesByTarget[target] ?? input.value
            notifiedTextByTarget[target] = notifiedTextByTarget[target] ?? control.text
            surfaceView.addSubview(control.view)
            let binding = Binding(target: target, input: input, control: control)
            bindingsByTarget[target] = binding
            if semanticTextWriter != nil {
                semanticDrafts[target] = ExperienceSemanticTextDraft(text: control.text, needsInitialWrite: true)
            } else {
                write(control.text, for: binding)
            }
        }
        installDismissTapRecognizer(on: surfaceView)
        layout()
    }

    func invalidateLayout() {
        metricsSnapshot = nil
        runtimeGeometryByRun.removeAll()
        metricsByTarget.removeAll()
        lastAppliedMetrics.removeAll()
        invalidMetricIDs = Set(bindingsByTarget.keys)
        layout()
    }

    func update(frame: ExperienceInteractiveTextFrame) {
        guard let snapshot = frame.snapshot else { invalidateLayout(); return }
        metricsSnapshot = snapshot
        if case .captured(let captured) = frame.geometry {
            runtimeGeometryByRun = captured
        } else {
            runtimeGeometryByRun.removeAll()
        }
        let resolver = ExperienceTextInputMetricsResolver(snapshot: snapshot)
        metricsByTarget = bindingsByTarget.compactMapValues {
            resolver.metrics(xPath: $0.input.geometry.xPath,
                authored: .init(fontSize: $0.input.style.fontSize, lineHeight: $0.input.style.lineHeight))
        }
        invalidMetricIDs = Set(bindingsByTarget.keys).subtracting(metricsByTarget.keys)
        for inputID in invalidMetricIDs { lastAppliedMetrics.removeValue(forKey: inputID) }
        layout()
    }

    /// Exact runtime text-run association keeps each real editor in the scene tree once.
    func applySemantics(_ capture: NuxieNativeSemanticCapture) -> [UInt32: UIView] {
        reconcileNativeInputs(capture)
        let nodes = Dictionary(uniqueKeysWithValues: capture.tree.nodes.map { ($0.id, $0) })
        let fields = bindingsByTarget.compactMapValues { binding in
            if let nodeID = binding.target.nodeID { return nodes[nodeID] }
            return capture.fieldsByTextRun[binding.input.textRunName]
        }
        let counts = Dictionary(grouping: Array(fields.values), by: \.id).mapValues(\.count)
        let unique = fields.filter { counts[$0.value.id] == 1 }
        if semanticTextWriter == nil, semanticFields != unique { generation &+= 1 }
        semanticFields = unique
        layout()
        var controls: [UInt32: UIView] = [:]
        for (inputID, binding) in bindingsByTarget {
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
        for inputID in bindingsByTarget.keys { drainSemanticWrite(inputID) }
        for binding in bindingsByTarget.values where binding.target.nodeID != nil {
            refreshSource(binding, captureID: capture.id, renderRevision: capture.tree.renderRevision)
        }
        layout()
        return controls
    }

    private func reconcileNativeInputs(_ capture: NuxieNativeSemanticCapture) {
        guard let surfaceView else { return }
        var presented = Set<InputTarget>()
        for input in nativeInputs {
            guard let name = input.editableValueName else { continue }
            for occurrence in capture.nativeInputs[name] ?? [] {
                // Never copy a secure value into an ordinary UIKit control.
                guard occurrence.geometry.obscured == (input.secureTextEntry == true) else { continue }
                let target = InputTarget(inputID: input.inputId, nodeID: occurrence.nodeID)
                presented.insert(target)
                let binding: Binding
                if let existing = bindingsByTarget[target] {
                    binding = existing
                } else {
                    let control = makeControl(for: input)
                    control.text = ""
                    control.view.accessibilityIdentifier = "nuxie-text-input-\(input.inputId)-\(occurrence.nodeID)"
                    control.view.isAccessibilityElement = true
                    binding = Binding(target: target, input: input, control: control)
                    bindingsByTarget[target] = binding
                    if case .field(let field) = control {
                        field.onViewportChange = { [weak self, weak binding] in
                            guard let self, let binding else { return }
                            self.drainContentOffset(binding)
                        }
                    }
                    surfaceView.addSubview(control.view)
                }
                binding.nativeGeometry = occurrence.geometry
                if let snapshot = metricsSnapshot {
                    metricsByTarget[target] = ExperienceTextInputMetricsResolver(snapshot: snapshot).metrics(
                        xPath: input.geometry.xPath,
                        authored: .init(fontSize: input.style.fontSize, lineHeight: input.style.lineHeight))
                }
            }
        }
        for target in Array(bindingsByTarget.keys) where target.nodeID != nil && !presented.contains(target) {
            retireNativeInput(target)
        }
        invalidMetricIDs = Set(bindingsByTarget.keys).subtracting(metricsByTarget.keys)
    }

    private func retireNativeInput(_ target: InputTarget) {
        // Remove ownership before UIKit delivers resign/marked-text callbacks.
        let retired = bindingsByTarget.removeValue(forKey: target)
        semanticDrafts.removeValue(forKey: target)
        semanticFields?.removeValue(forKey: target)
        textValuesByTarget.removeValue(forKey: target)
        notifiedTextByTarget.removeValue(forKey: target)
        metricsByTarget.removeValue(forKey: target)
        lastAppliedMetrics.removeValue(forKey: target)
        lastAppliedPlacements.removeValue(forKey: target)
        baselineCorrections.removeValue(forKey: target)
        failedInputIDs.remove(target)
        retired?.control.view.resignFirstResponder()
        retired?.control.view.removeFromSuperview()
    }

    private func refreshSource(_ binding: Binding, captureID: UUID, renderRevision: UInt64) {
        guard let reader = semanticTextReader, allowsInteraction(binding),
              binding.sourceReadID == nil,
              binding.readCaptureID != captureID || binding.readRenderRevision != renderRevision else { return }
        binding.readCaptureID = captureID
        binding.readRenderRevision = renderRevision
        let requestID = UUID()
        binding.sourceReadID = requestID
        let writeGeneration = binding.sourceWriteGeneration
        let currentGeneration = generation
        reader(captureID, binding.target) { [weak self] result in
            guard let self, self.generation == currentGeneration,
                  self.bindingsByTarget[binding.target] === binding,
                  binding.sourceReadID == requestID else { return }
            binding.sourceReadID = nil
            guard self.allowsInteraction(binding) else {
                binding.readCaptureID = nil
                return
            }
            guard case .success(let source) = result else { return }
            let value = source.text
            let ownerChanged = binding.ownerInstanceID != source.ownerInstanceID
            // An asynchronous read may finish after a newer edit was admitted.
            // Keep owner changes authoritative, but never let an overlapping
            // read roll the same owner's editor back to its previous value.
            if binding.sourceReady, !ownerChanged,
               binding.sourceWriteGeneration != writeGeneration {
                binding.readCaptureID = nil
                return
            }
            binding.ownerInstanceID = source.ownerInstanceID
            if !binding.sourceReady || ownerChanged {
                self.semanticDrafts[binding.target] = ExperienceSemanticTextDraft(text: value)
                binding.control.text = value
                binding.sourceReady = true
            } else {
                // Detect marked text directly: UIKit can begin composition before
                // sending its editing-changed notification.
                self.semanticDrafts[binding.target]?.replaceText(binding.control.text,
                    isComposing: binding.control.hasMarkedText)
                if self.semanticDrafts[binding.target]?.receiveSourceValue(value) == true,
                   binding.control.text != value { binding.control.text = value }
            }
            self.semanticDrafts[binding.target]?.present(captureID: captureID)
            self.layout()
            self.drainSemanticWrite(binding.target)
            self.drainContentOffset(binding)
        }
    }

    private func restoreAcceptedText(_ binding: Binding) {
        binding.control.text = semanticDrafts[binding.target]?.acceptedText
            ?? textValuesByTarget[binding.target]
            ?? notifiedTextByTarget[binding.target] ?? binding.input.value
    }

    private func allowsInteraction(_ binding: Binding) -> Bool {
        guard !invalidMetricIDs.contains(binding.target),
              !invalidGeometryIDs.contains(binding.target) else { return false }
        guard let semanticFields else { return true }
        guard !hidden, let surfaceView,
              ExperienceSemanticAccessibilityElement.allowsInteraction(in: surfaceView),
              let node = semanticFields[binding.target] else { return false }
        return node.stateFlags & (NuxieNativeSemanticNode.disabled | NuxieNativeSemanticNode.hidden) == 0
    }

    private func allowsEditing(_ binding: Binding) -> Bool {
        guard allowsInteraction(binding) else { return false }
        if binding.target.nodeID != nil, !binding.sourceReady { return false }
        guard let semanticFields else { return true }
        guard let node = semanticFields[binding.target] else { return false }
        return node.stateFlags & NuxieNativeSemanticNode.readOnly == 0
    }

    private func isSemanticallyHidden(_ inputID: InputTarget) -> Bool {
        guard let semanticFields else { return false }
        guard let node = semanticFields[inputID] else { return true }
        return node.stateFlags & NuxieNativeSemanticNode.hidden != 0
    }

    func clear() {
        generation &+= 1
        for target in Array(bindingsByTarget.keys) where target.nodeID != nil {
            retireNativeInput(target)
        }
        bindingsByTarget.values.forEach { $0.control.view.removeFromSuperview() }
        bindingsByTarget.removeAll()
        semanticFields = nil
        semanticDrafts.removeAll()
        semanticTextWriter = nil
        semanticContentOffsetWriter = nil
        semanticTextReader = nil
        nativeInputs.removeAll()
        metricsSnapshot = nil
        runtimeGeometryByRun.removeAll()
        metricsByTarget.removeAll()
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
        if value {
            for target in Array(bindingsByTarget.keys) where target.nodeID != nil {
                retireNativeInput(target)
            }
        }
        if value, semanticTextWriter != nil {
            for (inputID, binding) in bindingsByTarget {
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
            invalidGeometryIDs = Set(bindingsByTarget.keys)
            for (inputID, binding) in bindingsByTarget {
                layoutRuntimeField(binding, inputID: inputID, placement: nil)
            }
            return
        }
        let placements = bindingsByTarget.compactMapValues { binding in
            if binding.target.nodeID != nil {
                return binding.nativeGeometry.flatMap {
                    ExperienceTextInputPlacement(nativeInput: $0, viewport: transform)
                }
            }
            return runtimeGeometryByRun[binding.input.textRunName].flatMap {
                ExperienceTextInputPlacement(geometry: $0, viewport: transform)
            }
        }
        invalidGeometryIDs = Set(bindingsByTarget.keys).subtracting(placements.keys)
        for (inputID, binding) in bindingsByTarget {
            layoutRuntimeField(binding, inputID: inputID, placement: placements[inputID])
        }
    }

    private func layoutRuntimeField(_ binding: Binding, inputID: InputTarget,
        placement: ExperienceTextInputPlacement?) {
        switch binding.control {
        case .field(let field): field.isEnabled = allowsInteraction(binding) && (binding.target.nodeID == nil || binding.sourceReady)
        case .textView(let textView):
            textView.isEditable = allowsEditing(binding)
            textView.isSelectable = allowsInteraction(binding)
        }
        guard let placement, let metrics = metricsByTarget[inputID] else {
            // Fence delegate callbacks before resigning a composing editor.
            binding.control.view.isHidden = true
            binding.control.view.resignFirstResponder()
            lastAppliedPlacements.removeValue(forKey: inputID)
            return
        }
        binding.control.view.isHidden = hidden || failedInputIDs.contains(inputID) || isSemanticallyHidden(inputID)
            || (binding.target.nodeID != nil && !binding.sourceReady)
        guard lastAppliedPlacements[inputID] != placement || lastAppliedMetrics[inputID] != metrics else { return }
        lastAppliedPlacements[inputID] = placement
        lastAppliedMetrics[inputID] = metrics
        applyStyle(binding.input.style, metrics: metrics, to: binding.control,
            secure: binding.input.secureTextEntry == true,
            hostPlaceholder: binding.input.editableValueName != nil)
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
        guard manager.numberOfGlyphs > 0 else {
            editor.textContainerInset = UIEdgeInsets(top: placement.textOrigin.y,
                left: placement.textOrigin.x, bottom: 0, right: 0)
            return
        }
        let firstGlyph = manager.glyphIndexForCharacter(at: 0)
        let fragment = manager.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
        let nativeBaseline = fragment.minY + manager.location(forGlyphAt: firstGlyph).y
        let correction: CGFloat
        if let baseline = placement.firstBaseline {
            correction = baseline.y - placement.textOrigin.y - nativeBaseline
            baselineCorrections[binding.target] = (metrics, correction)
        } else if let previous = baselineCorrections[binding.target], previous.metrics == metrics {
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
            let value = TextView(frame: .zero, textContainer: nil)
            value.delegate = self
            value.backgroundColor = .clear
            value.textContainerInset = .zero
            value.textContainer.lineFragmentPadding = 0
            value.keyboardType = Self.keyboardType(input.keyboardType)
            if input.editableValueName != nil { value.placeholderLabel.text = input.placeholder }
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
        secure: Bool,
        hostPlaceholder: Bool
    ) {
        let fontSize = CGFloat(metrics.fontSize)
        let font = Self.font(
            for: style,
            contentSHA256: fontSHA256ByUniqueName[style.fontAssetUniqueName],
            systemWeight: systemFontWeightsByUniqueName[style.fontAssetUniqueName],
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
            if secure || hostPlaceholder, let placeholder = field.placeholder {
                var placeholderAttributes = attributes
                placeholderAttributes[.foregroundColor] = color
                field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: placeholderAttributes)
            }
        case .textView(let textView):
            textView.font = font
            textView.textAlignment = alignment
            textView.textColor = textColor
            textView.tintColor = color
            textView.typingAttributes[.kern] = CGFloat(style.letterSpacing)
            textView.typingAttributes[.paragraphStyle] = paragraph
            if hostPlaceholder, let placeholder = textView.placeholderLabel.text {
                textView.placeholderLabel.attributedText = NSAttributedString(string: placeholder,
                    attributes: [.font: font, .foregroundColor: color,
                        .kern: CGFloat(style.letterSpacing), .paragraphStyle: paragraph])
                textView.updatePlaceholder()
            }
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
        (textView as? TextView)?.updatePlaceholder()
        flushTextChange(for: textView)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if let binding = binding(for: scrollView) { drainContentOffset(binding) }
    }

    func textFieldDidChangeSelection(_ textField: UITextField) {
        if let binding = binding(for: textField) { drainContentOffset(binding) }
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
        if let binding = binding(for: control) { drainContentOffset(binding) }
    }

    private func emitEditingEvent(_ kind: ExperienceTextInputEventKind, for control: UIView) {
        guard let binding = binding(for: control), allowsEditing(binding),
              !binding.control.hasMarkedText else { return }
        flushTextChange(for: control)
        if semanticTextWriter != nil {
            let events = semanticDrafts[binding.target]?.requestEvent(kind) ?? []
            for event in events { notifyEditingEvent(event, binding: binding) }
        } else {
            onEditingEvent?(binding.input, .init(kind: kind, text: binding.control.text))
        }
    }

    func flushTextChange(for control: UIView) {
        (control as? TextView)?.updatePlaceholder()
        guard let binding = binding(for: control) else { return }
        guard allowsEditing(binding) else { restoreAcceptedText(binding); return }
        propagateTextChange(from: control)
        guard !binding.control.hasMarkedText else { return }
        if semanticTextWriter != nil {
            if let text = semanticDrafts[binding.target]?.requestValueChange() {
                notifyAcceptedTextChange(text, binding: binding)
            }
            return
        }
        let text = binding.control.text
        guard notifiedTextByTarget[binding.target] != text else { return }
        notifiedTextByTarget[binding.target] = text
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
            semanticDrafts[binding.target]?.replaceText(text, isComposing: binding.control.hasMarkedText)
            drainSemanticWrite(binding.target)
            return
        }
        textValuesByTarget[binding.target] = text
        write(text, for: binding)
    }

    private func notifyAcceptedTextChange(_ text: String, binding: Binding) {
        notifiedTextByTarget[binding.target] = text
        onAcceptedTextChange?(binding.input, text)
    }

    private func notifyEditingEvent(_ event: ExperienceTextInputEvent, binding: Binding) {
        var scoped = event
        scoped.ownerInstanceID = binding.ownerInstanceID
        onEditingEvent?(binding.input, scoped)
    }

    private func drainSemanticWrite(_ inputID: InputTarget) {
        guard !hidden, let writer = semanticTextWriter,
              let binding = bindingsByTarget[inputID], allowsEditing(binding),
              let write = semanticDrafts[inputID]?.takeWrite() else { return }
        let currentGeneration = generation
        let rendered = binding.target.nodeID == nil && binding.input.secureTextEntry == true ? "" : write.text
        binding.textWriteInFlight = true
        binding.sourceWriteGeneration = UUID()
        writer(write.captureID, inputID, rendered) { [weak self] outcome in
            guard let self, self.generation == currentGeneration,
                  self.bindingsByTarget[inputID] === binding else { return }
            binding.textWriteInFlight = false
            binding.sourceWriteGeneration = UUID()
            // Shaping may update native cursor scrolling. Reapply the host
            // viewport after the newly edited text has settled and presented.
            if case .accepted = outcome { binding.lastOffset = nil }
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
            self.textValuesByTarget[inputID] = self.semanticDrafts[inputID]?.acceptedText
            if let commit { self.notifyAcceptedTextChange(commit, binding: binding) }
            let events = self.semanticDrafts[inputID]?.takeReadyEvents() ?? []
            for event in events { self.notifyEditingEvent(event, binding: binding) }
            if case .rejected = outcome { self.restoreAcceptedText(binding) }
            self.drainSemanticWrite(inputID)
        }
    }

    private func drainContentOffset(_ binding: Binding) {
        guard let writer = semanticContentOffsetWriter, binding.target.nodeID != nil,
              allowsEditing(binding), binding.sourceReady, binding.sourceReadID == nil,
              !binding.textWriteInFlight, !binding.offsetWriteInFlight,
              !binding.control.hasMarkedText,
              semanticDrafts[binding.target]?.acceptedText == binding.control.text,
              let captureID = binding.readCaptureID,
              binding.offsetAttemptCaptureID != captureID else { return }
        let offset: CGPoint
        if !binding.control.view.isFirstResponder {
            offset = .zero
        } else {
            switch binding.control {
            case .field(let field): offset = field.nativeContentOffset
            case .textView(let view): offset = CGPoint(x: 0, y: view.contentOffset.y + view.adjustedContentInset.top)
            }
        }
        guard offset.x.isFinite, offset.y.isFinite, binding.lastOffset != offset else { return }
        binding.offsetAttemptCaptureID = captureID
        binding.offsetWriteInFlight = true
        let currentGeneration = generation
        writer(captureID, binding.target, offset) { [weak self, weak binding] outcome in
            guard let self, let binding, self.generation == currentGeneration,
                  self.bindingsByTarget[binding.target] === binding else { return }
            binding.offsetWriteInFlight = false
            switch outcome {
            case .accepted: binding.lastOffset = offset
            case .staleCapture: break // Retry only from a fresh presented capture.
            case .rejected: binding.lastOffset = offset // Legacy assets may lack a scroll container.
            }
        }
    }

    private func write(_ text: String, for binding: Binding) {
        guard let textWriter else { return }
        let input = binding.input
        let rendered = input.secureTextEntry == true ? "" : text
        let currentGeneration = generation
        textWriter(input.inputId, rendered) { [weak self] result in
            guard let self, self.generation == currentGeneration,
                  self.bindingsByTarget[binding.target] === binding else { return }
            switch result {
            case .success:
                self.failedInputIDs.remove(binding.target)
            case .failure(let error):
                self.failedInputIDs.insert(binding.target)
                LogWarning(
                    "ExperienceTextInputOverlayBridge: failed to update '\(input.inputId)': \(error)"
                )
            }
            self.layout()
        }
    }

    private func binding(for control: UIView) -> Binding? {
        bindingsByTarget.values.first { $0.control.view === control }
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
               forUniqueName: style.fontAssetUniqueName,
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
        return !bindingsByTarget.values.contains {
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
