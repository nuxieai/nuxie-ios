#if canImport(UIKit)
import Foundation
import UIKit

private enum FlowTextInputGeometryProjectionError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

/// Resolves the publisher's reserved geometry graph once, then applies the
/// runtime's identity-bearing scalar stream without exposing graph traversal
/// to the UIKit editing implementation.
private struct FlowTextInputGeometryProjection {
    struct Geometry {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var rotation: Double
        var scaleX: Double
        var scaleY: Double

        mutating func set(_ value: Double, for property: String) -> Bool {
            switch property {
            case "x": x = value
            case "y": y = value
            case "width": width = value
            case "height": height = value
            case "rotation": rotation = value
            case "scaleX": scaleX = value
            case "scaleY": scaleY = value
            default: return false
            }
            return true
        }
    }

    struct Issue {
        let code: String
        let message: String
    }

    private struct Definition {
        let inputID: String
        let memberName: String
    }

    private struct Entry {
        let definition: Definition
        var leafInstanceID: FlowRuntimeInstanceID?
        var geometry: Geometry?
    }

    let artboardBounds: CGRect?
    let initialIssues: [Issue]
    private let rootInstanceID: FlowRuntimeInstanceID
    private var containerInstanceID: FlowRuntimeInstanceID?
    private var entriesByInputID: [String: Entry]
    private var reservedContainerInstanceIDs: Set<FlowRuntimeInstanceID>
    private var reservedLeafInstanceIDs: Set<FlowRuntimeInstanceID>

    init(
        inputs: [FlowArtifactTextInput],
        bootstrap: FlowRuntimeBootstrap
    ) throws {
        guard let root = bootstrap.catalog.rootInstance else {
            throw FlowTextInputGeometryProjectionError.invalid(
                "Runtime bootstrap has no root ViewModel instance"
            )
        }
        var issues: [Issue] = []
        let bounds = bootstrap.player.bounds
        let candidateArtboardBounds = CGRect(
            x: CGFloat(bounds.minX),
            y: CGFloat(bounds.minY),
            width: CGFloat(bounds.width),
            height: CGFloat(bounds.height)
        )
        let artboardBounds: CGRect?
        if candidateArtboardBounds.origin.x.isFinite,
           candidateArtboardBounds.origin.y.isFinite,
           candidateArtboardBounds.width.isFinite,
           candidateArtboardBounds.height.isFinite,
           candidateArtboardBounds.width > 0,
           candidateArtboardBounds.height > 0 {
            artboardBounds = candidateArtboardBounds
        } else {
            artboardBounds = nil
            issues.append(Self.bindIssue(
                "Runtime bootstrap has invalid authored artboard bounds"
            ))
        }

        var definitions: [Definition] = []
        definitions.reserveCapacity(inputs.count)
        for input in inputs {
            do {
                definitions.append(try Self.definition(for: input))
            } catch {
                issues.append(Self.bindIssue(String(describing: error)))
            }
        }

        var containerInstanceID: FlowRuntimeInstanceID?
        var entries = Dictionary(uniqueKeysWithValues: definitions.map {
            ($0.inputID, Entry(definition: $0, leafInstanceID: nil, geometry: nil))
        })
        var reservedContainerInstanceIDs = Set<FlowRuntimeInstanceID>()
        var reservedLeafInstanceIDs = Set<FlowRuntimeInstanceID>()
        do {
            let rootNodeIndex = try Self.nodeIndex(
                for: root.id,
                in: bootstrap.values
            )
            let rootFields = try Self.viewModelFields(
                at: rootNodeIndex,
                in: bootstrap.values,
                expectedInstanceID: root.id,
                label: "root ViewModel"
            ).fields
            let containerNodeIndex = try Self.uniqueField(
                "nuxieTextInputs",
                in: rootFields,
                label: "root ViewModel"
            )
            let container = try Self.viewModelFields(
                at: containerNodeIndex,
                in: bootstrap.values,
                expectedInstanceID: nil,
                label: "nuxieTextInputs"
            )
            containerInstanceID = container.instanceID
            reservedContainerInstanceIDs.insert(container.instanceID)
            // The full reserved subtree belongs to the native UI contract,
            // even when this manifest declares no UIKit control for a child.
            // Discover by identity instead of suppressing arbitrary names.
            for field in container.fields {
                guard field.key != nil,
                      bootstrap.values.nodes.indices.contains(field.nodeIndex),
                      case .viewModel(_, let leafInstanceID?, _) =
                          bootstrap.values.nodes[field.nodeIndex].value else {
                    continue
                }
                reservedLeafInstanceIDs.insert(leafInstanceID)
            }
            for definition in definitions {
                let resolved = Self.entry(
                    for: definition,
                    containerFields: container.fields,
                    arena: bootstrap.values
                )
                entries[definition.inputID] = resolved.entry
                if let issue = resolved.issue {
                    issues.append(issue)
                }
                if let leafInstanceID = resolved.entry.leafInstanceID {
                    reservedLeafInstanceIDs.insert(leafInstanceID)
                }
            }
        } catch {
            // Keep the authoritative root reservation even when a descendant
            // is malformed so reserved UI state fails closed.
            issues.append(Self.bindIssue(String(describing: error)))
        }

        self.artboardBounds = artboardBounds
        self.initialIssues = issues
        self.rootInstanceID = root.id
        self.containerInstanceID = containerInstanceID
        self.entriesByInputID = entries
        self.reservedContainerInstanceIDs = reservedContainerInstanceIDs
        self.reservedLeafInstanceIDs = reservedLeafInstanceIDs
    }

