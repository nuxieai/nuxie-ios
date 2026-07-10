#if canImport(RiveRuntime) && canImport(UIKit)
import Foundation
import RiveRuntime
import UIKit

struct FlowViewModelBridgeProperty: Equatable {
    let name: String
    let type: String
}

struct FlowViewModelBridgeDefinition: Equatable {
    let name: String
    let instanceNames: [String]
    let properties: [FlowViewModelBridgeProperty]
}

enum FlowViewModelBridgeError: LocalizedError, Equatable {
    case artboardUnavailable
    case instanceNotBound
    case propertyMissing(path: String, expectedType: String)

    var errorDescription: String? {
        switch self {
        case .artboardUnavailable:
            return "The active Rive artboard is not available."
        case .instanceNotBound:
            return "No Rive ViewModel instance is bound."
        case .propertyMissing(let path, let expectedType):
            return "The bound Rive ViewModel has no \(expectedType) property at \(path)."
        }
    }
}

/// Outcome of pushing host-provided safe-area insets into the bound
/// view-model instance's reserved `safeArea` object.
enum FlowSafeAreaPushOutcome: Equatable {
    /// The insets were written to the bound instance.
    case pushed
    /// The bound view model has no `safeArea` number properties (published
    /// flows predating the safe-area env system).
    case unsupported
    /// No view-model instance is bound yet.
    case notBound
}

@MainActor
final class FlowViewModelBridge {
    typealias ImageResolver = (String) -> RiveRenderImage?
    typealias ValueChangeHandler = (_ path: VmPathRef, _ value: Any, _ source: String?) -> Void

    /// Reserved view-model object fed by the host with real device safe-area
    /// insets. Host-written like `nuxieTextInputs`; both subtrees are skipped
    /// when installing value-change listeners so host writes never echo back
    /// as renderer-originated view-model changes.
    static let safeAreaPropertyName = "safeArea"
    private static let hostWrittenPropertyNames: Set<String> = [
        "nuxieTextInputs",
        FlowViewModelBridge.safeAreaPropertyName,
    ]

    private struct ResolvedPath {
        let viewModelId: String
        let path: String
        let property: ViewModelProperty?
    }

    private let fnvOffsetBasis: UInt32 = 0x811c9dc5
    private let fnvPrime: UInt32 = 0x01000193

    private let model: RiveModel
    private let remoteFlow: RemoteFlow?
    private let imageResolver: ImageResolver?
    private let onValueChange: ValueChangeHandler?
    private var flowViewModelsById: [String: ViewModel] = [:]
    private var flowViewModelsByName: [String: ViewModel] = [:]
    private var riveViewModelsByName: [String: RiveDataBindingViewModel] = [:]
    private var boundFlowViewModelId: String?
    private var selectedFlowInstanceId: String?
    private var flowInstanceViewModelIds: [String: String] = [:]
    private var flowInstanceIdsByViewModelId: [String: [String]] = [:]
    private var riveInstancesByFlowInstanceId: [String: RiveDataBindingViewModel.Instance] = [:]
    private var boundViewModel: RiveDataBindingViewModel?
    private(set) var boundInstance: RiveDataBindingViewModel.Instance?
    private var boundValueListeners: [(property: RiveDataBindingViewModel.Instance.Property, listenerId: UUID)] = []
    private var suppressingValueChangeNotifications = false

    var boundViewModelName: String? {
        boundViewModel?.name
    }

    var boundInstanceName: String? {
        boundInstance?.name
    }

    init(
        model: RiveModel,
        remoteFlow: RemoteFlow? = nil,
        imageResolver: ImageResolver? = nil,
        onValueChange: ValueChangeHandler? = nil
    ) {
        self.model = model
        self.remoteFlow = remoteFlow
        self.imageResolver = imageResolver
        self.onValueChange = onValueChange

        for index in 0..<model.riveFile.viewModelCount {
            guard let viewModel = model.riveFile.viewModel(at: index) else { continue }
            riveViewModelsByName[viewModel.name] = viewModel
            let flowViewModel = Self.flowViewModel(from: viewModel, hashNameId: hashNameId)
            flowViewModelsById[flowViewModel.id] = flowViewModel
            flowViewModelsByName[flowViewModel.name] = flowViewModel
        }

        if let remoteFlow {
            for value in remoteFlow.viewModelValues ?? [] {
                guard let instanceId = value.instanceId else { continue }
                recordFlowInstance(instanceId, viewModelId: value.viewModelName)
            }
        }
    }

    func discoverViewModels() -> [FlowViewModelBridgeDefinition] {
        (0..<model.riveFile.viewModelCount).compactMap { index in
            guard let viewModel = model.riveFile.viewModel(at: index) else { return nil }
            return FlowViewModelBridgeDefinition(
                name: viewModel.name,
                instanceNames: viewModel.instanceNames,
                properties: viewModel.properties.map { property in
                    FlowViewModelBridgeProperty(
                        name: property.name,
                        type: Self.propertyTypeName(property.type)
                    )
                }
            )
        }
    }

