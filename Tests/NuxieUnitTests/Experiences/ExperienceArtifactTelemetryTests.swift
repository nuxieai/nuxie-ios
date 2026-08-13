import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class ExperienceArtifactTelemetryTests: XCTestCase {
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
            packageStore: ExperiencePackageStore(),
            eventLog: successLog
        )
        success.handleLoadingFinished()

        let failureLog = MockEventLog()
        let failure = ExperienceViewModel(
            experience: experience,
            packageStore: ExperiencePackageStore(),
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

    @MainActor
    func testLegacyTelemetryUsesExactVersionAndSignedPackageDigestForSuccessAndFailure() {
        let versionID = "legacy-version-exact"
        let packageDigest = String(repeating: "c", count: 64)
        let remote = RemoteExperience(
            experienceId: "legacy-experience",
            versionId: versionID,
            buildId: "legacy-build",
            artifact: RemoteExperienceArtifact(
                url: "https://cdn.nuxie.test/legacy.nux",
                sha256: packageDigest,
                sizeBytes: 123
            ),
            name: "Legacy",
            reentry: .everyTime,
            publishedAt: "2026-08-13T00:00:00Z"
        )
        let experience = Experience(
            remote: remote,
            journey: JourneyDocument(
                screens: [JourneyScreen(id: "screen-1")]
            ),
            assetBaseURL: URL(string: "https://assets.nuxie.test/")!
        )

        let successLog = MockEventLog()
        let success = ExperienceViewModel(
            experience: experience,
            packageStore: ExperiencePackageStore(),
            eventLog: successLog
        )
        success.handleLoadingFinished()

        let failureLog = MockEventLog()
        let failure = ExperienceViewModel(
            experience: experience,
            packageStore: ExperiencePackageStore(),
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
            XCTAssertEqual(
                event?.properties?["artifact_content_hash"] as? String,
                packageDigest
            )
        }
    }
}