    func geometry(for inputID: String) -> Geometry? {
        guard let geometry = entriesByInputID[inputID]?.geometry,
              geometry.width > 0,
              geometry.height > 0 else {
            return nil
        }
        return geometry
    }

    mutating func consume(
        _ result: FlowRuntimeOperationResult
    ) -> (issues: [Issue], reservedOutputSequences: Set<UInt64>) {
        var issues: [Issue] = []
        var reservedOutputSequences = Set<UInt64>()
        for output in result.orderedOutputs {
            let change: FlowRuntimeStateChange
            switch output.payload {
            case .stateChange(let value), .viewModelChange(let value):
                change = value
            case .delayedEvent, .reportedEvent, .hostCommand,
                 .renderRequest, .runtimeAdvanced:
                continue
            }

            let firstPathSegment = change.path.split(separator: "/", maxSplits: 1)
                .first.map(String.init)
            let isReservedRootPath = change.instanceID == rootInstanceID
                && firstPathSegment == "nuxieTextInputs"
            let isReservedContainerPath = change.instanceID.map {
                reservedContainerInstanceIDs.contains($0)
            } == true
            let isReservedLeafPath = change.instanceID.map {
                reservedLeafInstanceIDs.contains($0)
            } == true
            if isReservedRootPath || isReservedContainerPath || isReservedLeafPath {
                reservedOutputSequences.insert(output.sequence)
            }

            if isReservedContainerPath,
               let advertisedChildID = change.viewModelReference?.instanceID {
                // Every identity-bearing child of the reserved container is
                // native-owned, including children unknown to this manifest.
                reservedLeafInstanceIDs.insert(advertisedChildID)
            }

            if change.instanceID == rootInstanceID,
               change.path == "nuxieTextInputs" {
                if let advertisedID = change.viewModelReference?.instanceID {
                    // Reserve the replacement identity before reading its
                    // arena. A malformed/missing arena must not let later
                    // outputs from the advertised native subtree escape.
                    reservedContainerInstanceIDs.insert(advertisedID)
                }
                do {
                    issues.append(contentsOf: try rebindOuterViewModel(
                        reference: change.viewModelReference,
                        values: result.values
                    ))
                } catch {
                    invalidateAll()
                    issues.append(Issue(
                        code: "nuxie_ios.text_input_outer_view_model_rebind_failed",
                        message: "FlowTextInputOverlayBridge: failed to rebind nuxieTextInputs: \(error)"
                    ))
                }
                continue
            }

            if let containerInstanceID,
               change.instanceID == containerInstanceID,
               let inputID = entriesByInputID.values.first(where: {
                   $0.definition.memberName == change.path
               })?.definition.inputID {
                if var entry = entriesByInputID[inputID] {
                    entry.geometry = nil
                    entry.leafInstanceID = change.viewModelReference?.instanceID
                    entriesByInputID[inputID] = entry
                }
                issues.append(Issue(
                    code: "nuxie_ios.text_input_inner_view_model_replacement",
                    message: "FlowTextInputOverlayBridge: input '\(inputID)' replaced its inner geometry ViewModel; inner replacement is unsupported"
                ))
                continue
            }

            guard let instanceID = change.instanceID else { continue }
            var invalidatedGeometry = false
            for inputID in Array(entriesByInputID.keys) {
                guard var entry = entriesByInputID[inputID],
                      entry.leafInstanceID == instanceID,
                      var geometry = entry.geometry,
                      Self.geometryPropertyNames.contains(change.path) else {
                    continue
                }
                guard case .number(let number)? = change.value,
                      number.isFinite else {
                    entry.geometry = nil
                    entriesByInputID[inputID] = entry
                    invalidatedGeometry = true
                    continue
                }
                let wasUsable = geometry.width > 0 && geometry.height > 0
                _ = geometry.set(number, for: change.path)
                entry.geometry = geometry
                entriesByInputID[inputID] = entry
                if wasUsable && (geometry.width <= 0 || geometry.height <= 0) {
                    invalidatedGeometry = true
                }
            }
            if invalidatedGeometry {
                issues.append(Self.bindIssue(
                    "Runtime geometry update '\(change.path)' is not a valid finite geometry value"
                ))
            }
        }
        return (issues, reservedOutputSequences)
    }

