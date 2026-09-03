import Foundation
@testable import Nuxie

final class MockExperiencePresentationService:
    ExperiencePresentationServiceProtocol,
    @unchecked Sendable
{
    @MainActor private(set) var isExperiencePresented = false
    @MainActor private(set) var presentedJourneyId: String?
    private(set) var dismissCurrentExperienceCallCount = 0
    private(set) var shutdownCurrentExperienceCallCount = 0
    private(set) var appBecameActiveCallCount = 0
    private(set) var appDidEnterBackgroundCallCount = 0

    @MainActor func setPresented(journeyId: String?) {
        presentedJourneyId = journeyId
        isExperiencePresented = journeyId != nil
    }

    @MainActor func dismissCurrentExperience() async {
        await dismissCurrentExperience(reason: .hostDismissed)
    }

    @MainActor func dismissCurrentExperience(reason: CloseReason) async {
        _ = reason
        dismissCurrentExperienceCallCount += 1
        isExperiencePresented = false
        presentedJourneyId = nil
    }

    @MainActor func dismissCurrentExperienceFromHost() async {
        await dismissCurrentExperience(reason: .hostDismissed)
    }

    @MainActor func shutdownCurrentExperience() async {
        shutdownCurrentExperienceCallCount += 1
        isExperiencePresented = false
        presentedJourneyId = nil
    }

    @MainActor func onAppBecameActive() {
        appBecameActiveCallCount += 1
    }

    @MainActor func onAppDidEnterBackground() {
        appDidEnterBackgroundCallCount += 1
    }

    @MainActor func reset() {
        isExperiencePresented = false
        presentedJourneyId = nil
        dismissCurrentExperienceCallCount = 0
        shutdownCurrentExperienceCallCount = 0
        appBecameActiveCallCount = 0
        appDidEnterBackgroundCallCount = 0
    }
}