    @discardableResult
    func bindDefaultInstanceForActiveArtboard() throws -> Bool {
        guard let artboard = model.artboard else {
            throw FlowViewModelBridgeError.artboardUnavailable
        }

        guard let viewModel = model.riveFile.defaultViewModel(for: artboard) else {
            return false
        }

        guard let instance = viewModel.createDefaultInstance() ?? viewModel.createInstance() else {
            return false
        }

        artboard.bind(viewModelInstance: instance)
        model.stateMachine?.bind(viewModelInstance: instance)

        boundViewModel = viewModel
        boundInstance = instance
        boundFlowViewModelId = flowViewModelsByName[viewModel.name]?.id
        installBoundValueListeners()
        return true
    }

    func setString(_ value: String, path: String) throws {
        guard let property = try boundInstanceOrThrow().stringProperty(fromPath: path) else {
            throw FlowViewModelBridgeError.propertyMissing(path: path, expectedType: "string")
        }
        property.value = value
    }

    func stringValue(path: String) throws -> String {
        guard let property = try boundInstanceOrThrow().stringProperty(fromPath: path) else {
            throw FlowViewModelBridgeError.propertyMissing(path: path, expectedType: "string")
        }
        return property.value
    }

    func stringValue(path: String, instanceId: String) throws -> String {
        guard let instance = riveInstancesByFlowInstanceId[instanceId] else {
            throw FlowViewModelBridgeError.instanceNotBound
        }
        guard let property = instance.stringProperty(fromPath: path) else {
            throw FlowViewModelBridgeError.propertyMissing(path: path, expectedType: "string")
        }
        return property.value
    }

    func setNumber(_ value: Float, path: String) throws {
        guard let property = try boundInstanceOrThrow().numberProperty(fromPath: path) else {
            throw FlowViewModelBridgeError.propertyMissing(path: path, expectedType: "number")
        }
        property.value = value
    }

    func numberValue(path: String) throws -> Float {
        guard let property = try boundInstanceOrThrow().numberProperty(fromPath: path) else {
            throw FlowViewModelBridgeError.propertyMissing(path: path, expectedType: "number")
        }
        return property.value
    }

    func updateBoundListeners() {
        boundInstance?.updateListeners()
    }

    /// Writes device safe-area insets (already mapped into artboard units)
    /// into the bound instance's reserved `safeArea` object.
    ///
    /// Tolerant by design: published flows that predate the safe-area env
    /// system have no `safeArea` view model, which reports `.unsupported`
    /// instead of throwing so callers can quietly stop pushing.
    @discardableResult
    func pushSafeAreaInsets(_ insets: FlowSafeAreaInsets) -> FlowSafeAreaPushOutcome {
        guard let boundInstance else {
            return .notBound
        }

        let values: [(edge: String, value: Double)] = [
            ("top", insets.top),
            ("bottom", insets.bottom),
            ("left", insets.left),
            ("right", insets.right),
        ]

        var didWrite = false
        for (edge, value) in values {
            let path = "\(Self.safeAreaPropertyName)/\(edge)"
            guard let property = boundInstance.numberProperty(fromPath: path) else {
                continue
            }
            property.value = Float(value)
            didWrite = true
        }

        return didWrite ? .pushed : .unsupported
    }

    func numberValue(path: String, instanceId: String) throws -> Float {
        guard let instance = riveInstancesByFlowInstanceId[instanceId] else {
            throw FlowViewModelBridgeError.instanceNotBound
        }
        guard let property = instance.numberProperty(fromPath: path) else {
            throw FlowViewModelBridgeError.propertyMissing(path: path, expectedType: "number")
        }
        return property.value
    }

    func listCount(path: String) throws -> Int {
        guard let property = try boundInstanceOrThrow().listProperty(fromPath: path) else {
            throw FlowViewModelBridgeError.propertyMissing(path: path, expectedType: "list")
        }
        return Int(property.count)
    }

    func setBoolean(_ value: Bool, path: String) throws {
        guard let property = try boundInstanceOrThrow().booleanProperty(fromPath: path) else {
            throw FlowViewModelBridgeError.propertyMissing(path: path, expectedType: "boolean")
        }
        property.value = value
    }

    func booleanValue(path: String) throws -> Bool {
        guard let property = try boundInstanceOrThrow().booleanProperty(fromPath: path) else {
            throw FlowViewModelBridgeError.propertyMissing(path: path, expectedType: "boolean")
        }
        return property.value
    }

    @discardableResult
    func fireTrigger(path: String) throws -> Bool {
        guard let trigger = try boundInstanceOrThrow().triggerProperty(fromPath: path) else {
            return false
        }
        trigger.trigger()
        return true
    }

    @discardableResult
    func applySnapshot(_ snapshot: FlowViewModelSnapshot, screenId: String?) -> Bool {
        let instances = snapshot.viewModelInstances
        let selectedInstanceId = selectedFlowInstanceId ?? defaultFlowInstanceId(screenId: screenId, instances: instances)
        selectedFlowInstanceId = selectedInstanceId

        let didApply = withHostMutation {
            var didApply = false
            for value in snapshot.values {
                let viewModelId = value.viewModelName
                guard let flowViewModel = flowViewModelsById[viewModelId] else { continue }
                if let instanceId = value.instanceId {
                    recordFlowInstance(instanceId, viewModelId: viewModelId)
                }

                guard let riveInstance = riveInstance(
                    forFlowInstanceId: value.instanceId,
                    flowViewModel: flowViewModel
                ) else {
                    continue
                }

                didApply = applyValue(
                    value.value.value,
                    property: resolveProperty(value.path, in: flowViewModel),
                    path: value.path,
                    to: riveInstance
                ) || didApply
            }
            boundInstance?.updateListeners()
            return didApply
        }
        return didApply
    }