    private static let geometryPropertyNames: Set<String> = [
        "x", "y", "width", "height", "rotation", "scaleX", "scaleY",
    ]

    private mutating func rebindOuterViewModel(
        reference: FlowRuntimeViewModelReference?,
        values: FlowRuntimeValueArena?
    ) throws -> [Issue] {
        guard let reference else {
            throw FlowTextInputGeometryProjectionError.invalid(
                "replacement omitted its ViewModel identity"
            )
        }
        guard let values else {
            throw FlowTextInputGeometryProjectionError.invalid(
                "replacement omitted its authoritative value arena"
            )
        }
        let containerNodeIndex = try Self.nodeIndex(
            for: reference.instanceID,
            in: values
        )
        let container = try Self.viewModelFields(
            at: containerNodeIndex,
            in: values,
            expectedInstanceID: reference.instanceID,
            label: "replacement nuxieTextInputs"
        )
        var rebound: [String: Entry] = [:]
        var issues: [Issue] = []
        rebound.reserveCapacity(entriesByInputID.count)
        for existing in entriesByInputID.values {
            let definition = existing.definition
            let resolved = Self.entry(
                for: definition,
                containerFields: container.fields,
                arena: values
            )
            rebound[definition.inputID] = resolved.entry
            if let issue = resolved.issue {
                issues.append(issue)
            }
        }
        containerInstanceID = container.instanceID
        reservedContainerInstanceIDs.insert(container.instanceID)
        entriesByInputID = rebound
        for field in container.fields {
            guard field.key != nil,
                  values.nodes.indices.contains(field.nodeIndex),
                  case .viewModel(_, let leafInstanceID?, _) =
                      values.nodes[field.nodeIndex].value else {
                continue
            }
            reservedLeafInstanceIDs.insert(leafInstanceID)
        }
        reservedLeafInstanceIDs.formUnion(rebound.values.compactMap(\.leafInstanceID))
        return issues
    }

    private mutating func invalidateAll() {
        for inputID in Array(entriesByInputID.keys) {
            guard var entry = entriesByInputID[inputID] else { continue }
            entry.geometry = nil
            entry.leafInstanceID = nil
            entriesByInputID[inputID] = entry
        }
    }

