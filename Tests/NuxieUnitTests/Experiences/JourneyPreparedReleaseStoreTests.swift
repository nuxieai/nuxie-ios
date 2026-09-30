#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieRuntime
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

/// The shared prepared-release store, driven with real native preparation of
/// a small state scene. Releases are named by one hex letter; each release's
/// descriptor SHA-256 repeats that letter, so queue order is name order.
final class JourneyPreparedReleaseStoreTests: JourneyTestCase {
    private var base: JourneyProfileCatalog.Snapshot!
    private var template: AuthenticatedJourneyRelease!
    private var basePayload: AuthenticatedRuntimePayload!
    private var sceneURL: URL!
    private var stores: [JourneyPreparedReleaseStore] = []

    override func setUp() async throws {
        try await super.setUp()
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        base = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(base.profile.armedLegs.first)
        template = try XCTUnwrap(base.releasesByDigest[arm.reference.descriptorSha256])
        XCTAssertNotNil(template.descriptor.render)
        basePayload = try await statePayload(defaultViewModelName: "Test")
        sceneURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prepared-release-scene-\(UUID().uuidString).riv")
    }

    override func tearDown() async throws {
        for store in stores { await store.shutdown() }
        stores.removeAll()
        try await super.tearDown()
    }

    // MARK: - Lane

    func testLanePreparesOneReleaseAtATime() async throws {
        let gate = ConcurrencyProbeGate(holding: .all)
        let store = makeStore(gate)
        let keys = ["A", "B", "C", "D", "E"]

        await store.replaceProfile(
            prepared(keys),
            owner: PreparedReleaseOwner(distinctId: "u1"),
            generation: 1,
            admission: nil
        )
        for count in 1...keys.count {
            await gate.waitForStarts(count)
            await gate.releaseNext()
        }
        await store.waitForIdle()

        let maximumActive = await gate.maximumActiveCount
        XCTAssertEqual(maximumActive, 1)
        let startLog = await gate.startLog
        XCTAssertEqual(startLog, keys)
        for key in keys {
            let status = await store.cache.status(for: sha(key))
            XCTAssertEqual(status, .prepared, key)
        }
    }

    func testSeededReleasesLaneReadsNoObjects() async throws {
        let gate = ConcurrencyProbeGate()
        let acquirer = makeAcquirer()
        let store = makeStore(gate, acquirer: acquirer)
        let keys = ["A", "B", "C"]

        await store.replaceProfile(
            prepared(keys),
            owner: PreparedReleaseOwner(distinctId: "u1"),
            generation: 1,
            admission: nil
        )
        await store.waitForIdle()

        let acquisitions = await acquirer.starts
        XCTAssertEqual(acquisitions, [])
        for key in keys {
            let status = await store.cache.status(for: sha(key))
            XCTAssertEqual(status, .prepared, key)
        }
    }

    func testTriggerForWaitingReleaseStartsNowAndLaneSkipsIt() async throws {
        let gate = ConcurrencyProbeGate(holding: .keys(["A"]))
        let store = makeStore(gate)
        await store.replaceProfile(
            prepared(["A", "B", "C"]),
            owner: PreparedReleaseOwner(distinctId: "u1"),
            generation: 1,
            admission: nil
        )
        await gate.waitForStarts(1)

        let artifact = try await presentationArtifact("C", from: store)
        XCTAssertEqual(artifact.preparedReleaseOutcome, .jumped)
        _ = try await artifact.interactivePreparation.preparation()
        await gate.release("A")
        await store.waitForIdle()

        let startLog = await gate.startLog
        XCTAssertEqual(startLog, ["A", "C", "B"])
        let metrics = await store.cache.metrics()
        XCTAssertEqual(metrics.configuredPreparationCount, 3)
    }

