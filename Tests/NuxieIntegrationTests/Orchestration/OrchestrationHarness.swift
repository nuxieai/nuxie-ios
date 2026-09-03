import Foundation
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

/// A full production composition root with only transport, time, and the UI
/// edge replaced. These tests exercise durable adjacent subsystems across
/// process restarts while using the production Journey composition.
final class OrchestrationStack {
    let core: NuxieCore
    let experienceService: MockExperienceService

    private init(
        core: NuxieCore,
        experienceService: MockExperienceService
    ) {
        self.core = core
        self.experienceService = experienceService
    }

    static func boot(
        storageURL: URL,
        api: MockNuxieApi,
        dateProvider: MockDateProvider,
        sleepProvider: MockSleepProvider,
        distinctId: String,
        initialFeatureAccess: [String: FeatureAccess] = [:],
        forwardingHandler: ForwardingEventHandler? = nil,
        productService: ProductService? = nil,
        configure: ((NuxieConfiguration) -> Void)? = nil
    ) async throws -> OrchestrationStack {
        try FileManager.default.createDirectory(
            at: storageURL,
            withIntermediateDirectories: true
        )

        let configuration = NuxieConfiguration(
            apiKey: "orchestration-suite-key"
        )
        configuration.testingOverrides.customStoragePath = storageURL
        configuration.testingOverrides.flushAt = 10_000
        configuration.testingOverrides.flushInterval = 3_600
        configuration.testingOverrides.retryCount = 1
        configuration.testingOverrides.retryDelay = 0.01
        configure?(configuration)

        let identity = IdentityService(customStoragePath: storageURL)
        identity.setDistinctId(distinctId)
        let experienceService = MockExperienceService()
        var overrides = NuxieCoreOverrides()
        overrides.api = api
        overrides.dateProvider = dateProvider
        overrides.sleepProvider = sleepProvider
        overrides.identity = identity
        overrides.experiences = experienceService
        overrides.experiencePresentation = MockExperiencePresentationService()
        overrides.productService = productService

        let core = NuxieCore(
            configuration: configuration,
            overrides: overrides
        )
        if !initialFeatureAccess.isEmpty {
            await MainActor.run {
                core.featureInfo.admitProfileSnapshot(
                    initialFeatureAccess,
                    admittedAt: dateProvider.now()
                )
            }
        }

        if let journeys = core.journeys {
            await core.eventLog.subscribeCommitted { [weak journeys] event in
                await journeys?.handleEvent(event)
            }
        }
        if let forwardingHandler {
            await core.eventLog.subscribeForwarding(handler: forwardingHandler)
        }
        try await core.eventLog.configure(configuration: core.configuration)
        await core.journeys?.initialize()
        await core.featureUseCommands.recover()

        return OrchestrationStack(
            core: core,
            experienceService: experienceService
        )
    }

    var eventLog: EventLogProtocol { core.eventLog }

    func kill() async {
        await core.eventLog.close()
    }

    func shutdownForCleanup() async {
        await core.userTransitions.drain()
        await core.journeys?.shutdown()
        await core.featureUseCommands.close()
        await core.eventLog.close()
    }
}
