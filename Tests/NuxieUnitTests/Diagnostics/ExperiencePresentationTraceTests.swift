import Foundation
import Nimble
import Quick

@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class ExperiencePresentationTraceTests: AsyncSpec {
    override class func spec() {
        it("keeps events partitioned by their explicit presentation attempt") {
            let recorder = InMemoryExperiencePresentationTrace()
            let first = ExperiencePresentationAttempt(
                id: "attempt-1",
                triggerEvent: "upgrade_tapped",
                startedAt: Date(timeIntervalSince1970: 10)
            )
            let second = ExperiencePresentationAttempt(
                id: "attempt-2",
                triggerEvent: "export_tapped",
                startedAt: Date(timeIntervalSince1970: 20)
            )

            recorder.record(
                attempt: first,
                stage: .triggerAccepted,
                at: Date(timeIntervalSince1970: 11)
            )
            recorder.record(
                attempt: second,
                stage: .triggerAccepted,
                at: Date(timeIntervalSince1970: 21)
            )
            recorder.record(
                attempt: first,
                stage: .presentationRequested(
                    experienceVersionId: "experience-v1",
                    route: .direct
                ),
                at: Date(timeIntervalSince1970: 12)
            )

            expect(recorder.events(for: first.id).map(\.attempt.id))
                .to(equal(["attempt-1", "attempt-1"]))
            expect(recorder.events(for: second.id).map(\.attempt.id))
                .to(equal(["attempt-2"]))
        }

        it("records wall-clock and display-comparable monotonic timestamps") {
            let recorder = InMemoryExperiencePresentationTrace()
            let attempt = ExperiencePresentationAttempt(
                id: "attempt-clock",
                triggerEvent: "upgrade_tapped",
                startedAt: Date(timeIntervalSince1970: 10),
                startedAtMonotonicTime: 100
            )
            let timestamp = ExperiencePresentationTimestamp(
                wallClock: Date(timeIntervalSince1970: 11),
                monotonicTime: 101.25
            )

            recorder.record(
                attempt: attempt,
                stage: .runtimeReady,
                timestamp: timestamp
            )

            let event = recorder.events(for: attempt.id).first
            expect(event?.occurredAt).to(equal(timestamp.wallClock))
            expect(event?.monotonicTime).to(equal(timestamp.monotonicTime))
            expect(event?.attempt.startedAtMonotonicTime).to(equal(100))
        }

        it("derives a drawable wall clock from a coherent callback-time clock pair") {
            let observedAt = ExperiencePresentationTimestamp(
                wallClock: Date(timeIntervalSince1970: 200),
                monotonicTime: 50
            )

            let presentedAt = ExperiencePresentationTimestamp.anchored(
                monotonicTime: 49.25,
                observedAt: observedAt
            )

            expect(presentedAt.monotonicTime).to(equal(49.25))
            expect(presentedAt.wallClock).to(equal(Date(timeIntervalSince1970: 199.25)))
        }

        it("creates the attempt before trigger work and passes the same identity into TriggerService") {
            var harness = try SDKTestHarness.make(prefix: "presentation_attempt")
            let triggerService = MockTriggerService()
            let recorder = InMemoryExperiencePresentationTrace()
            harness.overrides.triggers = triggerService
            harness.overrides.presentationTrace = recorder
            try harness.setupSDK()

            _ = await NuxieSDK.shared.triggerAndWait("upgrade_tapped")

            let received = await triggerService.presentationAttempts()
            let accepted = recorder.events().filter { event in
                event.stage == .triggerAccepted
            }
            expect(received).to(haveCount(1))
            expect(accepted).to(haveCount(1))
            expect(received.first?.id).to(equal(accepted.first?.attempt.id))
            expect(received.first?.triggerEvent).to(equal("upgrade_tapped"))
            expect(accepted.first?.occurredAt).to(equal(received.first?.startedAt))

            await NuxieSDK.shared.shutdown()
            harness.cleanup()
        }

        it("round-trips the attempt through persisted journey context") {
            let attempt = ExperiencePresentationAttempt(
                id: "attempt-journey",
                triggerEvent: "onboarding_started",
                startedAt: Date(timeIntervalSince1970: 1_234.5),
                startedAtMonotonicTime: 456.75
            )
            let journey = TestJourneyBuilder().build()

            await ExperiencePresentationAttemptJourneyContext.store(
                attempt,
                in: journey,
                at: Date(timeIntervalSince1970: 2_000)
            )

            let loadedAttempt = await ExperiencePresentationAttemptJourneyContext.load(from: journey)
            expect(loadedAttempt).to(equal(attempt))
        }

        it("round-trips whole-second attempt timestamps through journey JSON") {
            let attempt = ExperiencePresentationAttempt(
                id: "attempt-integral-timestamps",
                triggerEvent: "onboarding_started",
                startedAt: Date(timeIntervalSince1970: 1_234),
                startedAtMonotonicTime: 456
            )
            let journey = TestJourneyBuilder().build()
            await ExperiencePresentationAttemptJourneyContext.store(
                attempt,
                in: journey,
                at: Date(timeIntervalSince1970: 2_000)
            )

            let encoded = try await JSONEncoder().encode(journey.snapshot())
            let decoded = try JSONDecoder().decode(JourneySnapshot.self, from: encoded)

            expect(ExperiencePresentationAttemptJourneyContext.load(from: decoded))
                .to(equal(attempt))
        }

        it("drops a persisted monotonic start when the device has rebooted") {
            let attempt = ExperiencePresentationAttempt(
                id: "attempt-before-reboot",
                triggerEvent: "onboarding_started",
                startedAt: Date(timeIntervalSince1970: 1_234),
                startedAtMonotonicTime: 456
            )
            var state = TestJourneyBuilder().buildSnapshot()

            ExperiencePresentationAttemptJourneyContext.store(
                attempt,
                in: &state,
                at: Date(timeIntervalSince1970: 2_000),
                bootSessionId: "boot-a"
            )

            let loaded = ExperiencePresentationAttemptJourneyContext.load(
                from: state,
                bootSessionId: "boot-b"
            )
            expect(loaded?.id).to(equal(attempt.id))
            expect(loaded?.startedAt).to(equal(attempt.startedAt))
            expect(loaded?.startedAtMonotonicTime).to(beNil())
        }

        it("exports correlated work spans with terminal duration and failure attribution") {
            let recorder = InMemoryExperiencePresentationTrace()
            let attempt = ExperiencePresentationAttempt(
                id: "attempt-waterfall",
                triggerEvent: "upgrade_tapped",
                startedAt: Date(timeIntervalSince1970: 10),
                startedAtMonotonicTime: 100
            )
            let context = ExperiencePresentationTraceContext(
                attempt: attempt,
                recorder: recorder,
                wallClock: { Date(timeIntervalSince1970: 20) },
                monotonicClock: { 200 }
            )

            let acquisition = context.begin(
                .artifactPackageAcquisition,
                attributes: ["experience_version_id": "experience-v1"]
            )
            context.complete(
                acquisition,
                at: ExperiencePresentationTimestamp(
                    wallClock: Date(timeIntervalSince1970: 21),
                    monotonicTime: 201.25
                ),
                attributes: ["source": "download", "bytes": "4096"]
            )
            let authentication = context.begin(.packageAuthentication)
            context.fail(
                authentication,
                error: ExperiencePackageAuthenticationError.invalidSignature,
                at: ExperiencePresentationTimestamp(
                    wallClock: Date(timeIntervalSince1970: 22),
                    monotonicTime: 202.5
                )
            )

            let snapshot = recorder.qualificationSnapshot(for: attempt.id)
            expect(snapshot.attemptId).to(equal(attempt.id))
            expect(snapshot.events.map(\.attemptId)).to(allPass(equal(attempt.id)))
            expect(snapshot.events.map(\.stage)).to(equal([
                "work_started",
                "work_completed",
                "work_started",
                "work_failed"
            ]))
            expect(snapshot.events[1].work).to(equal("artifact_package_acquisition"))
            expect(snapshot.events[1].durationMilliseconds).to(equal(1_250))
            expect(snapshot.events[1].attributes["source"]).to(equal("download"))
            expect(snapshot.events[3].work).to(equal("package_authentication"))
            expect(snapshot.events[3].durationMilliseconds).to(equal(2_500))
            expect(snapshot.events[3].errorCode).to(equal("package.signature.bad_signature"))
        }
    }
}
