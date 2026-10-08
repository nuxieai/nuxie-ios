import Foundation
#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import NuxieRuntime
#endif

/// Owns the run's native values, shared by all of its screen presentations.
actor ExperienceRunValues {
    private var retired = false
    private let restoredSnapshot: ExperienceRunSnapshot?

    init(snapshot: ExperienceRunSnapshot? = nil) { restoredSnapshot = snapshot }

    func journeyValues() async throws -> ExactJSONObject<JourneyReleaseJSONValue> {
        try await snapshot()?.journeyValues ?? [:]
    }

    func snapshot() async throws -> ExperienceRunSnapshot? {
        #if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
        guard !retired, let native = try await nativeTask?.value else { return nil }
        let snapshot = try await native.sessions.snapshot(native.reference)
        guard !retired else { throw CancellationError() }
        return ExperienceRunSnapshot(native: snapshot, catalog: native.catalog, origins: native.origins, authoredIDs: native.authoredIDs)
        #else
        return nil
        #endif
    }

    func responseAnswers(form: String, policy: JourneyReleaseValuePolicy) async throws -> ExactJSONObject<JourneyReleaseJSONValue> {
        #if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
        guard !retired, let declaration = policy.responses[form], let native = try await nativeTask?.value else {
            throw ExperienceInteractiveScreenError.stateContract("Response form is unavailable")
        }
        let snapshot = try await native.sessions.snapshot(native.reference)
        guard !retired else { throw CancellationError() }
        return try ExperienceResponseSheet.read(form: form, declaration: declaration, snapshot: snapshot, catalog: native.catalog)
        #else
        throw JourneyResponseSaveError.wrongOwner
        #endif
    }

    var isPrepared: Bool {
        #if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
        nativeTask != nil
        #else
        false
        #endif
    }

    func retire() async {
        retired = true
        #if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
        let task = nativeTask
        nativeTask = nil
        preparation = nil
        if let native = try? await task?.value {
            do { try await native.sessions.retire() }
            catch { LogWarning("Run values could not retire: \(error)") }
        }
        #endif
    }

    #if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
    struct Native: Sendable {
        let sessions: NuxieNativeSessionGroup
        let reference: NuxieNativeViewModelReference
        let schemaIndex: Int
        let catalog: NuxieNativeViewModelCatalog
        let origins: [UInt64: [ExperienceRunListSnapshot.OriginStep]]
        let authoredIDs: Set<UInt64>
    }

    private var preparation: NuxieNativePreparedFile?
    private var nativeTask: Task<Native?, Error>?
    private var preparationGeneration = 0

    func native(in preparedFile: NuxieNativePreparedFile) async throws -> Native? {
        guard !retired else {
            throw ExperienceInteractiveScreenError.stateContract("The run has ended")
        }
        if let preparation, !preparation.hasSameBytes(as: preparedFile) {
            throw ExperienceInteractiveScreenError.stateContract("A run cannot change its native file")
        }
        if let nativeTask {
            let native = try await resolve(nativeTask, generation: preparationGeneration)
            guard !retired else {
                throw ExperienceInteractiveScreenError.stateContract("The run has ended")
            }
            return native
        }
        preparation = preparedFile
        let restoredSnapshot = restoredSnapshot
        let task = Task {
            let catalog = await preparedFile.viewModelCatalog()
            guard let schema = catalog.schemas.first(where: { $0.name == "Experience" }) else { return nil as Native? }
            let sessions = try await preparedFile.makeSessionGroup()
            let reference = try await sessions.makeViewModel(schemaIndex: schema.index, authoredInstanceIndex: 0)
            do {
                let initial = try await sessions.snapshot(reference)
                let origins = ExperienceRunListSnapshot.authoredOrigins(initial)
                if let lists = restoredSnapshot?.lists {
                    try await lists.restore(sessions: sessions, root: reference)
                } else if let restoredSnapshot {
                    let mutations = try restoredSnapshot.mutations(for: reference)
                    if !mutations.isEmpty { _ = try await sessions.mutate(mutations) }
                }
                return Native(sessions: sessions, reference: reference, schemaIndex: schema.index,
                    catalog: catalog, origins: origins, authoredIDs: Set(initial.instances.map(\.id)))
            } catch {
                try? await sessions.retire()
                throw error
            }
        }
        preparationGeneration += 1
        nativeTask = task
        let native = try await resolve(task, generation: preparationGeneration)
        guard !retired else {
            throw ExperienceInteractiveScreenError.stateContract("The run has ended")
        }
        return native
    }
    private func resolve(_ task: Task<Native?, Error>, generation: Int) async throws -> Native? {
        do { return try await task.value }
        catch {
            if preparationGeneration == generation {
                nativeTask = nil
                preparation = nil
            }
            throw error
        }
    }
    #endif
}