    @discardableResult
    func bindDefaultInstance(forScreenId screenId: String) -> Bool {
        guard let screen = remoteFlow?.screens.first(where: { $0.id == screenId }),
              let target = defaultRiveInstance(for: screen) else {
            return false
        }

        model.artboard?.bind(viewModelInstance: target.instance)
        model.stateMachine?.bind(viewModelInstance: target.instance)
        selectedFlowInstanceId = target.instanceId
        boundFlowViewModelId = target.viewModelId
        boundViewModel = target.viewModelId
            .flatMap { flowViewModelsById[$0] }
            .flatMap { riveViewModelsByName[$0.name] }
        boundInstance = target.instance
        installBoundValueListeners()
        return true
    }

    @discardableResult
    func applyValue(path: VmPathRef, value: Any, screenId: String?, instanceId: String?) -> Bool {
        guard let resolved = resolvePath(path, screenId: screenId, instanceId: instanceId),
              let instance = instance(for: resolved.viewModelId, screenId: screenId, instanceId: instanceId) else {
            return false
        }
        let didApply = applyValue(value, property: resolved.property, path: resolved.path, to: instance)
        if didApply {
            if let list = instance.listProperty(fromPath: resolved.path) {
                _ = syncListIndexValues(property: resolved.property, list: list)
            }
            withHostMutation {
                instance.updateListeners()
            }
        }
        return didApply
    }

    @discardableResult
    func fireTrigger(path: VmPathRef, screenId: String?, instanceId: String?) -> Bool {
        guard let resolved = resolvePath(path, screenId: screenId, instanceId: instanceId),
              let instance = instance(for: resolved.viewModelId, screenId: screenId, instanceId: instanceId),
              let trigger = instance.triggerProperty(fromPath: resolved.path) else {
            return false
        }
        trigger.trigger()
        withHostMutation {
            instance.updateListeners()
        }
        return true
    }

    @discardableResult
    func applyListOperation(
        _ operation: FlowViewModelListOperation,
        path: VmPathRef,
        payload: [String: Any],
        screenId: String?,
        instanceId: String?
    ) -> Bool {
        guard let resolved = resolvePath(path, screenId: screenId, instanceId: instanceId),
              let instance = instance(for: resolved.viewModelId, screenId: screenId, instanceId: instanceId),
              let list = instance.listProperty(fromPath: resolved.path) else {
            return false
        }

        let didApply: Bool
        switch operation {
        case .insert:
            guard let item = listItemInstance(from: payload["value"], property: resolved.property) else { return false }
            if let index = intValue(payload["index"]) {
                let clampedIndex = min(max(index, 0), Int(list.count))
                didApply = list.insert(item, at: Int32(clampedIndex))
            } else {
                list.append(item)
                didApply = true
            }
        case .remove:
            guard let index = intValue(payload["index"]), index >= 0, index < Int(list.count) else { return false }
            list.remove(at: Int32(index))
            didApply = true
        case .swap:
            let from = intValue(payload["from"]) ?? intValue(payload["indexA"])
            let to = intValue(payload["to"]) ?? intValue(payload["indexB"])
            guard let from, let to, from >= 0, to >= 0, from < Int(list.count), to < Int(list.count) else { return false }
            list.swap(at: UInt32(from), with: UInt32(to))
            didApply = true
        case .move:
            guard let from = intValue(payload["from"]),
                  let to = intValue(payload["to"]),
                  from >= 0,
                  to >= 0,
                  from < Int(list.count),
                  let item = list.instance(at: Int32(from)) else {
                return false
            }
            list.remove(at: Int32(from))
            didApply = list.insert(item, at: Int32(min(to, Int(list.count))))
        case .set:
            guard let index = intValue(payload["index"]),
                  index >= 0,
                  index < Int(list.count),
                  let item = listItemInstance(from: payload["value"], property: resolved.property) else {
                return false
            }
            list.remove(at: Int32(index))
            didApply = list.insert(item, at: Int32(index))
        case .clear:
            _ = clearList(list)
            didApply = true
        }

        if didApply {
            _ = syncListIndexValues(property: resolved.property, list: list)
            withHostMutation {
                instance.updateListeners()
            }
        }
        return didApply
    }

    private func withHostMutation<T>(_ body: () -> T) -> T {
        suppressingValueChangeNotifications = true
        defer { suppressingValueChangeNotifications = false }
        return body()
    }

    private func installBoundValueListeners() {
        removeBoundValueListeners()
        guard let onValueChange,
              let instance = boundInstance,
              let viewModelId = boundFlowViewModelId,
              let viewModel = flowViewModelsById[viewModelId] else {
            return
        }

        installValueListeners(
            in: instance,
            schema: viewModel.properties,
            viewModelName: viewModel.name,
            pathPrefix: "",
            onValueChange: onValueChange
        )
    }