    func testTriggerJoinsInFlightPreparation() async throws {
        let gate = ConcurrencyProbeGate(holding: .keys(["A"]))
        let store = makeStore(gate)
        await store.replaceProfile(
            prepared(["A"]),
            owner: PreparedReleaseOwner(distinctId: "u1"),
            generation: 1,
            admission: nil
        )
        await gate.waitForStarts(1)

        let artifact = try await presentationArtifact("A", from: store)
        XCTAssertEqual(artifact.preparedReleaseOutcome, .joined)
        async let triggerPreparation = artifact.interactivePreparation.preparation()
        await gate.release("A")
        let joined = try await triggerPreparation
        await store.waitForIdle()

        let lanePreparation = try await cachedPreparation("A", in: store)
        XCTAssertTrue(joined === lanePreparation)
        let starts = await gate.startCount(of: "A")
        XCTAssertEqual(starts, 1)
    }

    // MARK: - Profiles

    func testProfileChangeRetainsArmedDropsRestQueuesNew() async throws {
        let gate = ConcurrencyProbeGate()
        let store = makeStore(gate)
        await store.replaceProfile(
            prepared(["A", "B"]),
            owner: PreparedReleaseOwner(distinctId: "u1"),
            generation: 1,
            admission: nil
        )
        await store.waitForIdle()
        let retainedBefore = try await cachedPreparation("B", in: store)

        await store.replaceProfile(
            prepared(["B", "C"]),
            owner: PreparedReleaseOwner(distinctId: "u1"),
            generation: 2,
            admission: nil
        )
        await store.waitForIdle()

        let dropped = await store.cache.status(for: sha("A"))
        XCTAssertEqual(dropped, .miss)
        let retainedAfter = try await cachedPreparation("B", in: store)
        XCTAssertTrue(retainedBefore === retainedAfter)
        let retainedStarts = await gate.startCount(of: "B")
        XCTAssertEqual(retainedStarts, 1)
        let queued = await store.cache.status(for: sha("C"))
        XCTAssertEqual(queued, .prepared)
    }

    func testIdenticalRecommitKeepsInFlightWork() async throws {
        let gate = ConcurrencyProbeGate(holding: .keys(["A"]))
        let store = makeStore(gate)
        await store.replaceProfile(
            prepared(["A"]),
            owner: PreparedReleaseOwner(distinctId: "u1"),
            generation: 1,
            admission: nil
        )
        await gate.waitForStarts(1)

        await store.replaceProfile(
            prepared(["A"]),
            owner: PreparedReleaseOwner(distinctId: "u1"),
            generation: 2,
            admission: nil
        )
        await gate.release("A")
        await store.waitForIdle()

        let starts = await gate.startCount(of: "A")
        XCTAssertEqual(starts, 1)
        let cancelled = await gate.cancelledKeys
        XCTAssertEqual(cancelled, [])
        let status = await store.cache.status(for: sha("A"))
        XCTAssertEqual(status, .prepared)
    }

    func testReservationKeepsDroppedReleaseUntilShowEnds() async throws {
        let gate = ConcurrencyProbeGate()
        let store = makeStore(gate)
        await store.replaceProfile(
            prepared(["A"]),
            owner: PreparedReleaseOwner(distinctId: "u1"),
            generation: 1,
            admission: nil
        )
        await store.waitForIdle()

        let (reservation, readiness) = await store.reserve(descriptorSHA256: sha("A"))
        XCTAssertEqual(readiness, .prepared)
        await store.replaceProfile(
            prepared(["B"]),
            owner: PreparedReleaseOwner(distinctId: "u1"),
            generation: 2,
            admission: nil
        )
        await store.waitForIdle()
        let heldStatus = await store.cache.status(for: sha("A"))
        XCTAssertEqual(heldStatus, .prepared)

        reservation.release()
        await store.waitForIdle()
        let released = await eventually { await store.cache.status(for: self.sha("A")) == .miss }
        XCTAssertTrue(released, "A release dropped from the profile must go when its show ends")
    }

