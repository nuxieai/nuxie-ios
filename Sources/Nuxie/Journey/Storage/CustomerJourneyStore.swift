import Foundation

/// Customer-scoped commands over the event database. No execution state lives in files.
struct CustomerJourneyStore: Sendable {
    let owner: CustomerStoreOwner
    let store: any CustomerStore
    let epoch: Int64
    let events: (any RoutedStableSystemEventCapturing)?
    private let pins: JourneyReleasePinStore
    private let files: CustomerPinFileOwner
    private let beforePersist: (@Sendable () throws -> Void)?
    var distinctId: String { owner.userId }
    var responseSaveNamespace: String { owner.authorityScope }

    init(directory: URL, distinctId: String, storageScope: JourneyStorageScope = .testFixture,
         openedAt: Date = Date(), openExecution: Bool = true,
         releasePinBudgetBytes: Int = JourneyReleasePinStore.defaultBudgetBytes,
         releasePinCountLimit: Int = JourneyReleasePinStore.defaultCountLimit,
         beforePersist: (@Sendable () throws -> Void)? = nil,
         events: (any RoutedStableSystemEventCapturing)? = nil,
         store suppliedStore: (any CustomerStore)? = nil) async throws {
        owner = .init(scope: storageScope, userId: distinctId)
        self.events = events
        self.beforePersist = beforePersist
        let root = directory.appendingPathComponent("journey-journal-v2", isDirectory: true)
        files = .init(journalRoot: root)
        pins = .init(journalRoot: root, customerDigest: storageScope.customerDigest(distinctId: distinctId),
            budgetBytes: releasePinBudgetBytes, countLimit: releasePinCountLimit)
        if let suppliedStore { store = suppliedStore }
        else if let connected = try await events?.openCustomerStore(at: directory) { store = connected }
        else {
            let sqlite = SQLiteEventStore(conversionCaptureScope: storageScope.conversionNamespace)
            try await sqlite.initialize(path: directory)
            store = sqlite
        }
        let metadata = try await store.openCustomerState(cutoverAt: Int64(JourneyConversionWatch.millis(openedAt)))
        if let sqlite = store as? SQLiteEventStore { try await sqlite.bindConversionAuthority(storageScope) }
        let scope = try await store.customerScope(owner: owner)
        epoch = scope?.executionEpoch ?? 0
        if scope == nil || openExecution {
            try await store.putCustomerScope(.init(owner: owner, executionEpoch: epoch, executionRevoked: false, openedStateVersion: CustomerStoreSchema.stateVersion))
        }
        do {
            let store = store, root = root, files = files
            try await files.withExclusiveAccess {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) where metadata.legacyCleanupPending {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true,
                          ["json", "revoked"].contains(file.pathExtension),
                          JourneyReleasePinStore.isLowercaseSHA256(file.deletingPathExtension().lastPathComponent) else { continue }
                    try FileManager.default.removeItem(at: file)
                }
                _ = try files.collectOrphans(committedPaths: await store.committedReleasePinPaths())
                if metadata.legacyCleanupPending { try await store.finishLegacyCleanup(cutoverSequence: metadata.cutoverSequence) }
            }
         } catch {
            LogWarning("CustomerJourneyStore: file cleanup remains pending: \(error)")
        }
    }

    static func admissionTarget(_ receipt: JourneyStateArmReceipt) throws -> String {
        "admission:" + SHA256Provider.hexDigest(try ExactJSONCodec.canonicalize(ExactJSONCodec.encode(receipt)))
    }

    func key(_ journey: JourneyRun) -> CustomerJourneyKey {
        .init(owner: owner, journeyId: journey.journeyId, legGeneration: Int64(journey.generation))
    }

    func command(_ mutation: CustomerExecutionCommand.Mutation, items: [RoutedStableSystemEventBatchItem] = [], admission: JourneyCommitAdmission? = nil, profileFence: JourneyProfileFence? = nil, profileToken: JourneyProfileFenceToken? = nil) async throws -> CustomerExecutionResult {
        let command = try await prepareCommand(mutation, items: items, admission: admission,
            profileFence: profileFence, profileToken: profileToken)
        let result = try await execute(command)
        await events?.publishCustomerCommand(command, result: result)
        return result
    }

    private func prepareCommand(_ mutation: CustomerExecutionCommand.Mutation, items: [RoutedStableSystemEventBatchItem], admission: JourneyCommitAdmission? = nil, profileFence: JourneyProfileFence? = nil, profileToken: JourneyProfileFenceToken? = nil) async throws -> CustomerExecutionCommand {
        let records: [StableEventCaptureRecord]
        if items.isEmpty { records = [] }
        else if let events { records = try await events.prepareCustomerEvents(items) }
        else {
            records = try items.map { item in
                .init(eventId: item.request.eventId, event: try StoredEvent(id: item.request.eventId, name: item.request.name,
                    properties: item.request.properties ?? [:], timestamp: item.occurredAt, distinctId: distinctId, journeyOrigin: item.request.journeyOrigin), recordedAt: item.occurredAt)
            }
        }
        return CustomerExecutionCommand(owner: owner, epoch: epoch, mutation: mutation, events: records,
            admission: admission, profileFence: profileFence, profileToken: profileToken)
    }

    func commit(_ mutation: CustomerExecutionCommand.Mutation, records: [StableEventCaptureRecord], admission: JourneyCommitAdmission? = nil, profileFence: JourneyProfileFence? = nil, profileToken: JourneyProfileFenceToken? = nil) async throws -> CustomerExecutionResult {
        let command = CustomerExecutionCommand(owner: owner, epoch: epoch, mutation: mutation, events: records, admission: admission, profileFence: profileFence, profileToken: profileToken)
        let result = try await execute(command)
        await events?.publishCustomerCommand(command, result: result)
        return result
    }

    private func execute(_ command: CustomerExecutionCommand) async throws -> CustomerExecutionResult {
        try beforePersist?()
        if !command.events.isEmpty, let events, await events.customerStore() != nil {
            return try await events.commitCustomerCommand(command)
        }
        return try await store.executeCustomerCommand(command)
    }

    private func releasePreparedPins(_ preparation: CustomerPinPreparation) async {
        let files = files
        let cleanup = Task.detached {
            do {
                try await files.withExclusiveAccess { preparation.release() }
            } catch {
                // Keep the conservative reservation if collection's lock is unavailable.
                LogWarning("CustomerJourneyStore: prepared pin cleanup remains pending: \(error)")
            }
        }
        await cleanup.value
    }

    func runs() async throws -> [JourneyRun] { try await store.activeJourneys(owner: owner) }

    func current(_ id: String) async throws -> JourneyRun {
        guard let journey = try await runs().first(where: { $0.id == id }) else { throw CustomerStoreError.staleRevision }
        return journey
    }

    func admit(arm: ArmedJourney, release: JourneyReleaseProfileEntry, artifactSource: JourneyReleaseArtifactSource? = nil,
               executionSnapshot: JourneyRun.ExecutionSnapshot, reentry: Journey.Frequency, policy: Journey.Policy? = nil,
               entryStepId: String, at: Date, profileFence: JourneyProfileFence? = nil,
               profileFenceToken: JourneyProfileFenceToken? = nil, stateArmReceipt: JourneyStateArmReceipt? = nil,
               sourceEventId: String? = nil, pinsPrepared: (@Sendable () async throws -> Void)? = nil,
               onAdmitted: @escaping @Sendable () -> Void = {}) async throws -> JourneyRun? {
        guard release.envelope.descriptorSha256 == arm.reference.descriptorSha256,
              release.locator.experienceId == arm.reference.experienceId, release.locator.experienceVersionId == arm.reference.versionId,
              release.locator.legId == arm.reference.legId else { throw CustomerStoreError.invalidRow }
        if let profileFence, let profileFenceToken, !profileFence.isCurrent(profileFenceToken) { return nil }
        let journeyId: String, generation: Int
        switch arm.binding.type {
        case .new: journeyId = UUID.v7().uuidString.lowercased(); generation = 0
        case .continuation:
            guard let id = arm.binding.journeyId, let value = arm.binding.generation else { throw CustomerStoreError.invalidRow }
            journeyId = id; generation = value
        }
        let seed = JourneyRun(journeyId: journeyId, generation: generation, reference: arm.reference, executionSnapshot: executionSnapshot,
            artifactSHA256s: [], reentry: reentry, startedAt: at, isEnrollment: arm.binding.type == .new,
            startedEventId: UUID.v7().uuidString.lowercased(), completedEventId: UUID.v7().uuidString.lowercased(), stepId: entryStepId, context: arm.context)
        let item = try JourneyReporter.started(seed, owner: distinctId)
        let records: [StableEventCaptureRecord]
        if let events { records = try await events.prepareCustomerEvents([item]) }
        else {
            records = [.init(eventId: item.request.eventId, event: try StoredEvent(id: item.request.eventId, name: item.request.name,
                properties: item.request.properties ?? [:], timestamp: item.occurredAt, distinctId: distinctId), recordedAt: at)]
        }
        let store = self
        let (admission, preparation) = try await files.withExclusiveAccess {
            _ = try store.files.collectOrphans(committedPaths: await store.store.committedReleasePinPaths())
            let inherited = try await store.runs().first(where: { $0.reference.descriptorSha256 == arm.reference.descriptorSha256 })?.artifactSHA256s ?? []
            let prepared = try store.pins.prepareAdmission(release: release, descriptorSHA256: arm.reference.descriptorSha256, artifactSource: artifactSource, inheritedArtifactSHA256s: inherited)
            var journey = seed
            journey.artifactSHA256s = prepared.artifactSHA256s
            var references = [try store.files.reference(owner: store.owner, sha256: arm.reference.descriptorSha256, kind: .descriptor)]
            references += try prepared.artifactSHA256s.map { try store.files.reference(owner: store.owner, sha256: $0, kind: .artifact) }
            try store.files.synchronize(references)
            let watch: JourneyConversionWatch?
            if let policy, policy.goal != nil { watch = try JourneyConversionWatch(run: journey, policy: policy, delivery: arm.conversion) }
            else { watch = nil }
            let receipt = JourneyStateArmReceipt(arm)
            let target = try Self.admissionTarget(receipt)
            var admission = CustomerAdmission(journey: journey, pins: references, watch: watch, arm: receipt, sourceEventId: sourceEventId, targetKey: target, stateLatch: stateArmReceipt != nil)
            admission.policyHash = try policy.map { SHA256Provider.hexDigest(try ExactJSONCodec.encode($0)) } ?? ""
            return (admission, store.files.protectPreparedPins(references))
        }
        let command = CustomerExecutionCommand(owner: owner, epoch: epoch, mutation: .admit(admission),
            events: records, profileFence: profileFence, profileToken: profileFenceToken)
        let result: CustomerExecutionResult
        do {
            try await pinsPrepared?()
            result = try await execute(command)
        } catch {
            await releasePreparedPins(preparation)
            throw error
        }
        // Serialize reservation removal with collection's SQL snapshot as well
        // as its deletions. Publication owns no filesystem or writer lock.
        await releasePreparedPins(preparation)
        if result.journey != nil { onAdmitted() }
        await events?.publishCustomerCommand(command, result: result)
        return result.journey
    }

    func beginEvaluation(_ journey: JourneyRun, at now: Date, triggeringAt: Date?) async throws -> JourneyRun {
        let result = try await command(.beginEvaluation(key: key(journey), revision: journey.cursorRevision,
            now: Int64(JourneyConversionWatch.millis(now)), triggeringAt: triggeringAt.map { Int64(JourneyConversionWatch.millis($0)) }))
        guard let saved = result.journey else { throw CustomerStoreError.staleRevision }
        return saved
    }

    @discardableResult
    func transition(_ id: String, stepId: String, context: ArmedJourney.Context,
                    checkpoint: JourneyControlExecutor.Checkpoint? = nil, nativeSnapshot: ExperienceRunSnapshot? = nil,
                    experimentExposure: JourneyRun.ExperimentExposure? = nil, waitKind: String = "event",
                    expectedRevision: Int64? = nil, inputEventId: String? = nil, resetEvaluation: Bool = false,
                    localInvocationId: String? = nil, admission: JourneyCommitAdmission? = nil) async throws -> Bool {
        if let admission, admission.commitJournalIfCurrent({ true }) != true { return false }
        let journey = try await current(id)
        var transition = CustomerInputTransition(key: key(journey), expectedRevision: expectedRevision ?? journey.cursorRevision,
            eventId: inputEventId, targetKey: "cursor:\(journey.cursorRevision)", stepId: stepId, context: context,
            checkpoint: checkpoint, nativeSnapshot: nativeSnapshot ?? journey.nativeSnapshot, exposure: experimentExposure, waitKind: waitKind)
        transition.resetEvaluation = resetEvaluation
        transition.rendererInvocationId = localInvocationId
        _ = try await command(.applyInput(transition), admission: admission)
        return true
    }

    @discardableResult
    func park(_ id: String, stepId: String, until: Date?, admission: JourneyCommitAdmission? = nil) async throws -> Bool {
        let journey = try await current(id)
        var transition = CustomerInputTransition(key: key(journey), expectedRevision: journey.cursorRevision, eventId: nil,
            targetKey: "availability", stepId: stepId, context: journey.context, nativeSnapshot: journey.nativeSnapshot)
        transition.waitKind = "availability"
        transition.availabilityAt = until.map { Int64(JourneyConversionWatch.millis($0)) }
        _ = try await command(.applyInput(transition), admission: admission)
        return true
    }

    func resumeParked(_ id: String, expectedStepId: String, expectedPark: JourneyRun.Park,
                      advancingTo: (stepId: String, context: ArmedJourney.Context)? = nil, eventId: String? = nil,
                      expectedRevision: Int64? = nil, evaluation: CustomerWaitEvaluation? = nil, presentAt: Date? = nil,
                      admission: JourneyCommitAdmission) async throws -> JourneyRun? {
        guard admission.commitJournalIfCurrent({ true }) == true else { return nil }
        let journey = try await current(id)
        guard journey.stepId == expectedStepId, journey.park == expectedPark else { return nil }
        var transition = CustomerInputTransition(key: key(journey), expectedRevision: expectedRevision ?? journey.cursorRevision, eventId: eventId,
            targetKey: "wait:\(journey.cursorRevision)", stepId: advancingTo?.stepId ?? journey.stepId,
            context: advancingTo?.context ?? journey.context, nativeSnapshot: journey.nativeSnapshot, consumesWait: true)
        transition.waitEvaluation = evaluation
        transition.resumeInPresentAt = presentAt.map { Int64(JourneyConversionWatch.millis($0)) }
        return try await command(.resolveWait(transition), admission: admission).journey
    }

    func claimEffect(_ id: String, stepId: String, expectedRevision: Int64? = nil) async throws -> String {
        let journey = try await current(id)
        let result = try await command(.claimEffect(key: key(journey), revision: expectedRevision ?? journey.cursorRevision,
            stepId: stepId, effectId: UUID.v7().uuidString.lowercased(), kind: "native"))
        guard let effect = result.effectId else { throw CustomerStoreError.invalidRow }
        return effect
    }

    func retainPresentationCommerce(_ id: String, stepId: String, effectId: String, placementId: String?, admission: JourneyCommitAdmission) async throws -> JourneyRun? {
        let journey = try await current(id)
        return try await command(.retainCommerce(key: key(journey), revision: journey.cursorRevision, stepId: stepId, effectId: effectId, placementId: placementId), admission: admission).journey
    }

    func recordAuthoredCloseWhileCommercePending(_ id: String, effectId: String, outcome: String, admission: JourneyCommitAdmission) async throws -> Bool {
        let journey = try await current(id)
        _ = try await command(.authoredClose(key: key(journey), revision: journey.cursorRevision, effectId: effectId, outcome: outcome), admission: admission)
        return true
    }

    func deferPresentationCommerceOutcome(_ id: String, stepId: String, effectId: String, eventId: String, admission: JourneyCommitAdmission) async throws -> Bool {
        let journey = try await current(id)
        let result = try await command(.receiveEffectResult(key: key(journey), revision: journey.cursorRevision, stepId: stepId, effectId: effectId, eventId: eventId), admission: admission)
        return !result.replayed
    }

    func settlePresentationCommerce(_ id: String, stepId: String, effectId: String, nextStepId: String?, eventId: String? = nil, admission: JourneyCommitAdmission?) async throws -> JourneyRun? {
        let journey = try await current(id)
        let transition = CustomerInputTransition(key: key(journey), expectedRevision: journey.cursorRevision, eventId: eventId,
            targetKey: "effect:\(effectId)", stepId: nextStepId ?? journey.stepId, context: journey.pendingCommerce?.context ?? journey.context, nativeSnapshot: journey.nativeSnapshot)
        return try await command(.settleEffect(transition, effectId: effectId, stepId: stepId), admission: admission).journey
    }

    @discardableResult
    func bindExperimentExposures(_ id: String, to screenId: String, admission: JourneyCommitAdmission) async throws -> Bool {
        guard admission.commitJournalIfCurrent({ true }) == true else { return false }
        let journey = try await current(id)
        _ = try await command(.bindExposures(key: key(journey), revision: journey.cursorRevision, screenId: screenId), admission: admission)
        return true
    }

    @discardableResult
    func markExperimentExposuresShown(_ id: String, screenId: String, at: Date, admission: JourneyCommitAdmission) async throws -> Bool {
        guard admission.commitJournalIfCurrent({ true }) == true else { return false }
        let journey = try await current(id)
        let selections = journey.experimentExposures.filter { $0.shownAt == nil && $0.presentationScreenId == screenId }
        let items = try selections.map { try JourneyReporter.exposure($0, journey: journey, owner: distinctId, at: at) }
        _ = try await command(.publishExposures(key: key(journey), revision: journey.cursorRevision, screenId: screenId, shownAt: Int64(JourneyConversionWatch.millis(at))), items: items, admission: admission)
        return true
    }

    @discardableResult
    func complete(_ id: String, outcome: String, at: Date, eventOutputs: ExactJSONObject<JourneyReleaseJSONValue> = [:],
                  responseOutputs: ExactJSONObject<JourneyReleaseJSONValue> = [:], expectedRevision: Int64? = nil, admission: JourneyCommitAdmission? = nil) async throws -> Bool {
        if let admission, admission.commitJournalIfCurrent({ true }) != true { return false }
        guard let journey = try await runs().first(where: { $0.id == id }) else { return true }
        if let expectedRevision, journey.cursorRevision != expectedRevision { throw CustomerStoreError.staleRevision }
        let report = try JourneyReporter.completed(journey, owner: distinctId, outcome: outcome, at: at,
            outputs: .init(event: eventOutputs, responses: responseOutputs))
        _ = try await command(.complete(key: key(journey), revision: journey.cursorRevision, at: Int64(JourneyConversionWatch.millis(at)), reportId: journey.completedEventId), items: [report], admission: admission)
        await collectPinOrphans()
        return true
    }

    private func collectPinOrphans() async {
        // File maintenance follows commit and cannot change the terminal result.
        do {
            let files = files, store = store
            _ = try await files.withExclusiveAccess {
                try files.collectOrphans(committedPaths: await store.committedReleasePinPaths())
            }
        }
        catch { LogWarning("CustomerJourneyStore: pin cleanup remains pending: \(error)") }
    }

    func conversionWatches() async throws -> [String: JourneyConversionWatch] { try await store.customerWatches(owner: owner) }
    func recordConversionOccurrence(_ event: NuxieEvent, acceptedAt: Date, matching: Set<String>, admission: JourneyCommitAdmission, processingAt: Date? = nil) async throws -> Bool {
        guard event.distinctId.utf8.elementsEqual(distinctId.utf8) else { throw CustomerStoreError.wrongOwner }
        guard admission.commitJournalIfCurrent({ true }) == true else { return false }
        var watches = try await conversionWatches()
        let digest = SHA256Provider.hexDigest(try ExactJSONCodec.canonicalize(ExactJSONCodec.encode(watches)))
        var eligible = Set<String>()
        if let occurrence = JourneyConversionWatch.normalized(event, acceptedAt: acceptedAt) {
            for watch in watches.values where await watch.matches(occurrence) { eligible.insert(watch.journeyId) }
        }
        JourneyConversionWatch.apply(event: event, acceptedAt: acceptedAt, matching: eligible, watches: &watches)
        _ = try await command(.measure(eventId: event.id, watches: watches, expectedDigest: digest), admission: admission)
        return true
    }

    func retainStateArmReceipts(_ allowed: Set<JourneyStateArmReceipt>) async throws { _ = try await command(.retainArms(allowed)) }
    func clearStateArmReceipts(entryKind: JourneyEntryCondition.Kind) async throws { _ = try await command(.clearArms(entryKind)) }
    func releasePin(descriptorSHA256: String) async throws -> JourneyReleaseProfileEntry? {
        guard try await runs().contains(where: { $0.reference.descriptorSha256 == descriptorSHA256 }) else { return nil }
        return try pins.release(descriptorSHA256: descriptorSHA256)
    }
    func pinnedArtifacts(forRunId id: String) async throws -> JourneyPinnedReleaseArtifacts? {
        try pins.pinnedArtifacts(sha256s: await current(id).artifactSHA256s)
    }
    func recover(at: Date, invalidPinIds: Set<String> = []) async throws -> [JourneyRun] {
        let publication = try await recoverForOpen(at: at, invalidPinIds: invalidPinIds)
        await publish(publication)
        return try await runs()
    }

    func recoverForOpen(at: Date, invalidPinIds: Set<String> = []) async throws -> CustomerCommandPublication {
        let active = try await runs()
        let broken = active.filter { $0.park == nil || invalidPinIds.contains($0.id) || (try? pins.release(descriptorSHA256: $0.reference.descriptorSha256)) == nil }
        return try await recover(broken, at: at, revoke: false)
    }
    func abandonAll(at: Date) async throws {
        if let scope = try await store.customerScope(owner: owner), scope.executionEpoch > epoch, scope.executionRevoked { return }
        let publication = try await recover(try await runs(), at: at, revoke: true)
        await publish(publication)
    }
    private func recover(_ active: [JourneyRun], at: Date, revoke: Bool) async throws -> CustomerCommandPublication {
        let boundaries = active.map { CustomerTerminalBoundary(key: key($0), revision: $0.cursorRevision, reportId: $0.completedEventId, at: Int64(JourneyConversionWatch.millis(at))) }
        let reports = try active.map { try JourneyReporter.completed($0, owner: distinctId, outcome: "abandoned", at: at, outputs: .init(event: $0.outputs.event, responses: $0.context.responses)) }
        let command = try await prepareCommand(.recover(boundaries, revoke: revoke), items: reports)
        let result = try await execute(command)
        await collectPinOrphans()
        return .init(command: command, result: result)
    }

    func publish(_ publication: CustomerCommandPublication) async {
        await events?.publishCustomerCommand(publication.command, result: publication.result)
    }
    func finalizeRevocation() async throws -> Bool { try await runs().isEmpty }

    func reserveResponseSave(run: JourneyRun, formName: String, answers: ExactJSONObject<JourneyReleaseJSONValue>, queued: Bool, admission: JourneyCommitAdmission? = nil) async throws -> JourneyResponseSave {
        if let admission, admission.commitJournalIfCurrent({ true }) != true { throw CancellationError() }
        let result = try await command(.reserveResponse(key: key(run), formName: formName, answers: answers, queued: queued), admission: admission)
        guard let sheet = result.response else { throw JourneyResponseSaveError.invalidReceipt }
        return sheet
    }
    func pendingResponseSaves() async throws -> [JourneyResponseSave] { try await store.customerResponseLanes(owner: owner).values.compactMap(\.pending) }
    func responseSaveDisplays(journeyId: String) async throws -> ExactJSONObject<JourneyResponseSaveDisplay> {
        var displays: ExactJSONObject<JourneyResponseSaveDisplay> = [:]
        for (key, lane) in try await store.customerResponseLanes(owner: owner) where key.journeyId == journeyId { displays[key.formName] = lane.display }
        return displays
    }
    func responseSaveAttempts(at now: Date) async throws -> [JourneyResponseSaveAttempt] {
        var lanes = try await store.customerResponseLanes(owner: owner)
        if lanes.values.contains(where: { $0.retry.map { Int64(JourneyConversionWatch.millis(now)) < $0.observedAt } == true }) {
            _ = try await command(.normalizeResponseClock(at: Int64(JourneyConversionWatch.millis(now))))
            lanes = try await store.customerResponseLanes(owner: owner)
        }
        return lanes.values.compactMap { lane in
            lane.pending.map { .init(sheet: $0, retry: lane.retry?.domainValue) }
        }
    }
    func confirmResponseSave(_ sheet: JourneyResponseSave, storedSequence: Int64) async throws {
        _ = try await recordResponseSaveReply(sheet, reply: .init(code: .saved, sequence: storedSequence), at: Date())
    }
    func recordWaitingResponseSaveReply(_ sheet: JourneyResponseSave, reply: JourneyResponseSaveReply) async throws {
        _ = try await command(.responseReply(sheet, reply, at: Int64(JourneyConversionWatch.millis(Date())), waiting: true))
    }
    func recordResponseSaveReply(_ sheet: JourneyResponseSave, reply: JourneyResponseSaveReply, at now: Date) async throws -> Bool {
        try await command(.responseReply(sheet, reply, at: Int64(JourneyConversionWatch.millis(now)), waiting: false)).stopped
    }
}