    private static func definition(
        for input: FlowArtifactTextInput
    ) throws -> Definition {
        let paths: [(path: String, property: String)] = [
            (input.geometry.xPath, "x"),
            (input.geometry.yPath, "y"),
            (input.geometry.widthPath, "width"),
            (input.geometry.heightPath, "height"),
            (input.geometry.rotationPath, "rotation"),
            (input.geometry.scaleXPath, "scaleX"),
            (input.geometry.scaleYPath, "scaleY"),
        ]
        var memberName: String?
        for item in paths {
            let segments = item.path.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard segments.count == 3,
                  segments[0] == "nuxieTextInputs",
                  !segments[1].isEmpty,
                  segments[2] == item.property else {
                throw FlowTextInputGeometryProjectionError.invalid(
                    "Text input '\(input.inputId)' has unsupported geometry path '\(item.path)'"
                )
            }
            if let memberName, memberName != segments[1] {
                throw FlowTextInputGeometryProjectionError.invalid(
                    "Text input '\(input.inputId)' spans multiple geometry ViewModels"
                )
            }
            memberName = segments[1]
        }
        guard let memberName else {
            throw FlowTextInputGeometryProjectionError.invalid(
                "Text input '\(input.inputId)' has no geometry paths"
            )
        }
        return Definition(inputID: input.inputId, memberName: memberName)
    }

    private static func entry(
        for definition: Definition,
        containerFields: [FlowRuntimeValueEdge],
        arena: FlowRuntimeValueArena
    ) -> (entry: Entry, issue: Issue?) {
        do {
            let inputNodeIndex = try uniqueField(
                definition.memberName,
                in: containerFields,
                label: "nuxieTextInputs"
            )
            let input = try viewModelFields(
                at: inputNodeIndex,
                in: arena,
                expectedInstanceID: nil,
                label: "text input '\(definition.inputID)'"
            )
            do {
                let geometry = try Geometry(
                    x: number("x", fields: input.fields, arena: arena),
                    y: number("y", fields: input.fields, arena: arena),
                    width: number("width", fields: input.fields, arena: arena),
                    height: number("height", fields: input.fields, arena: arena),
                    rotation: number("rotation", fields: input.fields, arena: arena),
                    scaleX: number("scaleX", fields: input.fields, arena: arena),
                    scaleY: number("scaleY", fields: input.fields, arena: arena)
                )
                return (
                    Entry(
                        definition: definition,
                        leafInstanceID: input.instanceID,
                        geometry: geometry
                    ),
                    geometry.width > 0 && geometry.height > 0
                        ? nil
                        : bindIssue(
                            "Text input '\(definition.inputID)' has non-positive runtime geometry"
                        )
                )
            } catch {
                // Identity remains usable even when authored scalars are
                // malformed. Continue reserving every direct output from it.
                return (
                    Entry(
                        definition: definition,
                        leafInstanceID: input.instanceID,
                        geometry: nil
                    ),
                    bindIssue(String(describing: error))
                )
            }
        } catch {
            return (
                Entry(definition: definition, leafInstanceID: nil, geometry: nil),
                bindIssue(String(describing: error))
            )
        }
    }

    private static func bindIssue(_ message: String) -> Issue {
        Issue(
            code: "nuxie_ios.text_input_geometry_bind_failed",
            message: "FlowTextInputOverlayBridge: failed to bind runtime geometry: \(message)"
        )
    }

    private static func nodeIndex(
        for instanceID: FlowRuntimeInstanceID,
        in arena: FlowRuntimeValueArena
    ) throws -> Int {
        let matchingRoots = arena.roots.filter { $0.instanceID == instanceID }
        guard matchingRoots.count == 1 else {
            throw FlowTextInputGeometryProjectionError.invalid(
                "Value arena has no unique root for instance \(instanceID.rawValue)"
            )
        }
        return matchingRoots[0].nodeIndex
    }

    private static func viewModelFields(
        at nodeIndex: Int,
        in arena: FlowRuntimeValueArena,
        expectedInstanceID: FlowRuntimeInstanceID?,
        label: String
    ) throws -> (instanceID: FlowRuntimeInstanceID, fields: [FlowRuntimeValueEdge]) {
        guard arena.nodes.indices.contains(nodeIndex),
              case .viewModel(_, let instanceID?, let fields) = arena.nodes[nodeIndex].value,
              expectedInstanceID == nil || instanceID == expectedInstanceID else {
            throw FlowTextInputGeometryProjectionError.invalid(
                "\(label) is not the expected identity-bearing ViewModel"
            )
        }
        return (instanceID, fields)
    }