    private func removeBoundValueListeners() {
        for listener in boundValueListeners {
            listener.property.removeListener(listener.listenerId)
        }
        boundValueListeners.removeAll()
    }

    private func installValueListeners(
        in instance: RiveDataBindingViewModel.Instance,
        schema: [String: ViewModelProperty],
        viewModelName: String,
        pathPrefix: String,
        onValueChange: @escaping ValueChangeHandler
    ) {
        for (name, property) in schema {
            if Self.hostWrittenPropertyNames.contains(name) {
                continue
            }
            let path = pathPrefix.isEmpty ? name : "\(pathPrefix)/\(name)"
            switch property.type {
            case .string:
                guard let riveProperty = instance.stringProperty(fromPath: path) else { continue }
                let listenerId = riveProperty.addListener { [weak self] value in
                    self?.emitValueChange(
                        viewModelName: viewModelName,
                        path: path,
                        value: value,
                        onValueChange: onValueChange
                    )
                }
                boundValueListeners.append((riveProperty, listenerId))
            case .number, .list_index:
                guard let riveProperty = instance.numberProperty(fromPath: path) else { continue }
                let listenerId = riveProperty.addListener { [weak self] value in
                    self?.emitValueChange(
                        viewModelName: viewModelName,
                        path: path,
                        value: value,
                        onValueChange: onValueChange
                    )
                }
                boundValueListeners.append((riveProperty, listenerId))
            case .boolean:
                guard let riveProperty = instance.booleanProperty(fromPath: path) else { continue }
                let listenerId = riveProperty.addListener { [weak self] value in
                    self?.emitValueChange(
                        viewModelName: viewModelName,
                        path: path,
                        value: value,
                        onValueChange: onValueChange
                    )
                }
                boundValueListeners.append((riveProperty, listenerId))
            case .enum:
                guard let riveProperty = instance.enumProperty(fromPath: path) else { continue }
                let listenerId = riveProperty.addListener { [weak self] value in
                    self?.emitValueChange(
                        viewModelName: viewModelName,
                        path: path,
                        value: value,
                        onValueChange: onValueChange
                    )
                }
                boundValueListeners.append((riveProperty, listenerId))
            case .trigger:
                guard let riveProperty = instance.triggerProperty(fromPath: path) else { continue }
                let listenerId = riveProperty.addListener { [weak self] in
                    self?.emitValueChange(
                        viewModelName: viewModelName,
                        path: path,
                        value: true,
                        onValueChange: onValueChange
                    )
                }
                boundValueListeners.append((riveProperty, listenerId))
            case .object:
                guard let nestedSchema = property.schema else { continue }
                installValueListeners(
                    in: instance,
                    schema: nestedSchema,
                    viewModelName: viewModelName,
                    pathPrefix: path,
                    onValueChange: onValueChange
                )
            case .viewModel:
                if let nestedSchema = property.schema {
                    installValueListeners(
                        in: instance,
                        schema: nestedSchema,
                        viewModelName: viewModelName,
                        pathPrefix: path,
                        onValueChange: onValueChange
                    )
                    continue
                }
                guard let nestedViewModelId = property.viewModelId,
                      let nestedViewModel = flowViewModelsById[nestedViewModelId] else { continue }
                installValueListeners(
                    in: instance,
                    schema: nestedViewModel.properties,
                    viewModelName: viewModelName,
                    pathPrefix: path,
                    onValueChange: onValueChange
                )
            case .color, .image, .list:
                continue
            }
        }
    }

    private func emitValueChange(
        viewModelName: String,
        path: String,
        value: Any,
        onValueChange: ValueChangeHandler
    ) {
        guard !suppressingValueChangeNotifications else { return }
        onValueChange(
            VmPathRef(viewModelName: viewModelName, path: path),
            value,
            "rive"
        )
    }

    func isTriggerPath(path: VmPathRef, screenId: String?, instanceId: String?) -> Bool {
        guard let resolved = resolvePath(path, screenId: screenId, instanceId: instanceId) else { return false }
        return resolved.property?.type == .trigger
    }

    private func applyValues(
        _ values: [String: Any],
        schema: [String: ViewModelProperty],
        rootPath: String,
        to instance: RiveDataBindingViewModel.Instance
    ) -> Bool {
        var didApply = false
        for (key, value) in values {
            guard let property = schema[key] else { continue }
            let path = rootPath.isEmpty ? key : "\(rootPath)/\(key)"
            didApply = applyValue(value, property: property, path: path, to: instance) || didApply
        }
        return didApply
    }