    func testStaleGenerationRefusedAdmissionAndNilSnapshot() async throws {
        let store = makeStore(ConcurrencyProbeGate(), automaticPreparation: false)
        await store.replaceProfile(
            prepared(["A", "B"]),
            owner: PreparedReleaseOwner(distinctId: "u1"),
            generation: 2,
            admission: nil
        )
        let current = await store.inspection()
        XCTAssertEqual(current.armed, [sha("A"), sha("B")])
        XCTAssertEqual(current.pending, [sha("A"), sha("B")])

        await store.replaceProfile(
            prepared(["C"]),
            owner: PreparedReleaseOwner(distinctId: "u1"),
            generation: 1,
            admission: nil
        )
        let afterStale = await store.inspection()
        XCTAssertEqual(afterStale, current)

        await store.replaceProfile(
            prepared(["D"]),
            owner: PreparedReleaseOwner(distinctId: "u1"),
            generation: 3,
            admission: ProfileSideEffectAdmission { false }
        )
        let afterRefused = await store.inspection()
        XCTAssertEqual(afterRefused, current)

        let (reservation, _) = await store.reserve(descriptorSHA256: sha("A"))
        await store.replaceProfile(
            PreparedJourneyProfileArtifacts(snapshot: nil),
            owner: PreparedReleaseOwner(distinctId: "u1"),
            generation: 4,
            admission: nil
        )
        let afterWithdrawal = await store.inspection()
        XCTAssertEqual(afterWithdrawal.armed, [])
        XCTAssertEqual(afterWithdrawal.pending, [])
        XCTAssertEqual(afterWithdrawal.entries, [sha("A")])
        reservation.release()
    }

    // MARK: - Users

    func testUserSwitchDiscardsQueuedInFlightAndPreparedButNotNewOwner() async throws {
        let acquisitionGate = ConcurrencyProbeGate(holding: .keys([sha("A")]))
        let acquirer = makeAcquirer(gate: acquisitionGate)
        let store = makeStore(ConcurrencyProbeGate(), acquirer: acquirer)
        await store.replaceProfile(
            prepared(["A", "B"], seeded: []),
            owner: PreparedReleaseOwner(distinctId: "u1"),
            generation: 1,
            admission: nil
        )
        await acquisitionGate.waitForStarts(1)

        await store.discard(departingDistinctId: "u1")
        await acquisitionGate.open()
        await store.waitForIdle()
        try await Task.sleep(nanoseconds: 100_000_000)

        for key in ["A", "B"] {
            let status = await store.cache.status(for: sha(key))
            XCTAssertEqual(status, .miss, key)
        }
        let queuedAcquisitions = await acquirer.startCount(of: sha("B"))
        XCTAssertEqual(queuedAcquisitions, 0, "A discarded queue must never start")
        let discarded = await store.inspection()
        XCTAssertNil(discarded.ownerDistinctId)
        XCTAssertEqual(discarded.entries, [])

        let arriving = makeStore(ConcurrencyProbeGate())
        await arriving.replaceProfile(
            prepared(["A"]),
            owner: PreparedReleaseOwner(distinctId: "u2"),
            generation: 1,
            admission: nil
        )
        await arriving.waitForIdle()
        let arrived = await arriving.inspection()
        await arriving.discard(departingDistinctId: "u1")
        let afterLateDiscard = await arriving.inspection()
        XCTAssertEqual(afterLateDiscard, arrived)
        XCTAssertEqual(afterLateDiscard.ownerDistinctId, "u2")
        let kept = await arriving.cache.status(for: sha("A"))
        XCTAssertEqual(kept, .prepared)
    }

