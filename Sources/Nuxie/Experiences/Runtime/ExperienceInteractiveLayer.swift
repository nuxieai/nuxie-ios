#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import NuxieRuntime

/// One presentation layer's clock and list. Screen bindings and routing remain
/// on ExperienceInteractiveScreen, rooted at each retained row instance.
actor ExperienceInteractiveLayer {
    struct Step: Equatable, Sendable {
        let native: NuxieNativePlayerStepResult
        let rows: [String: ExperienceInteractiveStepResult]
        let unattributedEvents: [NuxieNativeEvent]
        // The current ABI supplies no source instance for script host commands.
        var unattributedHostCommands: [NuxieNativeHostCommand] { native.hostCommands }
    }

    struct Completion: Sendable {
        let id: UUID
        let events: AsyncStream<Void>
    }

    private struct Waiter {
        let name: String
        let continuation: AsyncStream<Void>.Continuation
    }

    private struct Row {
        let screen: JourneyScreen
        let reference: NuxieNativeViewModelReference
        let binding: ExperienceInteractiveScreen
        let products: [StoreProduct]
        var lifecycle: ExperienceScreenLifecycleState
        var waiters: [UUID: Waiter] = [:]
    }

    let runtime: NuxieNativeRuntime
    private let contract: NativeExperienceLayerHost
    private let payload: AuthenticatedRuntimePayload
    private let preparedFile: NuxieNativePreparedFile
    private let runValues: ExperienceRunValues?
    private let imageIDsByName: [String: UInt64]
    private let root: NuxieNativeViewModelReference
    private let gate = ExperienceInteractiveOperationGate()
    private let environment: NuxieNativeViewModelReference?
    private let environmentBindings: ExperienceEnvironmentBindings
    private let presentationHeight = ExperiencePresentationHeight()
    private var rows: [String: Row] = [:]
    private(set) var mountedScreenIDs: [String] = []
    private var closed = false
    private var activeScreenID: String?
    private var videoPlayback: ExperienceVideoPlayback?
    private nonisolated let layoutBounds = ExperienceLayoutBounds(.zero)
    nonisolated var artboardBounds: CGRect { layoutBounds.read() }
    private var currentReduceMotion: Bool

    private init(runtime: NuxieNativeRuntime, contract: NativeExperienceLayerHost,
                 payload: AuthenticatedRuntimePayload, preparedFile: NuxieNativePreparedFile,
                 runValues: ExperienceRunValues?, imageIDsByName: [String: UInt64],
                 root: NuxieNativeViewModelReference, environment: NuxieNativeViewModelReference?,
                 catalog: NuxieNativeViewModelCatalog, reduceMotion: Bool) {
        self.runtime = runtime
        self.contract = contract
        self.payload = payload
        self.preparedFile = preparedFile
        self.runValues = runValues
        self.imageIDsByName = imageIDsByName
        self.root = root
        self.environment = environment
        currentReduceMotion = reduceMotion
        environmentBindings = ExperienceEnvironmentBindings(catalog: catalog)
    }

    static func open(payload: AuthenticatedRuntimePayload, preparedFile: NuxieNativePreparedFile,
                     runValues: ExperienceRunValues?, imageIDsByName: [String: UInt64],
                     pixelWidth: UInt32, pixelHeight: UInt32,
                     reduceMotion: Bool, safeArea: ExperienceSafeAreaInsets?,
                     colorScheme: ExperienceColorScheme?, videoDecoderPool: ExperienceVideoDecoderPool? = nil) async throws -> ExperienceInteractiveLayer {
        guard let contract = payload.renderPlan.layerHost,
              let artboard = try await preparedFile.artboards().first(where: { $0.name == contract.artboardName }),
              let machine = artboard.stateMachines.first else {
            throw ExperienceInteractiveScreenError.stateContract("Layer host requires a root state machine")
        }
        let shared = try await runValues?.native(in: preparedFile)
        let runtime: NuxieNativeRuntime
        if let shared {
            runtime = try await shared.sessions.openSession(artboardName: contract.artboardName,
                player: .stateMachine(machine), pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                bindDefaultViewModel: true)
        } else {
            runtime = try await preparedFile.openSession(artboardName: contract.artboardName,
                player: .stateMachine(machine), pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                bindDefaultViewModel: true)
        }
        do {
            let root = try await runtime.rootViewModelReference()
            let catalog = try await runtime.viewModelCatalog()
            let snapshot = try await runtime.snapshot()
            guard let rootSchema = snapshot.instances.first(where: { $0.id == root.rawValue })?.schemaIndex,
                  catalog.properties.contains(where: {
                      $0.schemaIndex == rootSchema && $0.name == contract.listPath && $0.kind == .list
                  }) else {
                throw ExperienceInteractiveScreenError.stateContract("Layer host requires its Screen list")
            }
            guard snapshot.values.contains(where: {
                $0.ownerInstanceID == root.rawValue && $0.name == contract.listPath && $0.value == .list([])
            }) else {
                throw ExperienceInteractiveScreenError.stateContract("Layer host requires an empty initial Screen list")
            }
            let environment = try await runtime.bindGlobalViewModel(named: "env", sharingAcrossSessions: false)
            let layer = ExperienceInteractiveLayer(runtime: runtime, contract: contract,
                payload: payload, preparedFile: preparedFile, runValues: runValues,
                imageIDsByName: imageIDsByName, root: root, environment: environment, catalog: catalog, reduceMotion: reduceMotion)
            try await layer.updateEnvironment(reduceMotion: reduceMotion, safeArea: safeArea, colorScheme: colorScheme)
            try await layer.setLayoutSize(width: Float(pixelWidth), height: Float(pixelHeight))
            if !payload.renderPlan.videos.isEmpty {
                let playback = try await ExperienceVideoPlayback.open(runtime: runtime, payload: payload,
                    artboardBounds: CGRect(x: 0, y: 0, width: Int(pixelWidth), height: Int(pixelHeight)),
                    decoderPool: videoDecoderPool)
                await layer.setVideoPlayback(playback)
            }
            return layer
        } catch {
            try? await runtime.close()
            throw error
        }
    }

    func insertIncoming(screenID: String, style: ExperienceScreenTransitionSpec.Kind,
                        isBack: Bool, products: [StoreProduct] = []) async throws {
        try await gate.withLock { [self] in
            let index = await incomingIndex(style: style, isBack: isBack)
            try await insertLocked(screenID: screenID, at: index, products: products)
        }
    }

    private func incomingIndex(style: ExperienceScreenTransitionSpec.Kind, isBack: Bool) -> Int {
        style == .push && isBack ? 0 : mountedScreenIDs.count
    }

    func insert(screenID: String, at index: Int, products: [StoreProduct] = []) async throws {
        try await gate.withLock { [self] in try await insertLocked(screenID: screenID, at: index, products: products) }
    }

    private func insertLocked(screenID: String, at index: Int, products: [StoreProduct]) async throws {
        try requireOpen()
        guard !mountedScreenIDs.contains(screenID), mountedScreenIDs.count < 2,
              index >= 0, index <= mountedScreenIDs.count else {
            throw ExperienceInteractiveScreenError.stateContract("Invalid layer row insertion")
        }
        try await prepareRowLocked(screenID: screenID, products: products)
        guard let row = rows[screenID] else { return }
        _ = try await runtime.mutateViewModel([.listInsert(instance: root, path: contract.listPath,
            index: index, value: row.reference)])
        mountedScreenIDs.insert(screenID, at: index)
    }

    func prepareRow(screenID: String, products: [StoreProduct]) async throws -> ExperienceInteractiveScreen {
        try await gate.withLock { [self] in
            try await prepareRowLocked(screenID: screenID, products: products)
            return try await binding(screenID: screenID)
        }
    }

    func products(screenID: String) throws -> [StoreProduct] {
        try requireOpen()
        guard let row = rows[screenID] else {
            throw ExperienceInteractiveScreenError.screenNotFound(screenID)
        }
        return row.products
    }

    private func prepareRowLocked(screenID: String, products: [StoreProduct]) async throws {
        try requireOpen()
        if rows[screenID] == nil {
            guard let screen = payload.journey.screens.first(where: { $0.id == screenID }) else {
                throw ExperienceInteractiveScreenError.journeyScreenNotFound(screenID)
            }
            let catalog = try await runtime.viewModelCatalog()
            let selection = try ExperienceLayerHostContract.rowSelection(screen: screen, catalog: catalog)
            // ArtboardComponentList selects the Screen by its distinct root type.
            guard !payload.journey.screens.contains(where: {
                $0.id != screenID && $0.defaultViewModelName == screen.defaultViewModelName
            }) else {
                throw ExperienceInteractiveScreenError.stateContract("Layer Screens must have distinct root types")
            }
            let reference = try await runtime.makeViewModel(schemaIndex: selection.schemaIndex,
                authoredInstanceIndex: selection.authoredInstanceIndex)
            do {
                let binding = try await ExperienceInteractiveScreen.openPrepared(payload: payload,
                    preparedFile: preparedFile, runValues: runValues, imageIDsByName: imageIDsByName,
                    screenID: screenID, products: products, player: .defaultScene,
                    pixelWidth: 1, pixelHeight: 1, initialReduceMotion: nil, initialSafeArea: nil,
                    initialColorScheme: nil, rowRuntime: runtime, rowReference: reference, operationGate: gate,
                    rowVideoPlayback: videoPlayback)
                await binding.setRowStepper { [weak self] pointers, focus, elapsed, correlation, capturesText in
                    guard let self else { throw CancellationError() }
                    let step = try await self.step(pointers: pointers, focusInputs: focus,
                        elapsedSeconds: elapsed, correlationID: correlation, capturesTextLayout: capturesText)
                    // A retained row can finish a save after leaving the mounted list.
                    var result = step.rows[screenID] ?? ExperienceInteractiveStepResult(
                        keepGoing: step.native.keepGoing || step.rows.values.contains { $0.keepGoing },
                        pointerHits: step.rows.values.first?.pointerHits ?? [],
                        focusState: step.native.focusState, effects: [])
                    result.layerStep = step
                    return result
                }
                rows[screenID] = Row(screen: screen, reference: reference, binding: binding,
                    products: products, lifecycle: .init(reduceMotion: currentReduceMotion))
            } catch {
                try? await runtime.releaseViewModels([reference])
                throw error
            }
        }
        if activeScreenID == nil { activeScreenID = screenID }
    }

    func binding(screenID: String) throws -> ExperienceInteractiveScreen {
        try requireOpen()
        guard let binding = rows[screenID]?.binding else {
            throw ExperienceInteractiveScreenError.screenNotFound(screenID)
        }
        return binding
    }

    func activeBinding() throws -> ExperienceInteractiveScreen {
        guard let activeScreenID else { throw ExperienceInteractiveScreenError.stateContract("Layer has no active row") }
        return try binding(screenID: activeScreenID)
    }

    func selectActiveRow(_ screenID: String) throws {
        _ = try binding(screenID: screenID)
        activeScreenID = screenID
    }

    var deliveredVideoFrames: UInt64 { get async { await videoPlayback?.deliveredFrames ?? 0 } }

    func environmentSnapshot() async throws -> NuxieNativeViewModelSnapshot? {
        guard let environment else { return nil }
        return try await gate.withLock { [self] in try await runtime.snapshot(environment) }
    }

    private func setVideoPlayback(_ playback: ExperienceVideoPlayback) { videoPlayback = playback }

    func configurePresentationHeight(fitContent: Bool, size: CGSize) async throws {
        // The released ABI measures only the root, not an individual row's intrinsic height.
        guard !fitContent else {
            throw ExperienceInteractiveScreenError.stateContract("Active row intrinsic presentation height is unavailable")
        }
        if size.width > 0, size.height > 0 {
            try await setLayoutSize(width: Float(size.width), height: Float(size.height))
        }
    }

    @discardableResult
    func remove(screenID: String) async throws -> Step {
        try await gate.withLock { [self] in try await removeLocked(screenID: screenID) }
    }

    private func removeLocked(screenID: String) async throws -> Step {
        try requireOpen()
        guard let index = mountedScreenIDs.firstIndex(of: screenID) else {
            throw ExperienceInteractiveScreenError.stateContract("Screen is absent from the layer")
        }
        _ = try await runtime.mutateViewModel([.listRemove(instance: root, path: contract.listPath, index: index)])
        // https://universe.basis.dev/issue/UNIV-5186 requires settling removal before a timed advance.
        let settled = try await stepLocked(pointers: [], elapsedSeconds: 0, correlationID: 0)
        mountedScreenIDs.remove(at: index)
        return settled
    }

    /// Both halves commit before the next player advance.
    func setPhases(_ phases: [(String, ExperienceScreenLifecyclePhase)], transition: String = "",
                   reduceMotion: Bool? = nil, exitReason: ExperienceScreenExitReason = .navigation) async throws {
        try await gate.withLock { [self] in
            try await setPhasesLocked(phases, transition: transition, reduceMotion: reduceMotion, exitReason: exitReason)
        }
    }

    private func setPhasesLocked(_ phases: [(String, ExperienceScreenLifecyclePhase)], transition: String,
                                 reduceMotion: Bool?, exitReason: ExperienceScreenExitReason) async throws {
        try requireOpen()
        var updated: [String: ExperienceScreenLifecycleState] = [:]
        var mutations: [NuxieNativeViewModelMutation] = []
        if let reduceMotion {
            currentReduceMotion = reduceMotion
            if let environment {
                mutations += environmentBindings.mutations(reference: environment, reduceMotion: reduceMotion)
            }
        }
        for (id, phase) in phases {
            guard var row = rows[id] else { throw ExperienceInteractiveScreenError.screenNotFound(id) }
            let snapshot = row.lifecycle.move(to: phase, transition: transition,
                reduceMotion: reduceMotion ?? currentReduceMotion, exitReason: exitReason)
            mutations += try await row.binding.lifecycleMutations(snapshot, screen: row.screen)
            updated[id] = row.lifecycle
        }
        _ = try await runtime.mutateViewModel(mutations)
        for (id, lifecycle) in updated { rows[id]?.lifecycle = lifecycle }
    }

    func applyLifecycleSnapshot(_ snapshot: ExperienceScreenLifecycleSnapshot, screenID: String) async throws {
        try await gate.withLock { [self] in
            guard let row = await rows[screenID] else { throw ExperienceInteractiveScreenError.screenNotFound(screenID) }
            let mutations = try await row.binding.lifecycleMutations(snapshot, screen: row.screen)
            _ = try await runtime.mutateViewModel(mutations)
            await storeLifecycle(snapshot, screenID: screenID)
        }
    }

    private func storeLifecycle(_ snapshot: ExperienceScreenLifecycleSnapshot, screenID: String) {
        rows[screenID]?.lifecycle = .init(snapshot: snapshot)
    }

    func applyJourneyState(_ command: ExperienceInteractiveStateCommand, screenID: String,
                           correlationID: UInt64 = 0) async throws -> ExperienceInteractiveMutationResult? {
        guard let row = rows[screenID] else { throw ExperienceInteractiveScreenError.screenNotFound(screenID) }
        guard let filtered = command.suppressingLifecycleReservedJourneyWrites(
            rootViewModelName: row.screen.defaultViewModelName, rootInstanceID: row.screen.defaultInstanceId) else { return nil }
        return try await row.binding.applyStateCommand(filtered, correlationID: correlationID)
    }

    func snapshot(screenID: String) async throws -> NuxieNativeViewModelSnapshot {
        try await gate.withLock { [self] in
            guard let reference = await rows[screenID]?.reference else {
                throw ExperienceInteractiveScreenError.screenNotFound(screenID)
            }
            return try await runtime.snapshot(reference)
        }
    }

    func state(screenID: String) -> ExperienceScreenLifecycleState? { rows[screenID]?.lifecycle }

    func lifecycle(screenID: String) -> ExperienceScreenLifecycleSnapshot? { rows[screenID]?.lifecycle.snapshot }

    func registerCompletion(screenID: String, eventName: String) async throws -> Completion {
        try await gate.withLock { [self] in try await registerCompletionLocked(screenID: screenID, eventName: eventName) }
    }

    private func registerCompletionLocked(screenID: String, eventName: String) throws -> Completion {
        try requireOpen()
        guard rows[screenID] != nil else { throw ExperienceInteractiveScreenError.screenNotFound(screenID) }
        let id = UUID()
        let pair = AsyncStream<Void>.makeStream()
        rows[screenID]?.waiters[id] = Waiter(name: eventName, continuation: pair.continuation)
        return Completion(id: id, events: pair.stream)
    }

    func removeCompletion(screenID: String, id: UUID) async {
        await gate.withLock { [self] in await removeCompletionLocked(screenID: screenID, id: id) }
    }

    private func removeCompletionLocked(screenID: String, id: UUID) {
        rows[screenID]?.waiters.removeValue(forKey: id)?.continuation.finish()
    }

    func step(pointers: [NuxieNativePointerEvent] = [], focusInputs: [NuxieNativeFocusInput] = [], elapsedSeconds: Float,
              correlationID: UInt64 = 0, capturesTextLayout: Bool = false) async throws -> Step {
        try await gate.withLock { [self] in
            try await stepLocked(pointers: pointers, focusInputs: focusInputs, elapsedSeconds: elapsedSeconds, correlationID: correlationID,
                capturesTextLayout: capturesTextLayout)
        }
    }

    private func stepLocked(pointers: [NuxieNativePointerEvent], focusInputs: [NuxieNativeFocusInput] = [], elapsedSeconds: Float,
                            correlationID: UInt64, capturesTextLayout: Bool = false) async throws -> Step {
        try requireOpen()
        let frame = try await runtime.stepWithSnapshot(pointers: pointers, focusInputs: focusInputs, elapsedSeconds: elapsedSeconds,
            correlationID: correlationID)
        layoutBounds.update(size: try await runtime.layoutSize())
        try await videoPlayback?.resizeViewport(bounds: artboardBounds)
        let videoActive = try await videoPlayback?.tick() ?? false
        guard let snapshot = frame.snapshot else {
            throw ExperienceInteractiveScreenError.stateContract("Layer step requires an event-source snapshot")
        }
        var graphs: [String: NuxieNativeViewModelSnapshot] = [:]
        for id in mountedScreenIDs {
            guard let row = rows[id] else { continue }
            // Removal can detach a row during this advance; its final effects still belong to it.
            if let graph = snapshot.rooted(at: row.reference.rawValue) { graphs[id] = graph }
            else { graphs[id] = try await runtime.snapshot(row.reference) }
        }
        let eventOwners: [String?] = frame.result.events.map { event in
            guard let source = event.sourceViewModelInstanceID else { return nil }
            let matches = graphs.filter { $0.value.instances.contains(where: { $0.id == source }) }
            return matches.count == 1 ? matches.first?.key : nil
        }
        var projected: [String: ExperienceInteractiveStepResult] = [:]
        for id in mountedScreenIDs {
            guard let row = rows[id], let graph = graphs[id] else { continue }
            let ids = Set(graph.instances.map(\.id))
            let events: [NuxieNativeEvent] = frame.result.events.enumerated().compactMap { index, event in
                eventOwners[index] == id ? event : nil
            }
            for event in events {
                for (token, waiter) in row.waiters where waiter.name == event.name {
                    waiter.continuation.yield(())
                    waiter.continuation.finish()
                    rows[id]?.waiters.removeValue(forKey: token)
                }
            }
            let result = NuxieNativePlayerStepResult(keepGoing: frame.result.keepGoing || videoActive,
                pointerHits: frame.result.pointerHits, stateChanges: frame.result.stateChanges,
                events: events, hostCommands: [],
                viewModelChanges: frame.result.viewModelChanges.filter { ids.contains($0.ownerInstanceID) },
                textGeometry: frame.result.textGeometry, focusResults: frame.result.focusResults,
                focusState: frame.result.focusState)
            projected[id] = try await row.binding.projectRowStep(result, snapshot: graph, correlationID: correlationID, capturesTextLayout: capturesTextLayout)
        }
        return Step(native: frame.result, rows: projected,
            unattributedEvents: frame.result.events.enumerated().compactMap { index, event in
                eventOwners[index] == nil ? event : nil
            })
    }

    func updateEnvironment(reduceMotion: Bool? = nil, safeArea: ExperienceSafeAreaInsets? = nil,
                           viewport: ExperienceViewportEnvironment? = nil, fold: ExperienceFoldEnvironment? = nil,
                           colorScheme: ExperienceColorScheme? = nil) async throws {
        try await gate.withLock { [self] in
            try await updateEnvironmentLocked(reduceMotion: reduceMotion, safeArea: safeArea,
                viewport: viewport, fold: fold, colorScheme: colorScheme)
        }
    }

    private func updateEnvironmentLocked(reduceMotion: Bool?, safeArea: ExperienceSafeAreaInsets?,
                                         viewport: ExperienceViewportEnvironment?, fold: ExperienceFoldEnvironment?,
                                         colorScheme: ExperienceColorScheme?) async throws {
        try requireOpen()
        if let reduceMotion {
            currentReduceMotion = reduceMotion
            for id in rows.keys { _ = rows[id]?.lifecycle.updateReduceMotion(reduceMotion) }
        }
        if let environment {
            let mutations = environmentBindings.mutations(reference: environment,
                reduceMotion: reduceMotion, safeArea: safeArea, viewport: viewport, fold: fold, colorScheme: colorScheme)
            if !mutations.isEmpty { _ = try await runtime.mutateViewModel(mutations) }
        }
        if let colorScheme, environmentBindings.themeSelection(for: colorScheme) != nil {
            _ = try await runtime.bindGlobalViewModel(named: ExperienceEnvironmentBindings.themeGlobalName,
                authoredInstanceNamed: colorScheme.label)
        }
    }

    func setLayoutSize(width: Float, height: Float) async throws {
        try await gate.withLock { [self] in
            _ = try await presentationHeight.apply(to: runtime, fitContent: false, width: width, height: height)
            try await updateEnvironmentLocked(reduceMotion: nil, safeArea: nil,
                viewport: ExperienceViewportEnvironment(width: Double(width), height: Double(height)),
                fold: nil, colorScheme: nil)
        }
    }

    func close() async throws {
        try await gate.withLock { [self] in try await closeLocked() }
    }

    private func closeLocked() async throws {
        guard !closed else { return }
        closed = true
        for row in rows.values { for waiter in row.waiters.values { waiter.continuation.finish() } }
        await videoPlayback?.close()
        rows.removeAll()
        mountedScreenIDs.removeAll()
        try await runtime.close()
    }

    private func requireOpen() throws {
        if closed { throw ExperienceInteractiveScreenError.stateContract("Layer is closed") }
    }
}

#endif
