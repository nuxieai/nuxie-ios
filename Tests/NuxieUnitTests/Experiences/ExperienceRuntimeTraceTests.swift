import Foundation
import Quick
import Nimble
import NuxieRuntime
import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class ExperienceRuntimeTraceTests: AsyncSpec {
    override class func spec() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        describe("a prepared show") {
            it("begins runtime preparation prepared and parses nothing") { @MainActor in
                try await Self.verifyPreparedShowRuntimePreparation()
            }
        }
        #endif

        describe("ExperienceRuntimeTraceRecorder") {
            it("records navigation and binding entries in deterministic step order") {
                let recorder = ExperienceRuntimeTraceRecorder()

                recorder.recordNavigation(screenId: "screen-2")
                recorder.recordRendererBindingChange(
                    screenId: "screen-2",
                    path: "path:VM:title",
                    value: ["title": "Hello", "count": 2],
                    source: "input",
                    instanceId: nil
                )
                recorder.recordRendererScreenChanged(
                    screenId: "screen-2"
                )

                let trace = recorder.trace(
                    fixtureId: "fixture-nav-binding",
                    runtime: "native"
                )

                expect(trace.schemaVersion).to(equal(ExperienceRuntimeTrace.currentSchemaVersion))
                expect(trace.entries.map(\.step)).to(equal([1, 2, 3]))

                expect(trace.entries[0].kind).to(equal(.navigation))
                expect(trace.entries[0].name).to(equal("navigate"))
                expect(trace.entries[0].output).to(equal("screen-2"))

                expect(trace.entries[1].kind).to(equal(.binding))
                expect(trace.entries[1].name).to(equal("did_set"))
                expect(trace.entries[1].screenId).to(equal("screen-2"))
                expect(trace.entries[1].output).to(contain("\"path\":\"path:VM:title\""))
                expect(trace.entries[1].output).to(contain("\"title\":\"Hello\""))
                expect(trace.entries[1].metadata?["source"]).to(equal("input"))

                expect(trace.entries[2].kind).to(equal(.navigation))
                expect(trace.entries[2].name).to(equal("screen_changed"))
            }

            it("records event entries with canonicalized properties") {
                let recorder = ExperienceRuntimeTraceRecorder()

                recorder.recordEvent(
                    name: "$experience_shown",
                    properties: [
                        "experience_version": "flow-1",
                        "screen_id": "screen-entry",
                        "nested": ["b": 2, "a": 1],
                    ]
                )

                let trace = recorder.trace(
                    fixtureId: "fixture-events",
                    runtime: "native"
                )
                let entry = trace.entries.first

                expect(entry?.kind).to(equal(.event))
                expect(entry?.name).to(equal("$experience_shown"))
                expect(entry?.screenId).to(equal("screen-entry"))
                expect(entry?.output).to(equal("{\"experience_version\":\"flow-1\",\"nested\":{\"a\":1,\"b\":2},\"screen_id\":\"screen-entry\"}"))
            }

            it("ingests tracked events and supports codable round-trip") {
                let recorder = ExperienceRuntimeTraceRecorder()
                recorder.ingestTrackedEvents([
                    (name: "$experience_artifact_load_succeeded", properties: ["experience_version": "flow-abc"]),
                    (name: "$experience_dismissed", properties: ["experience_version": "flow-abc"]),
                ])

                let trace = recorder.trace(
                    fixtureId: "fixture-round-trip",
                    runtime: "native"
                )

                let data = try! JSONEncoder().encode(trace)
                let decoded = try! JSONDecoder().decode(ExperienceRuntimeTrace.self, from: data)

                expect(decoded).to(equal(trace))
                expect(decoded.entries.map(\.kind)).to(equal([.event, .event]))
            }

            it("records renderer screen change notifications") {
                let recorder = ExperienceRuntimeTraceRecorder()

                recorder.recordRendererScreenChanged(
                    screenId: "screen-2"
                )

                let trace = recorder.trace(
                    fixtureId: "fixture-screen-changed",
                    runtime: "native"
                )
                guard let entry = trace.entries.first else {
                    fail("Expected at least one trace entry")
                    return
                }

                expect(entry.kind).to(equal(.navigation))
                expect(entry.name).to(equal("screen_changed"))
                expect(entry.screenId).to(equal("screen-2"))
            }
        }
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// A real ExperienceService prepares a signed release in the background;
    /// the show's runtime_preparation span must then begin prepared, with
    /// readiness prepared, and complete having parsed no bytes. This is the
    /// parent qualification's memory-warm check.
    @MainActor
    private static func verifyPreparedShowRuntimePreparation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prepared-show-trace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            StubURLProtocol.reset()
            try? FileManager.default.removeItem(at: directory)
        }
        let fixture = experiencePreparationRepositoryRoot()
            .appendingPathComponent("Tests/ExperienceRuntimeHostApp/Fixtures/multi-screen")
        let snapshot = try await authenticatedFixtureSnapshot(at: fixture)
        let release = try XCTUnwrap(snapshot.releasesByDigest.values.first)
        let screenID = try XCTUnwrap(release.descriptor.leg.screens.first?.id)
        let products = MockProductService()
        let sink = DiscardingSystemEventSink()
        let eventLog = MockEventLog()
        let transactions = TransactionService(
            productService: products,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            dateProvider: MockDateProvider(),
            settings: NuxieRuntimeSettings(
                configuration: NuxieConfiguration(apiKey: "test-api-key")
            ),
            eventSink: sink
        )
        let experiences = ExperienceService(
            productService: products,
            eventLog: eventLog,
            transactionServiceProvider: { transactions },
            systemEventSink: sink,
            releaseStore: JourneyReleaseAcquisitionStore(
                cacheDirectory: directory,
                urlSession: TestURLSessionProvider.createTestSession()
            ),
            automaticPreparation: true
        )
        let preparedProfile = try await experiences.prepareJourneyProfile(snapshot)
        let committed = await experiences.commitJourneyProfile(
            preparedProfile,
            owner: PreparedReleaseOwner(distinctId: "customer"),
            generation: 1,
            admission: nil
        )
        expect(committed).to(beTrue())
        await experiences.waitForPreparationIdle()

        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let identityFence = try XCTUnwrap(
            identity.performWithCurrentIdentityFence("customer") { _ in () }
        )
        let executionFence = JourneyProfileFence()
        let service = ExperiencePresentationService(
            windowProvider: MockWindowProvider(),
            experiences: experiences,
            eventLog: eventLog,
            identity: identity
        )
        let recorder = InMemoryExperiencePresentationTrace()
        let result = await service.presentJourney(JourneyPresentationRequest(
            fences: .init(
                identityToken: identityFence.token,
                executionFence: executionFence,
                executionToken: executionFence.token()
            ),
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: screenID,
            owner: .init(journeyId: "prepared-show-journey", distinctId: "customer"),
            reservation: service.reserveJourneyPresentation(ownerDistinctId: "customer"),
            presentationTraceContext: .init(
                attempt: ExperiencePresentationAttempt(
                    id: "prepared-show",
                    triggerEvent: "prepared_show",
                    startedAt: Date(),
                    startedAtMonotonicTime: 0
                ),
                recorder: recorder
            ),
            onEmissionBatch: { _, _ in true },
            onOutcome: { _, _ in true }
        ))
        expect(result).to(equal(.shown))

        func runtimePreparation(started: Bool) -> [String: String]? {
            recorder.events().lazy.compactMap { event -> [String: String]? in
                switch event.stage {
                case .workStarted(_, .runtimePreparation, let attributes) where started:
                    return attributes
                case .workCompleted(_, .runtimePreparation, _, let attributes) where !started:
                    return attributes
                default:
                    return nil
                }
            }.first
        }
        await expect { runtimePreparation(started: false) != nil }
            .toEventually(beTrue(), timeout: .seconds(10))
        let started = try XCTUnwrap(runtimePreparation(started: true))
        expect(started["prepared_riv_status"]).to(equal("prepared"))
        expect(started["readiness"]).to(equal("prepared"))
        let completed = try XCTUnwrap(runtimePreparation(started: false))
        expect(completed["parsed_bytes"]).to(equal("0"))

        await service.dismissCurrentExperienceFromHost()
        await experiences.shutdownPreparation()
    }
    #endif
}