    private func applyValue(
        _ rawValue: Any,
        property: ViewModelProperty?,
        path: String,
        to instance: RiveDataBindingViewModel.Instance
    ) -> Bool {
        let value = unwrap(rawValue)

        switch property?.type {
        case .string:
            guard let string = stringValue(value) else { return false }
            instance.stringProperty(fromPath: path)?.value = string
            return instance.stringProperty(fromPath: path) != nil
        case .image:
            guard let imageProperty = instance.imageProperty(fromPath: path) else { return false }
            if let image = value as? RiveRenderImage {
                imageProperty.setValue(image)
                return true
            }
            guard let imageKey = stringValue(value),
                  let image = imageResolver?(imageKey) else {
                return false
            }
            imageProperty.setValue(image)
            return true
        case .number, .list_index:
            guard let number = floatValue(value) else { return false }
            instance.numberProperty(fromPath: path)?.value = number
            return instance.numberProperty(fromPath: path) != nil
        case .boolean:
            guard let bool = boolValue(value) else { return false }
            instance.booleanProperty(fromPath: path)?.value = bool
            return instance.booleanProperty(fromPath: path) != nil
        case .enum:
            guard let string = stringValue(value) else { return false }
            instance.enumProperty(fromPath: path)?.value = string
            return instance.enumProperty(fromPath: path) != nil
        case .color:
            guard let color = colorValue(value),
                  let property = instance.colorProperty(fromPath: path) else {
                return false
            }
            property.value = color
            return true
        case .trigger:
            guard boolValue(value) == true || intValue(value).map({ $0 != 0 }) == true else { return false }
            instance.triggerProperty(fromPath: path)?.trigger()
            return instance.triggerProperty(fromPath: path) != nil
        case .object:
            guard let nested = dictionaryValue(value), let schema = property?.schema else { return false }
            return applyValues(nested, schema: schema, rootPath: path, to: instance)
        case .viewModel:
            return applyNestedViewModel(value, property: property, path: path, to: instance)
        case .list:
            return applyListValue(value, property: property, path: path, to: instance)
        case nil:
            return applyBestEffortValue(value, path: path, to: instance)
        }
    }

    private func applyBestEffortValue(
        _ value: Any,
        path: String,
        to instance: RiveDataBindingViewModel.Instance
    ) -> Bool {
        if let string = stringValue(value), let property = instance.stringProperty(fromPath: path) {
            property.value = string
            return true
        }
        if let number = floatValue(value), let property = instance.numberProperty(fromPath: path) {
            property.value = number
            return true
        }
        if let bool = boolValue(value), let property = instance.booleanProperty(fromPath: path) {
            property.value = bool
            return true
        }
        if let string = stringValue(value), let property = instance.enumProperty(fromPath: path) {
            property.value = string
            return true
        }
        return false
    }

    private func applyNestedViewModel(
        _ value: Any,
        property: ViewModelProperty?,
        path: String,
        to instance: RiveDataBindingViewModel.Instance
    ) -> Bool {
        if let replacement = listItemInstance(from: value, property: property) {
            return instance.setViewModelInstanceProperty(fromPath: path, to: replacement)
        }

        guard let nestedValues = dictionaryValue(value),
              let nestedViewModelId = property?.viewModelId,
              let nestedViewModel = flowViewModelsById[nestedViewModelId] else {
            return false
        }
        return applyValues(nestedValues, schema: nestedViewModel.properties, rootPath: path, to: instance)
    }

    private func applyListValue(
        _ value: Any,
        property: ViewModelProperty?,
        path: String,
        to instance: RiveDataBindingViewModel.Instance
    ) -> Bool {
        guard let values = arrayValue(value),
              let list = instance.listProperty(fromPath: path) else {
            return false
        }

        let didClear = clearList(list)

        var didApply = didClear || values.isEmpty
        for value in values {
            guard let item = listItemInstance(from: value, property: property) else { continue }
            list.append(item)
            didApply = true
        }
        if didApply {
            _ = syncListIndexValues(property: property, list: list)
        }
        return didApply
    }

    private func clearList(_ list: RiveDataBindingViewModel.Instance.ListProperty) -> Bool {
        guard list.count > 0 else { return false }
        for index in stride(from: Int(list.count) - 1, through: 0, by: -1) {
            list.remove(at: Int32(index))
        }
        return true
    }

    private func listItemInstance(
        from rawValue: Any?,
        property: ViewModelProperty?
    ) -> RiveDataBindingViewModel.Instance? {
        guard let value = rawValue.map(unwrap) else { return nil }
        let dict = dictionaryValue(value)
        let instanceId = dict?["vmInstanceId"] as? String ?? dict?["instanceId"] as? String
        let viewModelId = dict?["viewModelId"] as? String
            ?? instanceId.flatMap { flowInstanceViewModelIds[$0] }
            ?? property?.itemType?.viewModelId
            ?? property?.viewModelId
        if let instanceId, let existing = riveInstancesByFlowInstanceId[instanceId] {
            if let viewModelId,
               let flowViewModel = flowViewModelsById[viewModelId],
               let values = dictionaryValue(dict?["values"] ?? value) {
                _ = applyValues(values, schema: flowViewModel.properties, rootPath: "", to: existing)
            }
            return existing
        }

        guard let viewModelId,
              let flowViewModel = flowViewModelsById[viewModelId],
              let instance = createRiveInstance(for: flowViewModel) else {
            return nil
        }

        if let instanceId {
            recordFlowInstance(instanceId, viewModelId: viewModelId)
            riveInstancesByFlowInstanceId[instanceId] = instance
        }
        if let values = dictionaryValue(dict?["values"] ?? value) {
            _ = applyValues(values, schema: flowViewModel.properties, rootPath: "", to: instance)
        }
        return instance
    }

    private func createRiveInstance(for flowViewModel: ViewModel) -> RiveDataBindingViewModel.Instance? {
        riveViewModelsByName[flowViewModel.name]?.createInstance()
    }

