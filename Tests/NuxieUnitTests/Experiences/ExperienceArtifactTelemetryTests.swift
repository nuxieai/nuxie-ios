import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class ExperienceArtifactTelemetryTests: XCTestCase {
    @MainActor
    func testFailedArtifactTracePreservesMeasuredRequiredAcquisitionWork() async {
        let behavior = ExperienceBehaviorDefinition(
            reference: ExperienceReference(
                experienceId: "experience-resource-failure",
                versionId: "version-resource-failure"
            ),
            buildId: "build-resource-failure",
            artifactContentHash: String(repeating: "c", count: 64),
            name: "Resource failure",
            reentry: .everyTime,
            publishedAt: "2026-08-14T00:00:00Z",
            trigger: nil,
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            timeLimitSeconds: nil,
            experienceType: nil,
            presentationStyle: .fullScreen
        )
        let experience = Experience(
            behavior: behavior,
            journey: JourneyDocument(screens: [JourneyScreen(id: "screen-1")]),
            assetBaseURL: URL(string: "https://assets.nuxie.test/")!
        )
        let measured = ExperienceReleaseResourceMetrics(
            readBytes: 17,
            hashedBytes: 17,
            parsedBytes: 0,
            duplicateReadBytes: 0,
            duplicateHashBytes: 0,
            duplicateParseBytes: 0,
            preloadBytes: 0,
            unusedPreloadBytes: 0
        )
        let recorder = InMemoryExperiencePresentationTrace()
        let context = ExperiencePresentationTraceContext(
            attempt: .make(triggerEvent: "resource_failure", startedAt: Date()),
            recorder: recorder
        )
        let viewModel = ExperienceViewModel(
            experience: experience,
            artifactLoader: { _, _, _ in
                throw ExperienceReleaseResourceFailure(
                    underlying: ExperienceReleaseAcquisitionError.objectDigestMismatch(
                        key: "renders/sha256/expected.riv",
                        expected: String(repeating: "c", count: 64),
                        actual: String(repeating: "d", count: 64)
                    ),
                    resourceMetrics: measured
                )
            },
            eventLog: MockEventLog()
        )
        viewModel.updatePresentationTraceContext(context)

        viewModel.loadExperience()
        for _ in 0..<100 {
            if viewModel.currentState == .error { break }
            await Task.yield()
        }

        let failureAttributes = recorder.events().compactMap {
            event -> [String: String]? in
            guard case .workFailed(_, .artifactAcquisition, _, _, let attributes) =
                event.stage else { return nil }
            return attributes
        }
        XCTAssertEqual(viewModel.currentState, .error)
        XCTAssertEqual(failureAttributes.count, 1)
        XCTAssertEqual(failureAttributes[0]["read_bytes"], "17")
        XCTAssertEqual(failureAttributes[0]["hashed_bytes"], "17")
    }

    @MainActor
    func testDescriptorTelemetryUsesExactVersionAndSignedRIVDigestForSuccessAndFailure() {
        let versionID = "version-telemetry-exact"
        let rivDigest = String(repeating: "b", count: 64)
        let behavior = ExperienceBehaviorDefinition(
            reference: ExperienceReference(
                experienceId: "experience-telemetry",
                versionId: versionID
            ),
            buildId: "build-is-not-a-content-hash",
            artifactContentHash: rivDigest,
            name: "Telemetry",
            reentry: .everyTime,
            publishedAt: "2026-08-13T00:00:00Z",
            trigger: nil,
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            timeLimitSeconds: nil,
            experienceType: nil,
            presentationStyle: .fullScreen
        )
        let experience = Experience(
            behavior: behavior,
            journey: JourneyDocument(
                screens: [JourneyScreen(id: "screen-1")]
            ),
            assetBaseURL: URL(string: "https://assets.nuxie.test/")!
        )

        let successLog = MockEventLog()
        let success = ExperienceViewModel(
            experience: experience,
            artifactLoader: { _, _, _ in throw CancellationError() },
            eventLog: successLog
        )
        success.handleLoadingFinished()

        let failureLog = MockEventLog()
        let failure = ExperienceViewModel(
            experience: experience,
            artifactLoader: { _, _, _ in throw CancellationError() },
            eventLog: failureLog
        )
        failure.handleLoadingFailed(NuxieError.invalidConfiguration("expected"))

        for event in [
            successLog.trackedEvents.first {
                $0.name == JourneyEvents.experienceArtifactLoadSucceeded
            },
            failureLog.trackedEvents.first {
                $0.name == JourneyEvents.experienceArtifactLoadFailed
            },
        ] {
            XCTAssertEqual(event?.properties?["experience_version"] as? String, versionID)
            XCTAssertEqual(event?.properties?["artifact_content_hash"] as? String, rivDigest)
            XCTAssertEqual(
                event?.properties?["artifact_build_id"] as? String,
                "build-is-not-a-content-hash"
            )
        }
    }

}
