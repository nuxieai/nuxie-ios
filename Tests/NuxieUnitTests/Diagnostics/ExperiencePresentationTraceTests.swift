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
                    route: .journey
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

        it("uses the callback observation when a physical drawable reports no presentation time") {
            let observedAt = ExperiencePresentationTimestamp(
                wallClock: Date(timeIntervalSince1970: 200),
                monotonicTime: 50
            )

            let presentedAt = ExperiencePresentationTimestamp.anchored(
                monotonicTime: 0,
                observedAt: observedAt
            )

            expect(presentedAt).to(equal(observedAt))
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
            let routingStarted = recorder.events().filter { event in
                guard case .workStarted(_, .triggerRouting, _) = event.stage else {
                    return false
                }
                return true
            }
            expect(received).to(haveCount(1))
            expect(accepted).to(haveCount(1))
            expect(routingStarted).to(haveCount(1))
            expect(received.first?.id).to(equal(accepted.first?.attempt.id))
            expect(routingStarted.first?.attempt.id).to(equal(accepted.first?.attempt.id))
            expect(received.first?.triggerEvent).to(equal("upgrade_tapped"))
            expect(accepted.first?.occurredAt).to(equal(received.first?.startedAt))
            expect(routingStarted.first?.occurredAt).to(equal(accepted.first?.occurredAt))

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
                .artifactAcquisition,
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
            let authentication = context.begin(.descriptorAuthentication)
            context.fail(
                authentication,
                error: ExperienceReleaseDescriptorAuthenticationError.invalidSignature,
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
            expect(snapshot.events[1].work).to(equal("artifact_acquisition"))
            expect(snapshot.events[1].durationMilliseconds).to(equal(1_250))
            expect(snapshot.events[1].attributes["source"]).to(equal("download"))
            expect(snapshot.events[3].work).to(equal("descriptor_authentication"))
            expect(snapshot.events[3].durationMilliseconds).to(equal(2_500))
            expect(snapshot.events[3].errorCode).to(equal("experience_release.signature.bad_signature"))
        }

        it("classifies every resilience failure outcome for qualification telemetry") {
            let recorder = InMemoryExperiencePresentationTrace()
            let context = ExperiencePresentationTraceContext(
                attempt: .make(triggerEvent: "resilience_failure", startedAt: Date()),
                recorder: recorder
            )
            let cases: [
                (ExperiencePresentationWork, Error, ExperiencePresentationFailureCategory)
            ] = [
                (.descriptorAuthentication,
                 ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor,
                 .descriptor),
                (.descriptorAuthentication,
                 ExperienceReleaseDescriptorAuthenticationError.invalidSignature,
                 .trust),
                (.artifactAcquisition, URLError(.notConnectedToInternet), .network),
                (.artifactAcquisition, QualificationCacheFailure(), .cache),
                (.storeKitProductLookup, StoreKitError.networkUnavailable, .product),
                (.runtimePreparation, QualificationPreparationFailure(), .preparation),
                (.displayPresentation, QualificationDrawableFailure(), .drawable),
                (.displayPresentation, QualificationAbandonmentFailure(), .userAbandonment),
            ]

            for (work, error, _) in cases {
                context.fail(context.begin(work), error: error)
            }

            let categories = recorder.events().compactMap { event -> String? in
                guard case .workFailed(_, _, _, _, let attributes) = event.stage else {
                    return nil
                }
                return attributes["failure_category"]
            }
            expect(categories).to(equal(cases.map { $0.2.rawValue }))
        }

        it("attributes trigger routing through the presentation request") {
            let recorder = InMemoryExperiencePresentationTrace()
            let attempt = ExperiencePresentationAttempt(
                id: "attempt-routing",
                triggerEvent: "upgrade_tapped",
                startedAt: Date(timeIntervalSince1970: 10),
                startedAtMonotonicTime: 100
            )
            let context = ExperiencePresentationTraceContext(
                attempt: attempt,
                recorder: recorder
            )
            let acceptedAt = ExperiencePresentationTimestamp(
                wallClock: attempt.startedAt,
                monotonicTime: 100
            )
            let requestedAt = ExperiencePresentationTimestamp(
                wallClock: Date(timeIntervalSince1970: 10.08),
                monotonicTime: 100.08
            )

            context.recordTriggerAcceptedAndBeginRouting(at: acceptedAt)
            context.recordPresentationRequested(
                experienceVersionId: "experience-v1",
                route: .journey,
                at: requestedAt
            )
            context.recordPresentationRequested(
                experienceVersionId: "experience-v2",
                route: .journey,
                at: requestedAt
            )
            context.completeTriggerRouting(at: requestedAt)

            let snapshot = recorder.qualificationSnapshot(for: attempt.id)
            expect(snapshot.events.map(\.stage)).to(equal([
                "trigger_accepted",
                "work_started",
                "presentation_requested",
                "work_completed",
                "presentation_requested",
            ]))
            expect(snapshot.events[1].work).to(equal("trigger_routing"))
            expect(snapshot.events[3].work).to(equal("trigger_routing"))
            expect(snapshot.events[3].durationMilliseconds).to(beCloseTo(80, within: 0.001))
            expect(snapshot.events.filter { $0.work == "trigger_routing" })
                .to(haveCount(2))
        }

        it("terminates trigger routing when no presentation is requested") {
            let recorder = InMemoryExperiencePresentationTrace()
            let attempt = ExperiencePresentationAttempt(
                id: "attempt-no-presentation",
                triggerEvent: "upgrade_tapped",
                startedAt: Date(timeIntervalSince1970: 10),
                startedAtMonotonicTime: 100
            )
            let context = ExperiencePresentationTraceContext(
                attempt: attempt,
                recorder: recorder,
                wallClock: { Date(timeIntervalSince1970: 10.04) },
                monotonicClock: { 100.04 }
            )

            context.recordTriggerAcceptedAndBeginRouting(
                at: ExperiencePresentationTimestamp(
                    wallClock: attempt.startedAt,
                    monotonicTime: 100
                )
            )
            context.completeTriggerRouting()

            let routingEvents = recorder.qualificationSnapshot(for: attempt.id)
                .events.filter { $0.work == "trigger_routing" }
            expect(routingEvents.map(\.stage)).to(equal([
                "work_started",
                "work_completed",
            ]))
            expect(routingEvents[1].durationMilliseconds).to(beCloseTo(40, within: 0.001))
        }

        it("anchors display presentation work to the physical drawable timestamp") {
            let recorder = InMemoryExperiencePresentationTrace()
            let attempt = ExperiencePresentationAttempt(
                id: "attempt-display",
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

            let span = context.begin(.displayPresentation)
            context.completeDisplayPresentation(
                span,
                presentedMonotonicTime: 200.075,
                observedAt: ExperiencePresentationTimestamp(
                    wallClock: Date(timeIntervalSince1970: 20.1),
                    monotonicTime: 200.1
                )
            )

            let snapshot = recorder.qualificationSnapshot(for: attempt.id)
            expect(snapshot.events.map(\.work)).to(equal([
                "display_presentation",
                "display_presentation",
            ]))
            expect(snapshot.events[1].monotonicTime).to(equal(200.075))
            expect(snapshot.events[1].durationMilliseconds).to(beCloseTo(75, within: 0.001))
        }

    }
}

private struct QualificationCacheFailure: Error,
    ExperiencePresentationFailureCategorizing
{
    let presentationFailureCategory: ExperiencePresentationFailureCategory = .cache
}

private struct QualificationPreparationFailure: Error {}
private struct QualificationDrawableFailure: Error {}
private struct QualificationAbandonmentFailure: Error,
    ExperiencePresentationFailureCategorizing
{
    let presentationFailureCategory: ExperiencePresentationFailureCategory = .userAbandonment
}