    private func riveInstance(
        forFlowInstanceId instanceId: String?,
        flowViewModel: ViewModel
    ) -> RiveDataBindingViewModel.Instance? {
        if let instanceId, let existing = riveInstancesByFlowInstanceId[instanceId] {
            return existing
        }

        let instance: RiveDataBindingViewModel.Instance?
        if flowViewModel.id == boundFlowViewModelId && shouldUseBoundInstance(for: instanceId) {
            instance = boundInstance
        } else {
            instance = createRiveInstance(for: flowViewModel)
        }

        if let instance, let instanceId {
            riveInstancesByFlowInstanceId[instanceId] = instance
        }
        return instance
    }

    private func recordFlowInstance(_ instanceId: String, viewModelId: String) {
        flowInstanceViewModelIds[instanceId] = viewModelId
        var instanceIds = flowInstanceIdsByViewModelId[viewModelId] ?? []
        if !instanceIds.contains(instanceId) {
            instanceIds.append(instanceId)
            flowInstanceIdsByViewModelId[viewModelId] = instanceIds
        }
    }

    private func defaultRiveInstance(
        for screen: RemoteFlowScreen
    ) -> (instanceId: String?, viewModelId: String?, instance: RiveDataBindingViewModel.Instance)? {
        if let instanceId = screen.defaultInstanceId,
           let instance = riveInstancesByFlowInstanceId[instanceId] {
            return (
                instanceId,
                flowInstanceViewModelIds[instanceId] ?? screen.defaultViewModelName,
                instance
            )
        }

        if let viewModelId = screen.defaultViewModelName {
            if let instanceId = flowInstanceIdsByViewModelId[viewModelId]?.first(where: {
                riveInstancesByFlowInstanceId[$0] != nil
            }),
               let instance = riveInstancesByFlowInstanceId[instanceId] {
                return (instanceId, viewModelId, instance)
            }
            if viewModelId == boundFlowViewModelId, let boundInstance {
                return (selectedFlowInstanceId, viewModelId, boundInstance)
            }
            if let flowViewModel = flowViewModelsById[viewModelId],
               let instance = createRiveInstance(for: flowViewModel) {
                if let instanceId = screen.defaultInstanceId {
                    recordFlowInstance(instanceId, viewModelId: viewModelId)
                    riveInstancesByFlowInstanceId[instanceId] = instance
                    return (instanceId, viewModelId, instance)
                }
                return (nil, viewModelId, instance)
            }
        }

        return nil
    }

    private func shouldUseBoundInstance(for instanceId: String?) -> Bool {
        guard let instanceId else { return true }
        if let selectedFlowInstanceId {
            return selectedFlowInstanceId == instanceId
        }
        selectedFlowInstanceId = instanceId
        return true
    }

    private func defaultFlowInstanceId(screenId: String?, instances: [ViewModelInstance]) -> String? {
        let screens = remoteFlow?.screens ?? []
        let orderedScreens: [RemoteFlowScreen]
        if let screenId, let screen = screens.first(where: { $0.id == screenId }) {
            orderedScreens = [screen] + screens.filter { $0.id != screenId }
        } else {
            orderedScreens = screens
        }

        for screen in orderedScreens {
            if let defaultInstanceId = screen.defaultInstanceId {
                return defaultInstanceId
            }
            if let defaultViewModelName = screen.defaultViewModelName,
               let instanceId = firstInstanceId(for: defaultViewModelName, in: instances) {
                return instanceId
            }
        }

        guard let boundFlowViewModelId else { return nil }
        return instances.first { $0.viewModelId == boundFlowViewModelId }?.instanceId
    }

    private func firstInstanceId(for viewModelId: String, in instances: [ViewModelInstance]) -> String? {
        instances.first { $0.viewModelId == viewModelId }?.instanceId
    }

    @discardableResult
    private func syncListIndexValues(
        property: ViewModelProperty?,
        list: RiveDataBindingViewModel.Instance.ListProperty
    ) -> Bool {
        let indexKeys: [String]
        if property?.type == .list,
           let itemType = property?.itemType,
           itemType.type == .viewModel,
           let itemViewModelId = itemType.viewModelId,
           let itemViewModel = flowViewModelsById[itemViewModelId] {
            indexKeys = itemViewModel.properties.compactMap { key, property in
                property.type == .list_index ? key : nil
            }
        } else {
            indexKeys = Array(Set(
                flowViewModelsById.values.flatMap { viewModel in
                    viewModel.properties.compactMap { key, property in
                        property.type == .list_index ? key : nil
                    }
                }
            )).sorted()
        }
        guard !indexKeys.isEmpty else { return false }

        var didApply = false
        for index in 0..<Int(list.count) {
            guard let item = list.instance(at: Int32(index)) else { continue }
            var didUpdateItem = false
            for key in indexKeys {
                guard let property = item.numberProperty(fromPath: key) else { continue }
                let value = Float(index)
                if property.value != value {
                    property.value = value
                    didApply = true
                    didUpdateItem = true
                }
            }
            if didUpdateItem {
                item.updateListeners()
            }
        }
        return didApply
    }

