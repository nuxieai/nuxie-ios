import Foundation
#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import NuxieRuntime
#endif

/// Owns the run's native values, shared by all of its screen presentations.
actor ExperienceRunValues {
    private var retired = false

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
    }

    private var preparation: NuxieNativePreparedFile?
    private var nativeTask: Task<Native?, Error>?

    func native(in preparedFile: NuxieNativePreparedFile) async throws -> Native? {
        guard !retired else {
            throw ExperienceInteractiveScreenError.stateContract("The run has ended")
        }
        if let preparation, !preparation.hasSameBytes(as: preparedFile) {
            throw ExperienceInteractiveScreenError.stateContract("A run cannot change its native file")
        }
        if let nativeTask {
            let native = try await nativeTask.value
            guard !retired else {
                throw ExperienceInteractiveScreenError.stateContract("The run has ended")
            }
            return native
        }
        preparation = preparedFile
        let task = Task {
            let catalog = await preparedFile.viewModelCatalog()
            guard let schema = catalog.schemas.first(where: { $0.name == "Experience" }) else { return nil as Native? }
            let sessions = try await preparedFile.makeSessionGroup()
            let reference = try await sessions.makeViewModel(schemaIndex: schema.index, authoredInstanceIndex: 0)
            return Native(sessions: sessions, reference: reference, schemaIndex: schema.index)
        }
        nativeTask = task
        let native = try await task.value
        guard !retired else {
            throw ExperienceInteractiveScreenError.stateContract("The run has ended")
        }
        return native
    }
    #endif
}