    /// Decision 16: a first sign-in keeps everything prepared, whether the
    /// queued user transition or the signed-in user's profile reaches the
    /// store first. That profile still drops what it no longer arms.
    func testFirstSignInKeepsPreparedReleasesInEitherOrder() async throws {
        for transitionFirst in [true, false] {
            let order = transitionFirst ? "transition first" : "profile first"
            let gate = ConcurrencyProbeGate()
            let acquirer = makeAcquirer()
            let store = makeStore(gate, acquirer: acquirer)
            await store.replaceProfile(
                prepared(["A", "B"]),
                owner: PreparedReleaseOwner(distinctId: "anon"),
                generation: 1,
                admission: nil
            )
            await store.waitForIdle()
            let anonymousPreparation = try await cachedPreparation("A", in: store)

            let signedIn = PreparedReleaseOwner(
                distinctId: "u1",
                signedInFromAnonymousId: "anon"
            )
            if transitionFirst {
                await store.transferOwner(from: "anon", to: "u1")
            }
            await store.replaceProfile(
                prepared(["A", "C"]),
                owner: signedIn,
                generation: 2,
                admission: nil
            )
            if !transitionFirst {
                await store.transferOwner(from: "anon", to: "u1")
            }
            await store.waitForIdle()

            let kept = try await cachedPreparation("A", in: store)
            XCTAssertTrue(kept === anonymousPreparation, order)
            let startLog = await gate.startLog
            XCTAssertEqual(startLog, ["A", "B", "C"], "\(order): nothing prepared twice")
            let acquisitions = await acquirer.starts
            XCTAssertEqual(acquisitions, [], order)
            let unarmed = await store.cache.status(for: sha("B"))
            XCTAssertEqual(unarmed, .miss, order)
            let queued = await store.cache.status(for: sha("C"))
            XCTAssertEqual(queued, .prepared, order)
            let owner = await store.inspection().ownerDistinctId
            XCTAssertEqual(owner, "u1", order)
        }
    }

    /// A switch between identified users and a reset both discard, whether
    /// the transition's discard or the arriving user's profile reaches the
    /// store first. A discard that arrives after the arriving user's commit
    /// leaves that user's releases alone.
    func testIdentifiedSwitchAndResetDiscardInEitherOrder() async throws {
        for transitionFirst in [true, false] {
            let order = transitionFirst ? "transition first" : "profile first"
            let gate = ConcurrencyProbeGate()
            let store = makeStore(gate)
            await store.replaceProfile(
                prepared(["A"]),
                owner: PreparedReleaseOwner(distinctId: "u1", signedInFromAnonymousId: "anon"),
                generation: 1,
                admission: nil
            )
            await store.waitForIdle()
            let firstUserPreparation = try await cachedPreparation("A", in: store)

            // An identified user keeps the device's anonymous id, so the
            // arriving user reports the same sign-in origin as the departing one.
            let arrivals: [(departing: String, arriving: PreparedReleaseOwner)] = [
                ("u1", PreparedReleaseOwner(distinctId: "u2", signedInFromAnonymousId: "anon")),
                ("u2", PreparedReleaseOwner(distinctId: "anon-2")),
            ]
            var previous = firstUserPreparation
            for (index, arrival) in arrivals.enumerated() {
                let step = "\(order), \(arrival.departing) -> \(arrival.arriving.distinctId)"
                if transitionFirst {
                    await store.discard(departingDistinctId: arrival.departing)
                }
                await store.replaceProfile(
                    prepared(["A"]),
                    owner: arrival.arriving,
                    generation: UInt64(index + 2),
                    admission: nil
                )
                if !transitionFirst {
                    await store.discard(departingDistinctId: arrival.departing)
                }
                await store.waitForIdle()

                let current = try await cachedPreparation("A", in: store)
                XCTAssertFalse(current === previous, step)
                let starts = await gate.startCount(of: "A")
                XCTAssertEqual(starts, index + 2, step)
                let owner = await store.inspection().ownerDistinctId
                XCTAssertEqual(owner, arrival.arriving.distinctId, step)
                previous = current
            }
        }
    }

