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
    // Together steps take before registering waiters; only rows already present need positioning.
    private var incomingRowToPosition: String?
    var mountedScreenIDs: [String] { rowList.screenIDs }
    private var closed = false
    private var activeScreenID: String?
    private(set) var videoPlayback: ExperienceVideoPlayback?
    private nonisolated let layoutBounds = ExperienceLayoutBounds(.zero)
    nonisolated var artboardBounds: CGRect { layoutBounds.read() }
    private var liveStep: (artboard: String, name: String?)?
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
              let machine = artboard.stateMachines.first(where: { contract == .published ? $0 == ExperiencePageHostContract.machineName : true }) else {
            throw ExperienceInteractiveScreenError.stateContract("Page host requires a root state machine")
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
                  catalog.schemas.contains(where: { $0.index == rootSchema && (contract != .published || $0.name == ExperiencePageHostContract.modelName) }),
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
            let reference = try await runtime.makeViewModel(schemaIndex: schema)
            do {
                let binding = try await ExperienceInteractiveScreen.openPrepared(payload: payload,
                    preparedFile: preparedFile, runValues: runValues, imageIDsByName: imageIDsByName,
                    screenID: screenID, products: products, player: .defaultScene,
                    pixelWidth: 1, pixelHeight: 1, initialReduceMotion: nil, initialFontScale: nil, initialSafeArea: nil,
                    initialColorScheme: nil, rowRuntime: runtime, rowReference: reference, operationGate: gate,
                    rowVideoPlayback: videoPlayback, rowScreen: resolvedScreen)
                await binding.setRowStepper { [weak self] pointers, focus, elapsed, correlation, capturesText in
                    guard let self else { throw CancellationError() }
                    let step = try await self.step(pointers: pointers, focusInputs: focus,
                        elapsedSeconds: elapsed, correlationID: correlation, capturesTextLayout: capturesText)
                    // A retained row can finish a save after leaving the mounted list.
                    var result = step.rows[screenID] ?? ExperienceInteractiveStepResult(
                        keepGoing: step.native.keepGoing || step.rows.values.contains { $0.keepGoing },
                        pointerHits: step.rows.values.first?.pointerHits ?? [],
                        focusState: step.native.focusState, effects: [])
                    result.pageStep = step
                    return result
                }
                rows[screenID] = Row(screen: resolvedScreen, reference: reference, binding: binding,
                    products: products, lifecycle: .init(reduceMotion: currentReduceMotion))
            } catch {
                try? await runtime.releaseViewModels([reference])
                throw error
            }
        }
        if activeScreenID == nil { activeScreenID = screenID }
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

    func activeBinding() throws -> ExperienceInteractiveScreen {
        guard let activeScreenID else { throw ExperienceInteractiveScreenError.stateContract("Page has no active row") }
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

    static let fitContentDiagnostic = "ExperienceInteractivePage: compiler content height is unavailable; fit-content defaults to large"

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

    func apply(_ changes: [ExperiencePageStep.Change], source: String, target: String,
               reachable: Set<String>, reduceMotion: Bool) async throws {
        try await gate.withLock { [self] in
            try await applyLocked(changes, source: source, target: target, reachable: reachable, reduceMotion: reduceMotion)
        }
    }

    private func applyLocked(_ changes: [ExperiencePageStep.Change], source: String, target: String,
                             reachable: Set<String>, reduceMotion: Bool) async throws {
        guard let mapped = payload.renderPlan.screens.first(where: { $0.screenId == target }) else {
            throw ExperienceInteractiveScreenError.screenNotFound(target)
        }
        for change in changes {
            switch change {
            case .take:
                incomingRowToPosition = mountedScreenIDs.contains(target) ? target : nil
                try await insertLocked(screenID: target, at: mountedScreenIDs.count, products: rows[target]?.products ?? [])
            case .position(let isBack):
                guard incomingRowToPosition == target else { continue }
                incomingRowToPosition = nil
                var next = rowList
                if let mutation = next.position(target, relativeTo: source, isBack: isBack) {
                    try await applyRowMutation(mutation)
                    rowList = next
                }
            case .phases(let phases, let transition):
                try await setPhasesLocked(phases, transition: transition, reduceMotion: reduceMotion, exitReason: .navigation)
                if phases.contains(where: { $0.1 == .active }) { await videoPlayback?.setStepInProgress(false) }
            case .begin(let name):
                // Interim test scenes have no LiveStep records. Live moves require the published root.
                if contract == .published { try await runtime.stepBegin(incomingScreen: mapped.artboardName, stepName: name) }
                liveStep = (mapped.artboardName, name)
            case .end(let name):
                if contract == .published { try await runtime.stepEnd(incomingScreen: mapped.artboardName, stepName: name) }
                liveStep = nil
            case .retire:
                var next = rowList
                for mutation in next.retire(active: target, reachable: reachable) { try await applyRowMutation(mutation) }
                rowList = next
            }
        }
    }

    func restoreCancelledStep(source: String, target: String, reachable: Set<String>, reduceMotion: Bool) async throws {
        try await gate.withLock { [self] in
            try await restoreCancelledStepLocked(source: source, target: target, reachable: reachable, reduceMotion: reduceMotion)
        }
    }

    private func restoreCancelledStepLocked(source: String, target: String, reachable: Set<String>, reduceMotion: Bool) async throws {
        if let liveStep {
            if contract == .published { try await runtime.stepEnd(incomingScreen: liveStep.artboard, stepName: liveStep.name) }
            self.liveStep = nil
        }
        // Bring borrowed instances home before any rollback removes their destination.
        try await applyLocked([.take, .begin(nil), .end(nil), .retire,
            .phases([(target, .hidden), (source, .active)], "")], source: target, target: source,
            reachable: reachable, reduceMotion: reduceMotion)
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
        case .collapse(_, let index, let collapsed):
            try await runtime.setRowCollapsed(list: contract.listPath, index: index, collapsed: collapsed)
        case .remove(_, let index):
            _ = try await runtime.mutateViewModel([.listRemove(instance: root, path: contract.listPath, index: index)])
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
            throw ExperienceInteractiveScreenError.stateContract("Page step requires an event-source snapshot")
        }
        var graphs: [String: NuxieNativeViewModelSnapshot] = [:]
        for id in rows.keys.sorted() {
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
        for id in rows.keys.sorted() {
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
                events: events, hostCommands: ExperiencePageHostContract.hostCommands(frame.result.hostCommands, row: id, active: activeScreenID),
                viewModelChanges: frame.result.viewModelChanges.filter { ids.contains($0.ownerInstanceID) },
                textGeometry: frame.result.textGeometry, focusResults: frame.result.focusResults,
                focusState: frame.result.focusState)
            projected[id] = try await row.binding.projectRowStep(result, snapshot: graph, correlationID: correlationID, capturesTextLayout: capturesTextLayout)
        }
        return Step(native: frame.result, rows: projected,
            unattributedEvents: frame.result.events.enumerated().compactMap { index, event in
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
            for id in rows.keys { _ = rows[id]?.lifecycle.updateReduceMotion(reduceMotion) }
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
            try await runtime.setLayoutSize(width: width, height: height)
            try await updateEnvironmentLocked(reduceMotion: nil, fontScale: nil, safeArea: nil,
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
        rowList = ExperiencePageRows()
        try await runtime.close()
    }

    private func requireOpen() throws {
        if closed { throw ExperienceInteractiveScreenError.stateContract("Page is closed") }
    }
}

#endif