    private func instance(
        for viewModelId: String,
        screenId: String?,
        instanceId: String?
    ) -> RiveDataBindingViewModel.Instance? {
        if let instanceId, let instance = riveInstancesByFlowInstanceId[instanceId] {
            return instance
        }
        if let screenId,
           let screen = remoteFlow?.screens.first(where: { $0.id == screenId }),
           let defaultInstanceId = screen.defaultInstanceId,
           let defaultViewModelName = flowInstanceViewModelIds[defaultInstanceId],
           defaultViewModelName == viewModelId,
           let instance = riveInstancesByFlowInstanceId[defaultInstanceId] {
            return instance
        }
        if let screenId,
           let screen = remoteFlow?.screens.first(where: { $0.id == screenId }),
           screen.defaultInstanceId != nil,
           screen.defaultViewModelName == viewModelId,
           viewModelId == boundFlowViewModelId,
           selectedFlowInstanceId == nil || selectedFlowInstanceId == screen.defaultInstanceId {
            return boundInstance
        }
        if let screenId,
           let screen = remoteFlow?.screens.first(where: { $0.id == screenId }),
           screen.defaultViewModelName == viewModelId,
           viewModelId == boundFlowViewModelId {
            return boundInstance
        }
        if viewModelId == boundFlowViewModelId {
            return boundInstance
        }
        if let screenId,
           let screen = remoteFlow?.screens.first(where: { $0.id == screenId }),
           screen.defaultViewModelName == viewModelId,
           let cachedInstanceId = flowInstanceIdsByViewModelId[viewModelId]?.first(where: {
               riveInstancesByFlowInstanceId[$0] != nil
           }) {
            return riveInstancesByFlowInstanceId[cachedInstanceId]
        }
        if let cachedInstanceId = flowInstanceIdsByViewModelId[viewModelId]?.first(where: {
            riveInstancesByFlowInstanceId[$0] != nil
        }) {
            return riveInstancesByFlowInstanceId[cachedInstanceId]
        }
        guard let flowViewModel = flowViewModelsById[viewModelId] else { return nil }
        let instance = createRiveInstance(for: flowViewModel)
        if let instance, let instanceId {
            riveInstancesByFlowInstanceId[instanceId] = instance
        }
        return instance
    }

    private func resolvePath(_ path: VmPathRef, screenId: String?, instanceId: String?) -> ResolvedPath? {
        guard remoteFlow != nil else { return nil }

        let viewModel =
            path.viewModelName.flatMap { flowViewModelsByName[$0] } ??
            resolveRelativeViewModel(screenId: screenId, instanceId: instanceId) ??
            boundFlowViewModelId.flatMap { flowViewModelsById[$0] }
        guard let viewModel, !path.path.isEmpty else { return nil }
        return ResolvedPath(
            viewModelId: viewModel.id,
            path: path.path,
            property: resolveProperty(path.path, in: viewModel)
        )
    }

    private func resolveProperty(_ path: String, in viewModel: ViewModel) -> ViewModelProperty? {
        let segments = path.split(separator: "/").map(String.init)
        guard !segments.isEmpty else { return nil }
        var schema = viewModel.properties
        var property: ViewModelProperty?

        for (index, segment) in segments.enumerated() {
            guard let next = schema[segment] else { return nil }
            property = next
            if index == segments.count - 1 {
                return next
            }
            switch next.type {
            case .object:
                guard let nestedSchema = next.schema else { return nil }
                schema = nestedSchema
            case .viewModel:
                guard let nestedViewModelId = next.viewModelId,
                      let nestedViewModel = flowViewModelsById[nestedViewModelId] else {
                    return nil
                }
                schema = nestedViewModel.properties
            default:
                return nil
            }
        }

        return property
    }

    private func resolveRelativeViewModel(screenId: String?, instanceId: String?) -> ViewModel? {
        if let instanceId,
           let viewModelId = flowInstanceViewModelIds[instanceId],
           let viewModel = flowViewModelsById[viewModelId] {
            return viewModel
        }

        if let screenId,
           let screen = remoteFlow?.screens.first(where: { $0.id == screenId }) {
            if let defaultInstanceId = screen.defaultInstanceId,
               let viewModelId = flowInstanceViewModelIds[defaultInstanceId],
               let viewModel = flowViewModelsById[viewModelId] {
                return viewModel
            }
            if let defaultViewModelName = screen.defaultViewModelName,
               let viewModel = flowViewModelsById[defaultViewModelName] {
                return viewModel
            }
        }

        if let boundFlowViewModelId {
            return flowViewModelsById[boundFlowViewModelId]
        }

        return nil
    }

    private func boundInstanceOrThrow() throws -> RiveDataBindingViewModel.Instance {
        guard let boundInstance else {
            throw FlowViewModelBridgeError.instanceNotBound
        }
        return boundInstance
    }