    /// The anonymous user signed in as u1 and then switched to u2 before
    /// either transition ran. u2's profile looks like a first sign-in and
    /// keeps everything, until the first transition reports that the
    /// anonymous user signed in as u1: u2 is a switch, so everything goes.
    func testSignInClaimedByLaterUserDiscardsWhenTransitionArrives() async throws {
        let gate = ConcurrencyProbeGate()
        let store = makeStore(gate)
        await store.replaceProfile(
            prepared(["A"]),
            owner: PreparedReleaseOwner(distinctId: "anon"),
            generation: 1,
            admission: nil
        )
        await store.waitForIdle()
        let anonymousPreparation = try await cachedPreparation("A", in: store)

        await store.replaceProfile(
            prepared(["A"]),
            owner: PreparedReleaseOwner(distinctId: "u2", signedInFromAnonymousId: "anon"),
            generation: 2,
            admission: nil
        )
        await store.waitForIdle()
        let provisionallyKept = try await cachedPreparation("A", in: store)
        XCTAssertTrue(provisionallyKept === anonymousPreparation)

        await store.transferOwner(from: "anon", to: "u1")
        await store.discard(departingDistinctId: "u1")

        let dropped = await store.cache.status(for: sha("A"))
        XCTAssertEqual(dropped, .miss)
        let discarded = await store.inspection()
        XCTAssertNil(discarded.ownerDistinctId)
        XCTAssertEqual(discarded.entries, [])
        XCTAssertEqual(discarded.armed, [])

        // The transition then admits u2's profile again.
        await store.replaceProfile(
            prepared(["A"]),
            owner: PreparedReleaseOwner(distinctId: "u2", signedInFromAnonymousId: "anon"),
            generation: 3,
            admission: nil
        )
        await store.waitForIdle()
        let rebuilt = try await cachedPreparation("A", in: store)
        XCTAssertFalse(rebuilt === anonymousPreparation)
        let starts = await gate.startCount(of: "A")
        XCTAssertEqual(starts, 2)
    }

    // MARK: - App lifecycle

    func testBackgroundStartsNothingAndActiveResumes() async throws {
        let gate = ConcurrencyProbeGate(holding: .keys(["A"]))
        let store = makeStore(gate)
        await store.replaceProfile(
            prepared(["A", "B"]),
            owner: PreparedReleaseOwner(distinctId: "u1"),
            generation: 1,
            admission: nil
        )
        await gate.waitForStarts(1)

        store.gate.enterBackground()
        await gate.release("A")
        await store.waitForIdle()

        let completed = try await cachedPreparation("A", in: store)
        let pausedLog = await gate.startLog
        XCTAssertEqual(pausedLog, ["A"])
        let paused = await store.cache.status(for: sha("B"))
        XCTAssertEqual(paused, .miss)

        await store.onAppBecameActive()
        await store.waitForIdle()

        let resumedLog = await gate.startLog
        XCTAssertEqual(resumedLog, ["A", "B"])
        let resumed = await store.cache.status(for: sha("B"))
        XCTAssertEqual(resumed, .prepared)
        let kept = try await cachedPreparation("A", in: store)
        XCTAssertTrue(completed === kept)
    }

    func testMemoryWarningKeepsPreparedReleases() async throws {
        let gate = ConcurrencyProbeGate()
        let cache = probedPreparationCache(gate)
        let service = ExperienceService(
            productService: ProductService(),
            eventLog: MockEventLog(),
            transactionServiceProvider: {
                fatalError("preparation needs no transaction service")
            },
            systemEventSink: DiscardingSystemEventSink(),
            releaseStore: makeAcquirer(),
            automaticPreparation: true,
            preparationCache: cache
        )
        stores.append(service.preparedReleaseStore)
        await service.preparedReleaseStore.replaceProfile(
            prepared(["A"]),
            owner: PreparedReleaseOwner(distinctId: "u1"),
            generation: 1,
            admission: nil
        )
        await service.waitForPreparationIdle()
        let before = try await cachedPreparation("A", in: service.preparedReleaseStore)
        let metricsBefore = await cache.metrics()
        let startsBefore = await gate.startLog

        service.didReceiveMemoryWarning()
        await service.waitForPreparationIdle()

        XCTAssertTrue(service.preparedReleaseStore.gate.snapshot().builtScreensDeferred)
        let status = await cache.status(for: sha("A"))
        XCTAssertEqual(status, .prepared)
        let after = try await cachedPreparation("A", in: service.preparedReleaseStore)
        XCTAssertTrue(before === after)
        let metricsAfter = await cache.metrics()
        XCTAssertEqual(metricsAfter, metricsBefore)
        let startsAfter = await gate.startLog
        XCTAssertEqual(startsAfter, startsBefore)
    }