    private static func uniqueField(
        _ name: String,
        in fields: [FlowRuntimeValueEdge],
        label: String
    ) throws -> Int {
        let matches = fields.filter { $0.key == name }
        guard matches.count == 1 else {
            throw FlowTextInputGeometryProjectionError.invalid(
                "\(label) has no unique '\(name)' field"
            )
        }
        return matches[0].nodeIndex
    }

    private static func number(
        _ name: String,
        fields: [FlowRuntimeValueEdge],
        arena: FlowRuntimeValueArena
    ) throws -> Double {
        let nodeIndex = try uniqueField(name, in: fields, label: "text-input geometry")
        guard arena.nodes.indices.contains(nodeIndex),
              case .scalar(.number(let value)) = arena.nodes[nodeIndex].value,
              value.isFinite else {
            throw FlowTextInputGeometryProjectionError.invalid(
                "Text-input geometry '\(name)' is not a finite number"
            )
        }
        return value
    }
}

@MainActor
final class FlowTextInputOverlayBridge: NSObject, UITextFieldDelegate, UITextViewDelegate {
    typealias TextWriter = (
        _ text: String,
        _ runName: String,
        _ completion: @escaping @MainActor (
            Result<FlowRuntimeOperationResult, Error>
        ) -> Void
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

    private weak var surfaceView: UIView?
    private var geometryProjection: FlowTextInputGeometryProjection?
    private var textWriter: TextWriter?
    private var bindingsByInputId: [String: Binding] = [:]
    private var textValuesByInputId: [String: String] = [:]
    private var committedTextByInputId: [String: String] = [:]
    private var activeBuildId: String?
    private var fontSHA256ByRiveUniqueName: [String: String] = [:]
    private var failedRunNames = Set<String>()
    private var bindingGeneration: UInt64 = 0
    private var hidden = false
    private weak var activeEditingControl: UIView?
    private var keyboardShift: CGFloat = 0
    private var dismissTapRecognizer: UITapGestureRecognizer?

    /// Fired when an editable input ends editing with a value that changed
    /// since its last commit. The host decides what a commit means (response
    /// capture); the bridge only owns the native editing lifecycle.
    var onCommitText: ((FlowArtifactTextInput, String) -> Void)?

    /// Stable warnings for control-local bind failures and unsupported
    /// publisher topology. The screen may log or include these in tracing;
    /// neither condition terminates the runtime session.
    var onDiagnostic: ((FlowRuntimeDiagnostic) -> Void)?

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
        surfaceView: UIView,
        bootstrap: FlowRuntimeBootstrap,
        textWriter: @escaping TextWriter
    ) {
        if activeBuildId != artifact.manifest.buildId {
            textValuesByInputId.removeAll()
            committedTextByInputId.removeAll()
            activeBuildId = artifact.manifest.buildId
        }
        clear()

        self.surfaceView = surfaceView
        self.textWriter = textWriter
        failedRunNames.removeAll()
        let declaredInputs = artifact.manifest.textInputs.filter {
            $0.screenId == screenId && $0.editable
        }
        var seenInputIDs = Set<String>()
        var duplicateInputIDs = Set<String>()
        for input in declaredInputs where !seenInputIDs.insert(input.inputId).inserted {
            duplicateInputIDs.insert(input.inputId)
        }
        for inputID in duplicateInputIDs.sorted(by: { lhs, rhs in
            lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
        }) {
            emitDiagnostic(
                code: "nuxie_ios.text_input_duplicate_id",
                message: "FlowTextInputOverlayBridge: duplicate text input ID '\(inputID)' is disabled"
            )
        }
        let inputs = declaredInputs.filter { !duplicateInputIDs.contains($0.inputId) }

        do {
            let projection = try FlowTextInputGeometryProjection(
                inputs: inputs,
                bootstrap: bootstrap
            )
            geometryProjection = projection
            for issue in projection.initialIssues {
                emitDiagnostic(code: issue.code, message: issue.message)
            }
        } catch {
            geometryProjection = nil
            emitDiagnostic(
                code: "nuxie_ios.text_input_geometry_bind_failed",
                message: "FlowTextInputOverlayBridge: failed to bind runtime geometry: \(error)"
            )
        }

        fontSHA256ByRiveUniqueName = artifact.manifest.assets.fonts.reduce(into: [:]) {
            $0[$1.riveUniqueName] = $1.sha256
        }

        for input in inputs {
            let control = makeControl(for: input)
            control.view.accessibilityIdentifier = "nuxie-text-input-\(input.inputId)"
            control.view.isAccessibilityElement = true
            control.view.isHidden = hidden
            control.text = textValuesByInputId[input.inputId] ?? input.value
            // Seed the committed baseline so blur-without-change never emits.
            if committedTextByInputId[input.inputId] == nil {
                committedTextByInputId[input.inputId] = control.text
            }

            surfaceView.addSubview(control.view)
            bindingsByInputId[input.inputId] = Binding(input: input, control: control)
            setRuntimeTextRunValue(control.text, for: input)
        }

        installDismissTapRecognizer(on: surfaceView)
        layout()
    }