    private func hashNameId(_ value: String) -> Int {
        if value.isEmpty { return Int(fnvOffsetBasis) }
        var hash = fnvOffsetBasis
        for byte in value.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* fnvPrime
        }
        return Int(hash)
    }

    private func unwrap(_ value: Any) -> Any {
        if let anyCodable = value as? AnyCodable {
            return anyCodable.value
        }
        return value
    }

    private func dictionaryValue(_ value: Any?) -> [String: Any]? {
        guard let value = value.map(unwrap) else { return nil }
        if let dict = value as? [String: Any] {
            return dict.mapValues(unwrap)
        }
        if let dict = value as? [String: AnyCodable] {
            return dict.mapValues { $0.value }
        }
        return nil
    }

    private func arrayValue(_ value: Any) -> [Any]? {
        let value = unwrap(value)
        if let array = value as? [Any] {
            return array.map(unwrap)
        }
        if let array = value as? [AnyCodable] {
            return array.map { $0.value }
        }
        return nil
    }

    private func stringValue(_ value: Any) -> String? {
        let value = unwrap(value)
        if let string = value as? String { return string }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.stringValue
        }
        return nil
    }

    private func floatValue(_ value: Any) -> Float? {
        let value = unwrap(value)
        if let float = value as? Float { return float }
        if let double = value as? Double { return Float(double) }
        if let int = value as? Int { return Float(int) }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.floatValue
        }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        guard let value = value.map(unwrap) else { return nil }
        if let int = value as? Int { return int }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.intValue
        }
        return nil
    }

    private func boolValue(_ value: Any) -> Bool? {
        let value = unwrap(value)
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        return nil
    }

    private func colorValue(_ value: Any) -> UIColor? {
        let value = unwrap(value)
        if let color = value as? UIColor { return color }
        if let int = intValue(value) {
            return UIColor(
                red: CGFloat((int >> 16) & 0xff) / 255,
                green: CGFloat((int >> 8) & 0xff) / 255,
                blue: CGFloat(int & 0xff) / 255,
                alpha: CGFloat((int >> 24) & 0xff) / 255
            )
        }
        guard var hex = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        guard let int = Int(hex, radix: 16) else { return nil }
        if hex.count == 6 {
            return UIColor(
                red: CGFloat((int >> 16) & 0xff) / 255,
                green: CGFloat((int >> 8) & 0xff) / 255,
                blue: CGFloat(int & 0xff) / 255,
                alpha: 1
            )
        }
        if hex.count == 8 {
            return UIColor(
                red: CGFloat((int >> 16) & 0xff) / 255,
                green: CGFloat((int >> 8) & 0xff) / 255,
                blue: CGFloat(int & 0xff) / 255,
                alpha: CGFloat((int >> 24) & 0xff) / 255
            )
        }
        return nil
    }

    private static func flowViewModel(
        from viewModel: RiveDataBindingViewModel,
        hashNameId: (String) -> Int
    ) -> ViewModel {
        let defaultInstance = viewModel.createDefaultInstance() ?? viewModel.createInstance()
        let properties = flowProperties(
            from: viewModel.properties,
            instance: defaultInstance
        )
        return ViewModel(
            id: viewModel.name,
            name: viewModel.name,
            viewModelPathId: hashNameId(viewModel.name),
            properties: properties
        )
    }

    private static func flowProperties(
        from properties: [RiveDataBindingViewModel.Instance.Property.Data],
        instance: RiveDataBindingViewModel.Instance?
    ) -> [String: ViewModelProperty] {
        Dictionary(
            uniqueKeysWithValues: properties.map { property in
                (
                    property.name,
                    flowProperty(from: property, instance: instance)
                )
            }
        )
    }

    private static func flowProperty(
        from property: RiveDataBindingViewModel.Instance.Property.Data,
        instance: RiveDataBindingViewModel.Instance?
    ) -> ViewModelProperty {
        let type = flowPropertyType(property.type)
        let nestedSchema: [String: ViewModelProperty]?
        if type == .viewModel,
           let nestedInstance = instance?.viewModelInstanceProperty(fromPath: property.name) {
            nestedSchema = flowProperties(from: nestedInstance.properties, instance: nestedInstance)
        } else {
            nestedSchema = nil
        }

        return ViewModelProperty(
            type: type,
            schema: nestedSchema
        )
    }

    private static func flowPropertyType(
        _ type: RiveDataBindingViewModel.Instance.Property.Data.DataType
    ) -> ViewModelPropertyType {
        switch type {
        case .string:
            return .string
        case .number, .integer:
            return .number
        case .boolean:
            return .boolean
        case .color:
            return .color
        case .list:
            return .list
        case .enum:
            return .enum
        case .trigger, .input:
            return .trigger
        case .viewModel:
            return .viewModel
        case .symbolListIndex:
            return .list_index
        case .assetImage:
            return .image
        case .artboard, .any, .none:
            return .object
        @unknown default:
            return .object
        }
    }

    private static func propertyTypeName(_ type: RiveDataBindingViewModel.Instance.Property.Data.DataType) -> String {
        switch type {
        case .none:
            return "none"
        case .string:
            return "string"
        case .number:
            return "number"
        case .boolean:
            return "boolean"
        case .color:
            return "color"
        case .list:
            return "list"
        case .enum:
            return "enum"
        case .trigger:
            return "trigger"
        case .viewModel:
            return "viewModel"
        case .integer:
            return "integer"
        case .symbolListIndex:
            return "symbolListIndex"
        case .assetImage:
            return "assetImage"
        case .artboard:
            return "artboard"
        case .input:
            return "input"
        case .any:
            return "any"
        @unknown default:
            return String(describing: type)
        }
    }
}
#endif