    func testShutdownCancelsLaneAndDrops() async throws {
        let gate = ConcurrencyProbeGate(holding: .all)
        let store = makeStore(gate)
        await store.replaceProfile(
            prepared(["A", "B"]),
            owner: PreparedReleaseOwner(distinctId: "u1"),
            generation: 1,
            admission: nil
        )
        await gate.waitForStarts(1)

        await store.shutdown()

        let observedCancellation = await eventually { await gate.cancelledKeys == ["A"] }
        XCTAssertTrue(observedCancellation, "The gated preparation must observe cancellation")
        for key in ["A", "B"] {
            let status = await store.cache.status(for: sha(key))
            XCTAssertEqual(status, .miss, key)
        }
        await store.replaceProfile(
            prepared(["C"]),
            owner: PreparedReleaseOwner(distinctId: "u1"),
            generation: 2,
            admission: nil
        )
        await store.onAppBecameActive()
        await store.waitForIdle()
        try await Task.sleep(nanoseconds: 50_000_000)
        let startLog = await gate.startLog
        XCTAssertEqual(startLog, ["A"])
        let afterShutdown = await store.cache.status(for: sha("C"))
        XCTAssertEqual(afterShutdown, .miss)
    }

    // MARK: - Cross-SDK readiness vector

    func testReserveReadinessMatchesPresentationReadinessVector() async throws {
        struct Vector: Decodable {
            struct Case: Decodable {
                let name: String
                let verifiedRelease: Bool
                let nativePreparation: String
                let readiness: String
            }
            let cases: [Case]
        }
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf:
            experiencePreparationRepositoryRoot()
                .appendingPathComponent("fixtures/journeys/planes/presentation-readiness.json")))
        XCTAssertFalse(vector.cases.isEmpty)
        for vectorCase in vector.cases {
            let gate = ConcurrencyProbeGate(holding: .all)
            let store = makeStore(gate, automaticPreparation: false)
            await store.replaceProfile(
                prepared(["A"], seeded: vectorCase.verifiedRelease ? ["A"] : []),
                owner: PreparedReleaseOwner(distinctId: "u1"),
                generation: 1,
                admission: nil
            )
            let payload = try XCTUnwrap(runtime("A").preparationPayload)
            let handle = ExperienceInteractivePreparationHandle(
                cache: store.cache,
                provenance: sha("A"),
                payload: payload
            )
            let nativePreparation = try XCTUnwrap(
                ExperienceInteractivePreparationCacheStatus(
                    rawValue: vectorCase.nativePreparation
                ),
                vectorCase.name
            )
            var preparation: Task<Void, Never>?
            switch nativePreparation {
            case .miss:
                break
            case .preparing:
                preparation = Task { _ = try? await handle.preparation() }
                await gate.waitForStarts(1)
            case .prepared:
                await gate.open()
                _ = try await handle.preparation()
            }
            let status = await store.cache.status(for: sha("A"))
            XCTAssertEqual(status, nativePreparation, vectorCase.name)

            let (reservation, readiness) = await store.reserve(descriptorSHA256: sha("A"))
            XCTAssertEqual(readiness.rawValue, vectorCase.readiness, vectorCase.name)
            reservation.release()
            await gate.open()
            await preparation?.value
        }
    }

    // MARK: - Helpers

    private func sha(_ key: String) -> String {
        String(repeating: key.lowercased(), count: 64)
    }

    private func release(_ key: String) -> AuthenticatedJourneyRelease {
        AuthenticatedJourneyRelease(
            authenticatedKeyID: template.authenticatedKeyID,
            exactDescriptorBytes: template.exactDescriptorBytes,
            descriptorSHA256: sha(key),
            descriptor: template.descriptor,
            publishedAtSeqToPromote: nil
        )
    }

    /// A verified runtime release whose native preparation is keyed by `key`.
    private func runtime(_ key: String) -> PreparedRuntimeRelease {
        let plan = basePayload.renderPlan
        let payload = AuthenticatedRuntimePayload(
            authenticatedKeyID: basePayload.authenticatedKeyID,
            renderPlan: NativeExperienceRenderPlan(
                identity: .init(
                    experienceId: key,
                    buildId: plan.identity.buildId,
                    appId: plan.identity.appId,
                    environment: plan.identity.environment
                ),
                scene: plan.scene,
                entry: plan.entry,
                screens: plan.screens,
                transitions: plan.transitions,
                textInputs: plan.textInputs,
                images: plan.images,
                fonts: plan.fonts
            ),
            journey: basePayload.journey,
            sceneBytes: basePayload.sceneBytes,
            assets: basePayload.assets
        )
        return PreparedRuntimeRelease(
            payloadsByScreenID: [plan.entry.screenId: payload],
            objectURLsByKey: [plan.scene.key: sceneURL],
            source: .cache,
            resourceMetrics: .zero
        )
    }

    private func snapshot(_ keys: [String]) -> JourneyProfileCatalog.Snapshot {
        let baseArm = base.profile.armedLegs[0]
        let arms = keys.map { key in
            ArmedJourney(
                reference: .init(
                    experienceId: baseArm.reference.experienceId,
                    versionId: baseArm.reference.versionId,
                    legId: baseArm.reference.legId,
                    descriptorSha256: sha(key)
                ),
                binding: baseArm.binding,
                entryCondition: baseArm.entryCondition,
                context: baseArm.context
            )
        }
        let profile = JourneyPlaneProfile(
            schemaVersion: base.profile.schemaVersion,
            status: base.profile.status,
            delivery: base.profile.delivery,
            features: base.profile.features,
            facts: base.profile.facts,
            armedLegs: arms,
            releases: base.profile.releases
        )
        return .init(
            profile: profile,
            releasesByDigest: Dictionary(uniqueKeysWithValues: keys.map {
                (sha($0), release($0))
            })
        )
    }

    /// A committed profile arming `keys`. Admission already verified the
    /// releases in `seeded` (every key by default), so the store holds their
    /// bytes without reading objects.
    private func prepared(
        _ keys: [String],
        seeded: Set<String>? = nil
    ) -> PreparedJourneyProfileArtifacts {
        PreparedJourneyProfileArtifacts(
            snapshot: snapshot(keys),
            runtimeReleasesByDescriptorSHA256: Dictionary(
                uniqueKeysWithValues: (seeded ?? Set(keys)).map {
                    (sha($0), runtime($0))
                }
            )
        )
    }

    private func makeAcquirer(
        gate: ConcurrencyProbeGate = ConcurrencyProbeGate()
    ) -> RecordingJourneyReleaseAcquirer {
        RecordingJourneyReleaseAcquirer(
            runtimes: Dictionary(uniqueKeysWithValues: ["A", "B", "C", "D", "E"].map {
                (sha($0), runtime($0))
            }),
            gate: gate
        )
    }

    private func makeStore(
        _ gate: ConcurrencyProbeGate,
        acquirer: RecordingJourneyReleaseAcquirer? = nil,
        automaticPreparation: Bool = true
    ) -> JourneyPreparedReleaseStore {
        let store = JourneyPreparedReleaseStore(
            acquirer: acquirer ?? makeAcquirer(),
            cache: probedPreparationCache(gate),
            gate: ExperiencePreparationGate(),
            automaticPreparation: automaticPreparation
        )
        stores.append(store)
        return store
    }

    private func presentationArtifact(
        _ key: String,
        from store: JourneyPreparedReleaseStore
    ) async throws -> AcquiredExperienceArtifact {
        try await store.presentationArtifact(
            release: release(key),
            delivery: base.profile.delivery,
            pinnedArtifacts: nil,
            screenID: basePayload.renderPlan.entry.screenId,
            identity: .init(experienceId: key, buildId: "build"),
            productResolver: { _ in [] }
        )
    }

    /// The prepared native preparation for `key`, without starting another.
    private func cachedPreparation(
        _ key: String,
        in store: JourneyPreparedReleaseStore
    ) async throws -> ExperienceInteractivePreparation {
        let status = await store.cache.status(for: sha(key))
        XCTAssertEqual(status, .prepared, key)
        return try await store.cache.preparation(
            provenance: sha(key),
            payload: try XCTUnwrap(runtime(key).preparationPayload)
        )
    }

    private func eventually(
        timeout: TimeInterval = 2,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }
}
#endif