    func clear() {
        // Invalidate late text-run completions before detaching their controls.
        bindingGeneration &+= 1
        for binding in bindingsByInputId.values {
            binding.control.view.removeFromSuperview()
        }
        bindingsByInputId.removeAll()
        lastAppliedFrames.removeAll()
        lastAppliedRotations.removeAll()
        if let dismissTapRecognizer {
            dismissTapRecognizer.view?.removeGestureRecognizer(dismissTapRecognizer)
        }
        dismissTapRecognizer = nil
        activeEditingControl = nil
        applyKeyboardShift(0, animationDuration: 0)
        fontSHA256ByRiveUniqueName.removeAll()
        geometryProjection = nil
        failedRunNames.removeAll()
        textWriter = nil
        surfaceView = nil
    }

    func setHidden(_ isHidden: Bool) {
        hidden = isHidden
        layout()
    }

    /// Per-input cache of the last applied layout so the runtime's per-frame
    /// call only does real work when geometry actually moved —
    /// applyStyle (font creation) per input per frame is measurable.
    private var lastAppliedFrames: [String: CGRect] = [:]
    private var lastAppliedRotations: [String: CGFloat] = [:]

    func layout() {
        guard let surfaceView,
              let projection = geometryProjection,
              let artboardBounds = projection.artboardBounds,
              let transform = FlowContainCenterTransform(
                  artboardBounds: artboardBounds,
                  viewportBounds: surfaceView.bounds
              ) else {
            bindingsByInputId.values.forEach { $0.control.view.isHidden = true }
            return
        }

        for (inputId, binding) in bindingsByInputId {
            guard let geometry = projection.geometry(for: binding.input.inputId),
                  geometry.width > 0,
                  geometry.height > 0 else {
                binding.control.view.isHidden = true
                lastAppliedFrames.removeValue(forKey: inputId)
                continue
            }
            binding.control.view.isHidden = hidden
                || failedRunNames.contains(binding.input.riveTextRunName)
            let frame = Self.frame(
                for: geometry,
                transform: transform
            )
            // Unchanged since the last pass → skip style + transform work.
            if lastAppliedFrames[inputId] == frame,
               lastAppliedRotations[inputId] == CGFloat(geometry.rotation) {
                continue
            }
            lastAppliedFrames[inputId] = frame
            lastAppliedRotations[inputId] = CGFloat(geometry.rotation)
            let styleScaleX = transform.scale * max(0, CGFloat(geometry.scaleX))
            let styleScaleY = transform.scale * max(0, CGFloat(geometry.scaleY))
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
                    binding.control.view.transform = CGAffineTransform(
                        rotationAngle: CGFloat(geometry.rotation)
                    )
                }
            }
        }
    }

    /// Applies identity-bearing geometry outputs before canonical state
    /// reconciliation, then removes only those reserved outputs from the
    /// result passed to `FlowRuntimeStateBridge`. All other ordered output
    /// families remain byte-for-byte and order-for-order intact.
    @discardableResult
    func consume(
        _ result: FlowRuntimeOperationResult
    ) -> FlowRuntimeOperationResult {
        guard geometryProjection != nil else { return result }
        let consumed = geometryProjection?.consume(result)
            ?? (issues: [], reservedOutputSequences: [])
        for issue in consumed.issues {
            emitDiagnostic(code: issue.code, message: issue.message)
        }
        guard !consumed.reservedOutputSequences.isEmpty else { return result }
        return result.replacingOrderedOutputs(
            result.orderedOutputs.filter {
                !consumed.reservedOutputSequences.contains($0.sequence)
            }
        )
    }

    private static func frame(
        for geometry: FlowTextInputGeometryProjection.Geometry,
        transform: FlowContainCenterTransform
    ) -> CGRect {
        var frame = transform.viewportRect(
            fromArtboard: CGRect(
                x: CGFloat(geometry.x),
                y: CGFloat(geometry.y),
                width: CGFloat(geometry.width),
                height: CGFloat(geometry.height)
            )
        )
        frame.size.width *= max(0, CGFloat(geometry.scaleX))
        frame.size.height *= max(0, CGFloat(geometry.scaleY))
        return frame
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
        guard let surfaceView else {
            return
        }
        let transform: CGAffineTransform = shift == 0
            ? .identity
            : CGAffineTransform(translationX: 0, y: -shift)
        guard animationDuration > 0 else {
            surfaceView.transform = transform
            return
        }
        UIView.animate(withDuration: animationDuration, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
            surfaceView.transform = transform
        }
    }

    // MARK: Tap-outside dismissal

    private func installDismissTapRecognizer(on surfaceView: UIView) {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDismissTap(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delegate = self
        surfaceView.addGestureRecognizer(recognizer)
        dismissTapRecognizer = recognizer
    }

    @objc private func handleDismissTap(_ recognizer: UITapGestureRecognizer) {
        surfaceView?.endEditing(true)
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
        guard let binding = binding(for: control) else {
            return
        }

        let nextText = binding.control.text
        textValuesByInputId[binding.input.inputId] = nextText
        setRuntimeTextRunValue(nextText, for: binding.input)
    }

    private func setRuntimeTextRunValue(
        _ text: String,
        for input: FlowArtifactTextInput
    ) {
        guard let textWriter else { return }
        let renderedText = input.secureTextEntry == true ? "" : text
        let generation = bindingGeneration
        textWriter(renderedText, input.riveTextRunName) { [weak self] result in
            guard let self, self.bindingGeneration == generation else { return }
            switch result {
            case .success:
                self.failedRunNames.remove(input.riveTextRunName)
            case .failure(let error):
                self.failedRunNames.insert(input.riveTextRunName)
                self.emitDiagnostic(
                    code: "nuxie_ios.text_run_bind_failed",
                    message: "FlowTextInputOverlayBridge: failed to update text run '\(input.riveTextRunName)': \(error)"
                )
            }
            self.layout()
        }
    }

    private func emitDiagnostic(code: String, message: String) {
        onDiagnostic?(FlowRuntimeDiagnostic(
            severity: .warning,
            code: code,
            message: message
        ))
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

private extension FlowRuntimeOperationResult {
    func replacingOrderedOutputs(
        _ orderedOutputs: [FlowRuntimeOutput]
    ) -> FlowRuntimeOperationResult {
        FlowRuntimeOperationResult(
            renderOutcome: renderOutcome,
            surfaceDisposition: surfaceDisposition,
            isDirty: isDirty,
            isSettled: isSettled,
            wakeAfter: wakeAfter,
            orderedOutputs: orderedOutputs,
            diagnostics: diagnostics,
            bootstrap: bootstrap,
            values: values,
            catalog: catalog,
            playerInputs: playerInputs,
            createdInstances: createdInstances
        )
    }
}

extension FlowTextInputOverlayBridge: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Never steal from the runtime surface's own touch handling.
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
