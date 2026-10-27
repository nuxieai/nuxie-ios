#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import NuxieRuntime

/// One native page's clock and list. Screen bindings and routing remain
/// on ExperienceInteractiveScreen, rooted at each retained row instance.
actor ExperienceInteractivePage {
    struct Step: Equatable, Sendable {
        let native: NuxieNativePlayerStepResult
        let rows: [String: ExperienceInteractiveStepResult]
        let unattributedEvents: [NuxieNativeEvent]
        var mountedScreenIDs: [String] = []
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
        var removedSnapshot: NuxieNativeViewModelSnapshot? = nil
    }

    let runtime: NuxieNativeRuntime
    private let contract: NativeExperiencePageHost
    private let payload: AuthenticatedRuntimePayload
    private let preparedFile: NuxieNativePreparedFile
    private let runValues: ExperienceRunValues?
    private let imageIDsByName: [String: UInt64]
    private let root: NuxieNativeViewModelReference
    private let gate = ExperienceInteractiveOperationGate()
    private let environment: NuxieNativeViewModelReference?
    private let environmentBindings: ExperienceEnvironmentBindings
    private var rows: [String: Row] = [:]
    private var rowList = ExperiencePageRows()
    var retainedScreenIDs: Set<String> { Set(rows.keys) }
    var mountedScreenIDs: [String] { rowList.screenIDs }
    private var closed = false
    private var retirementTask: Task<Void, Error>?
    private(set) var activeScreenID: String?
    // Opt-in probe of committed lifecycle writes, including standalone handshakes.
    struct LifecycleWrite: Equatable, Sendable {
        let screenID: String
        let phase: ExperienceScreenLifecyclePhase
    }
    private(set) var lifecycleWriteLog: [LifecycleWrite]?
    func recordLifecycleWrites() { lifecycleWriteLog = [] }
    private var activeRowReference: NuxieNativeViewModelReference?
    private(set) var videoPlayback: ExperienceVideoPlayback?
    private nonisolated let layoutBounds = ExperienceLayoutBounds(.zero)
    nonisolated var artboardBounds: CGRect { layoutBounds.read() }
    var collapsedScreenIDs: Set<String> { rowList.collapsed }
    private var currentReduceMotion: Bool

    private init(runtime: NuxieNativeRuntime, contract: NativeExperiencePageHost,
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
                     reduceMotion: Bool, fontScale: Double? = nil, safeArea: ExperienceSafeAreaInsets?,
                     colorScheme: ExperienceColorScheme?, videoDecoderPool: ExperienceVideoDecoderPool? = nil) async throws -> ExperienceInteractivePage {
        let contract = payload.renderPlan.pageHost ?? .published
        guard let artboard = try await preparedFile.artboards().first(where: { $0.name == contract.artboardName }),
              let machine = artboard.stateMachines.first(where: { contract.machineName == nil || $0 == contract.machineName }) else {
            throw ExperienceInteractiveScreenError.stateContract("Page host requires a root state machine")
        }
        let shared = try await runValues?.native(in: preparedFile)
        let runtime: NuxieNativeRuntime
        if let shared {
            runtime = try await shared.sessions.openSession(artboardName: contract.artboardName,
                player: .stateMachine(machine), pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                bindDefaultViewModel: true, clearingDefaultList: contract.initialRows == .clearBeforePlayer ? contract.listPath : nil)
        } else {
            runtime = try await preparedFile.openSession(artboardName: contract.artboardName,
                player: .stateMachine(machine), pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                bindDefaultViewModel: true, clearingDefaultList: contract.initialRows == .clearBeforePlayer ? contract.listPath : nil)
        }
        do {
            let root = try await runtime.rootViewModelReference()
            let catalog = try await runtime.viewModelCatalog()
            let snapshot = try await runtime.snapshot()
            guard let rootSchema = snapshot.instances.first(where: { $0.id == root.rawValue })?.schemaIndex,
                  catalog.schemas.contains(where: { $0.index == rootSchema && (contract.modelName == nil || $0.name == contract.modelName) }),
                  catalog.properties.contains(where: {
                      $0.schemaIndex == rootSchema && $0.name == contract.listPath && $0.kind == .list
                  }) else {
                throw ExperienceInteractiveScreenError.stateContract("Page host requires its Screen list")
            }
            guard snapshot.values.contains(where: {
                $0.ownerInstanceID == root.rawValue && $0.name == contract.listPath && $0.value == .list([])
            }) else {
                throw ExperienceInteractiveScreenError.stateContract("Page host requires an empty initial Screen list")
            }
            let environment = try await runtime.bindGlobalViewModel(named: "env", sharingAcrossSessions: false)
            let page = ExperienceInteractivePage(runtime: runtime, contract: contract,
                payload: payload, preparedFile: preparedFile, runValues: runValues,
                imageIDsByName: imageIDsByName, root: root, environment: environment, catalog: catalog, reduceMotion: reduceMotion)
            try await page.updateEnvironment(reduceMotion: reduceMotion, fontScale: fontScale, safeArea: safeArea, colorScheme: colorScheme)
            try await page.setLayoutSize(width: Float(pixelWidth), height: Float(pixelHeight))
            if !payload.renderPlan.videos.isEmpty {
                let playback = try await ExperienceVideoPlayback.open(runtime: runtime, payload: payload,
                    artboardBounds: CGRect(x: 0, y: 0, width: Int(pixelWidth), height: Int(pixelHeight)),
                    decoderPool: videoDecoderPool)
                await page.setVideoPlayback(playback)
            }
            return page
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
        mountedScreenIDs.count
    }

    func insert(screenID: String, at index: Int, products: [StoreProduct] = []) async throws {
        try await gate.withLock { [self] in try await insertLocked(screenID: screenID, at: index, products: products) }
    }

    private func insertLocked(screenID: String, at index: Int, products: [StoreProduct]) async throws {
        try requireOpen()
        guard mountedScreenIDs.contains(screenID) || index == mountedScreenIDs.count else {
            throw ExperienceInteractiveScreenError.stateContract("New page rows must append")
        }
        try await prepareRowLocked(screenID: screenID, products: products)
        var next = rowList
        try await applyRowMutation(next.take(screenID))
        rowList = next
    }

    func prepareRow(screenID: String, products: [StoreProduct]) async throws -> ExperienceInteractiveScreen {
        try await gate.withLock { [self] in
            try await prepareRowLocked(screenID: screenID, products: products)
            return try await binding(screenID: screenID)
        }
    }

    func isRowRemoved(screenID: String) -> Bool { rows[screenID]?.removedSnapshot != nil }

    func products(screenID: String) throws -> [StoreProduct] {
        try requireOpen()
        guard let row = rows[screenID] else {
            throw ExperienceInteractiveScreenError.screenNotFound(screenID)
        }
        return row.products
    }

    private func prepareRowLocked(screenID: String, products: [StoreProduct]) async throws {
        try requireOpen()
        if rows[screenID] == nil || rows[screenID]?.removedSnapshot != nil {
            let previous = rows[screenID]
            let retained = previous?.removedSnapshot
            guard let screen = payload.journey.screens.first(where: { $0.id == screenID }) else {
                throw ExperienceInteractiveScreenError.journeyScreenNotFound(screenID)
            }
            guard let mapped = payload.renderPlan.screens.first(where: { $0.screenId == screenID }) else {
                throw ExperienceInteractiveScreenError.screenNotFound(screenID)
            }
            let schema = try await runtime.defaultSchema(artboardName: mapped.artboardName)
            let catalog = try await runtime.viewModelCatalog()
            guard let schemaName = catalog.schemas.first(where: { $0.index == schema })?.name else {
                throw ExperienceInteractiveScreenError.stateContract("Mapped Screen artboard has no root schema")
            }
            let resolvedScreen = JourneyScreen(id: screenID, defaultViewModelName: schemaName,
                defaultInstanceId: screen.defaultInstanceId)
            var identities: [ExperienceInteractiveViewModelIdentity: UInt64] = [:]
            if retained != nil, let previous { identities = await previous.binding.identitySnapshotIDs() }
            let reference = try await runtime.makeViewModel(schemaIndex: schema)
            do {
                let binding = try await ExperienceInteractiveScreen.openPrepared(payload: payload,
                    preparedFile: preparedFile, runValues: runValues, imageIDsByName: imageIDsByName,
                    screenID: screenID, products: previous?.products ?? products, player: .defaultScene,
                    pixelWidth: 1, pixelHeight: 1, initialReduceMotion: nil, initialFontScale: nil, initialSafeArea: nil,
                    initialColorScheme: nil, rowRuntime: runtime, rowReference: reference, operationGate: gate,
                    rowVideoPlayback: videoPlayback, rowScreen: resolvedScreen, retainedRowSnapshot: retained,
                    retainedIdentities: identities)
                await binding.setRowStepper { [weak self] pointers, focus, elapsed, correlation, capturesText in
                    guard let self else { throw CancellationError() }
                    let step = try await self.stepFromRow(screenID: screenID, reference: reference,
                        pointers: pointers, focusInputs: focus, elapsedSeconds: elapsed,
                        correlationID: correlation, capturesTextLayout: capturesText)
                    // A retained row can finish a save after leaving the mounted list.
                    var result = step.rows[screenID] ?? ExperienceInteractiveStepResult(
                        keepGoing: step.native.keepGoing || step.rows.values.contains { $0.keepGoing },
                        pointerHits: step.rows.values.first?.pointerHits ?? [],
                        focusState: step.native.focusState, effects: [])
                    result.pageStep = step
                    return result
                }
                if let previous, let retained = previous.removedSnapshot {
                    await previous.binding.closePageRow()
                    await runtime.endRemovedRowGeneration(retained)
                }
                rows[screenID] = Row(screen: resolvedScreen, reference: reference, binding: binding,
                    products: previous?.products ?? products, lifecycle: previous?.lifecycle ?? .init(reduceMotion: currentReduceMotion))
            } catch {
                try? await runtime.releaseViewModels([reference])
                throw error
            }
        }
        if activeScreenID == nil {
            activeScreenID = screenID
            activeRowReference = rows[screenID]?.reference
        }
    }

    func screen(screenID: String) throws -> JourneyScreen {
        guard let screen = rows[screenID]?.screen else { throw ExperienceInteractiveScreenError.screenNotFound(screenID) }
        return screen
    }

    func binding(screenID: String) throws -> ExperienceInteractiveScreen {
        try requireOpen()
        guard let binding = rows[screenID]?.binding else {
            throw ExperienceInteractiveScreenError.screenNotFound(screenID)
        }
        return binding
    }

    func selectActiveRow(_ screenID: String) throws {
        guard let row = rows[screenID], row.removedSnapshot == nil else {
            throw CancellationError()
        }
        activeScreenID = screenID
        activeRowReference = rows[screenID]?.reference
    }

    var deliveredVideoFrames: UInt64 { get async { await videoPlayback?.deliveredFrames ?? 0 } }

    func environmentSnapshot() async throws -> NuxieNativeViewModelSnapshot? {
        guard let environment else { return nil }
        return try await gate.withLock { [self] in try await runtime.snapshot(environment) }
    }

    private func setVideoPlayback(_ playback: ExperienceVideoPlayback) { videoPlayback = playback }

    func configurePresentationHeight(fitContent: Bool, size: CGSize,
                                     diagnostic: (@Sendable (String) async -> Void)? = nil) async throws {
        if fitContent {
            if let diagnostic { await diagnostic(Self.fitContentDiagnostic) }
            else { LogWarning("\(Self.fitContentDiagnostic)") }
        }
        if size.width > 0, size.height > 0 {
            try await setLayoutSize(width: Float(size.width), height: Float(size.height))
        }
    }

    static let fitContentDiagnostic = "ExperienceInteractivePage: page content height is unavailable; fit-content defaults to large"

    func remove(screenID: String) async throws {
        try await gate.withLock { [self] in try await removeLocked(screenID: screenID) }
    }

    private func removeLocked(screenID: String) async throws {
        try requireOpen()
        var next = rowList
        guard let mutation = next.remove(screenID) else {
            throw ExperienceInteractiveScreenError.stateContract("Screen is absent from the page")
        }
        try await applyRowMutation(mutation)
        rowList = next
    }

    /// The frame queue calls this once, so no advance can split a lifecycle batch.
    func beginPresentationStep() async {
        await videoPlayback?.setStepInProgress(true)
    }

    @discardableResult
    func apply(_ changes: [ExperiencePageStep.Change], source: String, target: String,
               reachable: Set<String>, reduceMotion: Bool) async throws -> Step? {
        try await gate.withLock { [self] in
            try await applyLocked(changes, source: source, target: target, reachable: reachable, reduceMotion: reduceMotion)
        }
    }

    private func applyLocked(_ changes: [ExperiencePageStep.Change], source: String, target: String,
                             reachable: Set<String>, reduceMotion: Bool) async throws -> Step? {
        guard let mapped = payload.renderPlan.screens.first(where: { $0.screenId == target }) else {
            throw ExperienceInteractiveScreenError.screenNotFound(target)
        }
        var settled: Step?
        for change in changes {
            switch change {
            case .take:
                try await prepareRowLocked(screenID: target, products: rows[target]?.products ?? [])
            case .position(let isBack):
                var next = rowList
                if !next.screenIDs.contains(target) {
                    try await applyRowMutation(next.take(target))
                    rowList = next
                    if !isBack { continue }
                }
                if let mutation = next.position(target, relativeTo: source, isBack: isBack) {
                    try await applyRowMutation(mutation)
                    rowList = next
                }
            case .expand:
                guard rowList.screenIDs.contains(target) else {
                    throw ExperienceInteractiveScreenError.stateContract("Incoming page row must be inserted before expansion")
                }
                var next = rowList
                try await applyRowMutation(next.take(target))
                rowList = next
            case .settle:
                settled = try await stepLocked(pointers: [], elapsedSeconds: 0, correlationID: 0)
            case .phases(let phases, let transition):
                try await setPhasesLocked(phases, transition: transition, reduceMotion: reduceMotion, exitReason: .navigation)
                if phases.contains(where: { $0.1 == .active }) { await videoPlayback?.setStepInProgress(false) }
            case .begin(let name):
                // Only contracts with native live-move records can begin a step.
                if contract.hasLiveMoves { try await runtime.stepBegin(incomingScreen: mapped.artboardName, stepName: name.map { contract.stepNames[$0] ?? $0 }) }
            case .end(let name):
                if contract.hasLiveMoves { try await runtime.stepEnd(incomingScreen: mapped.artboardName, stepName: name.map { contract.stepNames[$0] ?? $0 }) }
            case .retire:
                var next = rowList
                for mutation in next.retire(active: target, reachable: reachable) { try await applyRowMutation(mutation) }
                rowList = next
            }
        }
        return settled
    }

    private func applyRowMutation(_ mutation: ExperiencePageRows.Mutation) async throws {
        switch mutation {
        case .append(let id, let index):
            guard let row = rows[id] else { throw ExperienceInteractiveScreenError.screenNotFound(id) }
            _ = try await runtime.mutateViewModel([.listInsert(instance: root, path: contract.listPath,
                index: index, value: row.reference)])
        case .move(_, let from, let to):
            _ = try await runtime.mutateViewModel([.listMove(instance: root, path: contract.listPath,
                from: from, to: to)])
        case .collapse(let id, let index, let collapsed):
            guard let row = rows[id], row.removedSnapshot == nil else {
                assertionFailure("R6b: collapse of a removed row")
                throw ExperienceInteractiveScreenError.screenNotFound(id)
            }
            try await runtime.setRowCollapsed(list: contract.listPath, index: index, collapsed: collapsed, rowReference: row.reference)
        case .remove(let id, let index):
            guard let row = rows[id], row.removedSnapshot == nil else {
                assertionFailure("R6b: removing an already removed row")
                throw ExperienceInteractiveScreenError.screenNotFound(id)
            }
            guard row.waiters.isEmpty else {
                throw ExperienceInteractiveScreenError.stateContract("Screen still awaits completion")
            }
            let retained = try await runtime.snapshot(row.reference)
            _ = try await runtime.mutateViewModel([.listRemove(instance: root, path: contract.listPath, index: index)])
            rows[id]?.removedSnapshot = retained
            await row.binding.markRowRemoved(retained)
            await runtime.freezeRemovedRow(retained)
            let children = await row.binding.takeOwnedRowHandles()
            try await runtime.releaseViewModels(children + [row.reference])
        }
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
        let transition = contract.stepNames[transition] ?? transition
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
            assert(row.removedSnapshot == nil, "R6b: phase write after removal")
            guard row.removedSnapshot == nil else { throw ExperienceInteractiveScreenError.screenNotFound(id) }
            let snapshot = row.lifecycle.move(to: phase, transition: transition,
                reduceMotion: reduceMotion ?? currentReduceMotion, exitReason: exitReason)
            mutations += try await row.binding.lifecycleMutations(snapshot, screen: row.screen)
            updated[id] = row.lifecycle
        }
        _ = try await runtime.mutateViewModel(mutations)
        for (id, lifecycle) in updated { rows[id]?.lifecycle = lifecycle }
        lifecycleWriteLog?.append(contentsOf: phases.map { .init(screenID: $0.0, phase: $0.1) })
    }

    func applyLifecycleSnapshot(_ snapshot: ExperienceScreenLifecycleSnapshot, screenID: String) async throws {
        try await gate.withLock { [self] in
            guard let row = await rows[screenID] else { throw ExperienceInteractiveScreenError.screenNotFound(screenID) }
            guard row.removedSnapshot == nil else { return }
            let mutations = try await row.binding.lifecycleMutations(snapshot, screen: row.screen)
            _ = try await runtime.mutateViewModel(mutations)
            await storeLifecycle(snapshot, screenID: screenID)
            if snapshot.phase == .active { await videoPlayback?.setStepInProgress(false) }
        }
    }

    private func storeLifecycle(_ snapshot: ExperienceScreenLifecycleSnapshot, screenID: String) {
        rows[screenID]?.lifecycle = .init(snapshot: snapshot)
        lifecycleWriteLog?.append(.init(screenID: screenID, phase: snapshot.phase))
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
        if eventName.isEmpty {
            pair.continuation.yield(())
            pair.continuation.finish()
            return Completion(id: id, events: pair.stream)
        }
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

    private func acceptsRowInput(screenID: String, reference: NuxieNativeViewModelReference) -> Bool {
        rows[screenID]?.reference == reference && !isRowRemoved(screenID: screenID)
    }

    private func stepFromRow(screenID: String, reference: NuxieNativeViewModelReference,
                             pointers: [NuxieNativePointerEvent], focusInputs: [NuxieNativeFocusInput],
                             elapsedSeconds: Float, correlationID: UInt64, capturesTextLayout: Bool) async throws -> Step {
        try await gate.withLock { [self] in
            let acceptsInput = await acceptsRowInput(screenID: screenID, reference: reference)
            return try await stepLocked(pointers: acceptsInput ? pointers : [], focusInputs: acceptsInput ? focusInputs : [],
                elapsedSeconds: elapsedSeconds, correlationID: correlationID, capturesTextLayout: capturesTextLayout)
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
            throw ExperienceInteractiveScreenError.stateContract("Page step requires an event-source snapshot")
        }
        return try await projectCapturedStep(frame.result, snapshot: snapshot, correlationID: correlationID,
            capturesTextLayout: capturesTextLayout, videoActive: videoActive)
    }

    /// Projects a committed journal using the current live or removed row for each Screen.
    func projectCapturedStep(_ result: NuxieNativePlayerStepResult, snapshot: NuxieNativeViewModelSnapshot,
                             correlationID: UInt64 = 0, capturesTextLayout: Bool = false,
                             videoActive: Bool = false) async throws -> Step {
        let currentRows = rows.keys.sorted().compactMap { id in rows[id].map { (id, $0) } }
        var graphs: [UInt64: NuxieNativeViewModelSnapshot] = [:]
        for (_, row) in currentRows {
            let identity = row.reference.rawValue
            if let retained = row.removedSnapshot { graphs[identity] = retained }
            else if let graph = snapshot.rooted(at: identity) { graphs[identity] = graph }
            else { graphs[identity] = try await runtime.snapshot(row.reference) }
        }
        let activeIdentity = activeRowReference?.rawValue
        let eventOwners: [UInt64?] = result.events.map { event in
            guard let source = event.sourceViewModelInstanceID else { return nil }
            let matches = graphs.filter { $0.value.instances.contains(where: { $0.id == source }) }
            if matches.count == 1 { return matches.first?.key }
            // An instance several rows link, such as an item of a shared Experience
            // list, belongs to the Screen on top when it is one of them (F1).
            if let activeIdentity, matches[activeIdentity] != nil { return activeIdentity }
            return nil
        }
        var projected: [String: ExperienceInteractiveStepResult] = [:]
        for (id, row) in currentRows {
            let identity = row.reference.rawValue
            guard let graph = graphs[identity] else { continue }
            let ids = Set(graph.instances.map(\.id))
            let events: [NuxieNativeEvent] = result.events.enumerated().compactMap { index, event in
                eventOwners[index] == identity ? event : nil
            }
            for event in events {
                for (token, waiter) in row.waiters where waiter.name == event.name {
                    waiter.continuation.yield(())
                    waiter.continuation.finish()
                    rows[id]?.waiters.removeValue(forKey: token)
                }
            }
            let rowResult = NuxieNativePlayerStepResult(keepGoing: result.keepGoing || videoActive,
                pointerHits: result.pointerHits, stateChanges: result.stateChanges,
                events: events, hostCommands: activeRowReference == row.reference
                    ? ExperiencePageHostContract.hostCommands(result.hostCommands, row: id, active: activeScreenID) : [],
                viewModelChanges: result.viewModelChanges.filter { ids.contains($0.ownerInstanceID) },
                textGeometry: result.textGeometry, focusResults: result.focusResults,
                focusState: result.focusState)
            let next = try await row.binding.projectRowStep(rowResult, snapshot: graph, correlationID: correlationID, capturesTextLayout: capturesTextLayout)
            projected[id] = next
        }
        return Step(native: result, rows: projected,
            unattributedEvents: result.events.enumerated().compactMap { index, event in
                eventOwners[index] == nil ? event : nil
            }, mountedScreenIDs: mountedScreenIDs)
    }

    func updateEnvironment(reduceMotion: Bool? = nil, fontScale: Double? = nil, safeArea: ExperienceSafeAreaInsets? = nil,
                           viewport: ExperienceViewportEnvironment? = nil, fold: ExperienceFoldEnvironment? = nil,
                           colorScheme: ExperienceColorScheme? = nil) async throws {
        try await gate.withLock { [self] in
            try await updateEnvironmentLocked(reduceMotion: reduceMotion, fontScale: fontScale, safeArea: safeArea,
                viewport: viewport, fold: fold, colorScheme: colorScheme)
        }
    }

    private func updateEnvironmentLocked(reduceMotion: Bool?, fontScale: Double?, safeArea: ExperienceSafeAreaInsets?,
                                         viewport: ExperienceViewportEnvironment?, fold: ExperienceFoldEnvironment?,
                                         colorScheme: ExperienceColorScheme?) async throws {
        try requireOpen()
        if let reduceMotion {
            currentReduceMotion = reduceMotion
            for id in rows.keys where rows[id]?.removedSnapshot == nil { _ = rows[id]?.lifecycle.updateReduceMotion(reduceMotion) }
        }
        if let environment {
            let mutations = environmentBindings.mutations(reference: environment,
                reduceMotion: reduceMotion, fontScale: fontScale, safeArea: safeArea, viewport: viewport, fold: fold, colorScheme: colorScheme)
            if !mutations.isEmpty { _ = try await runtime.mutateViewModel(mutations) }
        }
        if let colorScheme, environmentBindings.themeSelection(for: colorScheme) != nil {
            _ = try await runtime.bindGlobalViewModel(named: ExperienceEnvironmentBindings.themeGlobalName,
                authoredInstanceNamed: colorScheme.label)
        }
    }

    func setLayoutSize(width: Float, height: Float) async throws {
        try await gate.withLock { [self] in
            try await setLayoutSizeLocked(width: width, height: height)
        }
    }

    private func setLayoutSizeLocked(width: Float, height: Float) async throws {
        try requireOpen()
        try await runtime.setLayoutSize(width: width, height: height)
        layoutBounds.update(size: try await runtime.layoutSize())
        try await updateEnvironmentLocked(reduceMotion: nil, fontScale: nil, safeArea: nil,
            viewport: .init(width: Double(width), height: Double(height)), fold: nil, colorScheme: nil)
        try await videoPlayback?.resizeViewport(bounds: artboardBounds)
    }

    // Renderer, media and geometry belong to the page, including the interval
    // after the outgoing row retires and before the incoming row becomes active.
    func metalDevice(enablesSemantics: Bool) async throws -> ExperienceInteractiveMetalDevice {
        try await gate.withLock { [self] in
            try await requireOpen()
            if enablesSemantics { try await runtime.enableSemantics() }
            return ExperienceInteractiveMetalDevice(value: try await runtime.metalDevice().value)
        }
    }

    func setMediaVisible(_ visible: Bool) async throws {
        try await gate.withLock { [self] in
            try await requireOpen()
            try await videoPlayback?.setSuspended(reason: 1, enabled: !visible)
        }
    }

    func resize(pixelWidth: UInt32, pixelHeight: UInt32, layoutScaleFactor: Float) async throws
        -> ExperienceInteractiveRenderOutcome {
        try await gate.withLock { [self] in
            try await resizeLocked(pixelWidth: pixelWidth, pixelHeight: pixelHeight, layoutScaleFactor: layoutScaleFactor)
        }
    }

    private func resizeLocked(pixelWidth: UInt32, pixelHeight: UInt32, layoutScaleFactor: Float) async throws
        -> ExperienceInteractiveRenderOutcome {
        try requireOpen()
        for row in rows.values { await row.binding.discardTextFrame() }
        if pixelWidth > 0, pixelHeight > 0, layoutScaleFactor > 0 {
            let width = Float(pixelWidth) / layoutScaleFactor
            let height = Float(pixelHeight) / layoutScaleFactor
            try await setLayoutSizeLocked(width: width, height: height)
        } else {
            try await updateEnvironmentLocked(reduceMotion: nil, fontScale: nil, safeArea: nil,
                viewport: .init(width: 0, height: 0), fold: nil, colorScheme: nil)
            try await videoPlayback?.resizeViewport(bounds: .zero)
        }
        return ExperienceInteractiveScreen.renderOutcome(try await runtime.resize(pixelWidth: pixelWidth, pixelHeight: pixelHeight))
    }

    func renderFrame(layoutScaleFactor: Float, drawable: ExperienceInteractiveDrawable?, isOccluded: Bool,
                     capturesSemantics: Bool, capturesCaptions: Bool,
                     completion: (@Sendable () -> Void)?) async throws -> ExperienceInteractiveRenderedFrame {
        let state: NuxieNativeDrawableState = if let drawable {
            .available(NuxieNativeDrawable(drawable.value))
        } else { isOccluded ? .occluded : .timeout }
        return try await gate.withLock { [self] in
            try await renderFrameLocked(layoutScaleFactor: layoutScaleFactor, state: state, isOccluded: isOccluded,
                capturesSemantics: capturesSemantics, capturesCaptions: capturesCaptions, completion: completion)
        }
    }

    private func renderFrameLocked(layoutScaleFactor: Float, state: NuxieNativeDrawableState, isOccluded: Bool,
                                   capturesSemantics: Bool, capturesCaptions: Bool,
                                   completion: (@Sendable () -> Void)?) async throws -> ExperienceInteractiveRenderedFrame {
        try requireOpen()
        // No outgoing editor metadata is admitted after its row retires.
        let row = activeScreenID.flatMap { rows[$0] }
        let content = if let row, row.removedSnapshot == nil {
            await row.binding.pagePresentationContent()
        } else { (text: Optional<ExperienceInteractiveTextFrame>.none, nativeInputs: [String]()) }
        try await videoPlayback?.setSuspended(reason: 1, enabled: isOccluded)
        let ready = try await videoPlayback?.isReadyForPresentation() ?? true
        let frame = try await runtime.renderFrame(layoutScaleFactor: layoutScaleFactor,
            drawable: ready ? state : .timeout, clearColor: 0, readback: nil,
            capturesSemantics: capturesSemantics, nativeInputs: content.nativeInputs, completion: completion)
        let captions: [ExperienceInteractiveVideoCaption]?
        if capturesCaptions, frame.outcome.disposition == .presented {
            captions = try await videoPlayback?.captions() ?? []
        } else { captions = nil }
        return ExperienceInteractiveRenderedFrame(outcome: ExperienceInteractiveScreen.renderOutcome(frame.outcome),
            semantics: frame.semantics, text: frame.outcome.disposition == .presented ? content.text : nil, captions: captions)
    }

    func close() async throws {
        let task: Task<Void, Error>
        if let retirementTask { task = retirementTask }
        else {
            task = Task {
                defer { self.retirementTask = nil }
                try await self.gate.withLock { [self] in try await closeLocked() }
            }
            retirementTask = task
        }
        // Closing the page is native work alone.
        try await ExperienceRuntimeRetirement.wait(authoredTime: nil) { try await task.value }
    }

    private func closeLocked() async throws {
        guard !closed else { return }
        closed = true
        for row in rows.values {
            for waiter in row.waiters.values { waiter.continuation.finish() }
            // The page already holds the shared operation gate. Row cleanup
            // closes its font scope without reacquiring that gate.
            await row.binding.closePageRow()
        }
        await videoPlayback?.close()
        rows.removeAll()
        rowList = ExperiencePageRows()
        try await runtime.close()
    }

    private func requireOpen() throws {
        if closed { throw ExperienceInteractiveScreenError.stateContract("Page is closed") }
    }
}

#endif
