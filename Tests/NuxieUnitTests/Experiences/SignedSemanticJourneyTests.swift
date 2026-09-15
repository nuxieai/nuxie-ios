#if canImport(UIKit) && NUXIE_HOSTED_INPUT_TESTS
import UIKit
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

/// Hosted UIKit activation, not a claim of VoiceOver traversal qualification.
@MainActor
final class SignedSemanticJourneyTests: XCTestCase {
    func testSignedSemanticActivationPersistsResponsesBeforeAuthoredNavigation() async throws {
        try await exercise(.success)
    }

    func testFailedSignedSemanticActionDoesNotCommitPartialResponses() async throws {
        try await exercise(.scriptFailure)
    }

    func testSignedAuthoredRolesExposeOneSecureEditorAndPersistNativeActions() async throws {
        try await exercise(.roles)
    }

    private enum Scenario: String {
        case roles = "rendered-semantic-roles"
        case success = "rendered-semantic-screen-control"
        case scriptFailure = "rendered-semantic-screen-control-error"
    }

    private func exercise(_ scenario: Scenario) async throws {
        let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
            .appendingPathComponent(scenario.rawValue)
        let entry = try object(at: root.appendingPathComponent("release-entry.json"))
        let provenance = try object(at: root.appendingPathComponent("provenance.json"))
        let locator = try XCTUnwrap(entry["locator"] as? [String: Any])
        let envelope = try XCTUnwrap(entry["envelope"] as? [String: Any])
        let signature = try XCTUnwrap(envelope["signature"] as? [String: Any])
        let keys = [JourneyPackageAuthorizationKey(
            keyID: try XCTUnwrap(signature["keyId"] as? String),
            ed25519PublicKeyBytes: try XCTUnwrap(Data(base64Encoded: XCTUnwrap(provenance["publicKeyBase64"] as? String)))
        )]
        let profile = try JourneyPlaneProfile.decode(JSONSerialization.data(withJSONObject: [
            "schemaVersion": "nuxie.journey-plane-profile.v1", "status": "ok",
            "delivery": ["renderBaseUrl": "https://semantic.sdk-fixtures.nuxie.test/", "assetBaseUrl": "https://semantic.sdk-fixtures.nuxie.test/"],
            "features": [], "facts": ["properties": [:], "memberships": [:], "assignments": [:]],
            "releases": [entry],
            "armedLegs": [[
                "reference": ["experienceId": locator["experienceId"]!, "versionId": locator["experienceVersionId"]!,
                              "legId": locator["legId"]!, "descriptorSha256": envelope["descriptorSha256"]!],
                "binding": ["type": "new"], "entryCondition": ["type": "app_foregrounded"],
                "context": ["event": [:], "responses": [:]],
            ]],
        ]))
        let authority = ProfileDeliveryAuthority(appId: try XCTUnwrap(locator["appId"] as? String), environment: "test")
        let productionCatalog = JourneyProfileCatalog(authorizationKeys: keys,
            supportedRuntime: JourneyReleaseRuntime.current, highWaterStore: InMemoryJourneyReleaseHighWaterStore())
        do {
            _ = try await productionCatalog.prepare(profile, authority: authority)
            XCTFail("Default admission must reject the unqualified semantic capability")
        } catch {
            XCTAssertEqual(error as? JourneyReleaseAuthenticationError, .unsupportedCapabilities(["scene-semantics-v1"]))
        }
        let current = JourneyReleaseRuntime.current
        let candidate = JourneyReleaseSupportedRuntime(currentSdkVersion: current.currentSdkVersion,
            supportedRuntimeRevisions: current.supportedRuntimeRevisions, supportedLuauRevisions: current.supportedLuauRevisions,
            sceneFormat: current.sceneFormat, timezoneDataRevision: current.timezoneDataRevision,
            timezoneDataSHA256: current.timezoneDataSHA256,
            supportedCapabilities: current.supportedCapabilities.union(["scene-semantics-v1"]))
        let catalog = JourneyProfileCatalog(authorizationKeys: keys, supportedRuntime: candidate,
            highWaterStore: InMemoryJourneyReleaseHighWaterStore())
        let prepared = try await catalog.prepare(profile, authority: authority)
        let owner = "semantic-\(UUID().uuidString)"
        let committed = try await catalog.commit(prepared, distinctId: owner)
        XCTAssertTrue(committed)
        let release = try XCTUnwrap(prepared.snapshot.releasesByDigest.values.first)
        XCTAssertEqual(release.descriptorSHA256, provenance["descriptorSha256"] as? String)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(owner)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            StubURLProtocol.reset()
            try? FileManager.default.removeItem(at: directory)
        }
        let requests = FixtureRequests()
        let descriptorBytes = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(envelope["descriptorBytesBase64"] as? String)))
        let descriptorDocument = try XCTUnwrap(JSONSerialization.jsonObject(with: descriptorBytes) as? [String: Any])
        let render = try XCTUnwrap(descriptorDocument["render"] as? [String: Any])
        let references = [try XCTUnwrap(render["riv"] as? [String: Any])]
            + (render["assets"] as? [[String: Any]] ?? [])
            + (descriptorDocument["screenBehaviors"] as? [[String: Any]] ?? []).compactMap {
                ($0["script"] as? [String: Any])?["artifact"] as? [String: Any]
            }
        let contentTypes = try Dictionary(uniqueKeysWithValues: references.map {
            (try XCTUnwrap($0["key"] as? String), try XCTUnwrap($0["contentType"] as? String))
        })
        StubURLProtocol.register(matcher: { $0.url?.host == "semantic.sdk-fixtures.nuxie.test" }) { request in
            let url = try XCTUnwrap(request.url)
            let path = String(url.path.dropFirst())
            let bytes = try Data(contentsOf: root.appendingPathComponent(path))
            requests.record(path)
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                "Content-Type": try XCTUnwrap(contentTypes[path]),
                "Content-Length": String(bytes.count),
            ])!, bytes)
        }
        let acquisition = JourneyReleaseAcquisitionStore(cacheDirectory: directory.appendingPathComponent("artifacts"),
            urlSession: TestURLSessionProvider.createTestSession())
        let configuration = NuxieConfiguration(apiKey: "signed-semantic-qualification")
        configuration.testingOverrides.customStoragePath = directory
        configuration.testingOverrides.suppressBackgroundWork = true
        let identity = IdentityService(customStoragePath: directory)
        identity.setDistinctId(owner)
        let events = EventLog(identity: identity, dateProvider: SystemDateProvider(), apiClient: MockNuxieApi())
        let products = ProductService()
        let transactions = TransactionService(productService: products, transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: PendingPurchaseStore(customStoragePath: directory), dateProvider: SystemDateProvider(),
            settings: NuxieRuntimeSettings(configuration: configuration), eventSink: DiscardingSystemEventSink())
        let experiences = ExperienceService(productService: products, eventLog: events,
            transactionServiceProvider: { transactions }, systemEventSink: DiscardingSystemEventSink(), releaseStore: acquisition)
        let presentations = ExperiencePresentationService(experiences: experiences, eventLog: events)
        let storageScope = JourneyStorageScope(authority: authority)
        let journal = try JourneyRunJournal(directory: directory, distinctId: owner, storageScope: storageScope)
        let observer = SemanticJourneyPresenter(base: presentations, journal: journal)
        let journeys = JourneyService(identity: identity, events: events, dateProvider: SystemDateProvider(),
            sleepProvider: SystemSleepProvider(), journalDirectory: directory, storageScope: storageScope,
            featureAccess: { _ in nil }, dispatcher: JourneyEffectDispatcher(identity: identity, events: events),
            presenter: observer, pinnedReleaseAuthenticator: { entry, reference in
                try JourneyReleaseVerifier().authenticateJourney(envelopeBytes: JSONEncoder().encode(entry.envelope),
                    authorizationKeys: keys, expectedIdentity: entry.locator.identity, expectedLegId: reference.legId,
                    supportedRuntime: candidate, replayPolicy: .pinned(experienceVersionId: reference.versionId,
                        buildId: entry.locator.buildId, descriptorSHA256: reference.descriptorSha256))
            }, timezones: try XCTUnwrap(SignedTimezoneBundle.installed))
        do {
            await events.subscribeCommitted { event in await journeys.handleEvent(event) }
            try await events.configure(configuration: configuration)
            let artifacts = try await experiences.prepareJourneyProfile(prepared.snapshot)
            let didCommit = await experiences.commitJourneyProfile(artifacts, generation: 1, admission: nil)
            XCTAssertTrue(didCommit)
            await journeys.initialize()
            await journeys.profileDidCommit(prepared.snapshot, artifacts: artifacts.artifacts,
                authority: authority, admissionGeneration: 1, distinctId: owner)
            await journeys.onAppBecameActive()
            try await waitUntil("Signed controls must reach the UIKit accessibility container") {
                observer.revealed && (scenario == .roles
                    ? self.semanticElements(in: presentations.currentExperienceViewController?.view).count == 8
                    : self.button(in: presentations.currentExperienceViewController?.view) != nil)
            }
            if scenario == .roles {
                try await assertAuthoredRoles(in: presentations.currentExperienceViewController?.view,
                    observer: observer, journal: journal)
            } else {
                let button = try XCTUnwrap(button(in: presentations.currentExperienceViewController?.view))
                XCTAssertTrue(button.accessibilityTraits.contains(.button))
                XCTAssertTrue(button.accessibilityActivate())
                if scenario == .success {
                    try await waitUntil("Authored navigation must follow durable emission admission") { observer.navigationResponses != nil && observer.accepted.count == 1 }
                    XCTAssertEqual(observer.navigationResponses?["selection"], .string("pro"))
                    XCTAssertEqual(observer.accepted.first?.emissions.map(\.name), [JourneyResponseControlNames.responseSet, "script_control_activated"])
                    let stored = try await journal.runs()
                    XCTAssertEqual(stored.first?.context.responses["selection"], .string("pro"))
                    XCTAssertTrue(presentations.isExperiencePresented)
                } else {
                    try await waitUntil("A throwing script must retire the presentation") { observer.failureResponses != nil && !presentations.isExperiencePresented }
                    XCTAssertNil(observer.failureResponses?["selection"])
                    XCTAssertTrue(observer.accepted.isEmpty)
                    XCTAssertNil(observer.navigationResponses)
                    let mark = try await journal.checkmark(experienceId: release.descriptor.identity.experienceId)
                    XCTAssertEqual(mark?.outcome, "abandoned")
                    let runs = try await journal.runs()
                    XCTAssertTrue(runs.isEmpty)
                }
            }
            XCTAssertTrue(requests.paths.contains { $0.hasPrefix("renders/sha256/") })
            if scenario != .roles {
                XCTAssertTrue(requests.paths.contains { $0.hasPrefix("screen-behavior/sha256/") })
            }
        } catch {
            await journeys.shutdown()
            await presentations.shutdownCurrentExperience()
            await events.close()
            throw error
        }
        await journeys.shutdown()
        await presentations.shutdownCurrentExperience()
        await events.close()
    }

    private func assertAuthoredRoles(in view: UIView?, observer: SemanticJourneyPresenter,
                                     journal: JourneyRunJournal) async throws {
        let elements = semanticElements(in: view)
        XCTAssertEqual(elements.compactMap(\.accessibilityLabel).sorted(), [
            "Annual plan", "Choose your plan", "Continue", "Password", "Plan option", "Plan option", "Seats", "Unavailable",
        ].sorted())
        let field = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Password" } as? UITextField)
        XCTAssertTrue(field.isSecureTextEntry)
        XCTAssertEqual(field.text, "")
        XCTAssertEqual(elements.filter { $0 is UITextField }.count, 1)
        let selected = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Annual plan" })
        XCTAssertTrue(selected.accessibilityTraits.contains(.selected))
        let disabled = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Unavailable" })
        XCTAssertTrue(disabled.accessibilityTraits.contains(.notEnabled))
        XCTAssertFalse(disabled.accessibilityActivate())
        let repeated = elements.filter { $0.accessibilityLabel == "Plan option" }
        XCTAssertEqual(Set(repeated.map(ObjectIdentifier.init)).count, 2)
        let seats = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Seats" })
        XCTAssertTrue(seats.accessibilityTraits.contains(.adjustable))
        seats.accessibilityIncrement()
        try await waitUntil("The authored increment must reach the Journey emission boundary") {
            observer.accepted.flatMap(\.emissions).filter { $0.name == "seat_increased" }.count == 1
        }
        seats.accessibilityDecrement()
        try await waitUntil("The authored decrement must reach the Journey emission boundary") {
            observer.accepted.flatMap(\.emissions).filter { $0.name == "seat_decreased" }.count == 1
        }
        field.text = "typed-password"
        field.sendActions(for: .editingChanged)
        try await waitUntil("The native editor must commit a response emission") {
            observer.accepted.flatMap(\.emissions).contains { $0.name == JourneyResponseControlNames.responseSet }
        }
        let runs = try await journal.runs()
        XCTAssertEqual(runs.first?.context.responses["password"], .string("typed-password"))
        XCTAssertNotEqual(field.accessibilityValue, "typed-password")
        XCTAssertFalse(elements.contains { $0.accessibilityValue == "fixture-secret-never-publish" })
        XCTAssertEqual(semanticElements(in: view).filter { $0.accessibilityLabel == "Password" }.count, 1)
        // Allow queued frames to expose late duplicates before checking the entire transaction sequence.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(observer.accepted.map { $0.emissions.map(\.name) }, [
            ["seat_increased"], ["seat_decreased"], [JourneyResponseControlNames.responseSet],
        ])
    }

    private func semanticElements(in view: UIView?) -> [NSObject] {
        guard let view else { return [] }
        if let elements = view.accessibilityElements?.compactMap({ $0 as? NSObject }), !elements.isEmpty {
            return elements
        }
        return view.subviews.flatMap { semanticElements(in: $0) }
    }

    private func object(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func button(in view: UIView?) -> UIAccessibilityElement? {
        guard let view else { return nil }
        if let element = view.accessibilityElements?.compactMap({ $0 as? UIAccessibilityElement })
            .first(where: { $0.accessibilityLabel == "Choose Pro" }) { return element }
        return view.subviews.lazy.compactMap { self.button(in: $0) }.first
    }

    private func waitUntil(_ message: String, condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), message)
        if !condition() { throw NSError(domain: "SignedSemanticJourneyTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}

private final class FixtureRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var values: Set<String> = []
    func record(_ value: String) { lock.withLock { _ = values.insert(value) } }
    var paths: Set<String> { lock.withLock { values } }
}

@MainActor
private final class SemanticJourneyPresenter: JourneyPresenting {
    let base: ExperiencePresentationService
    let journal: JourneyRunJournal
    var revealed = false
    var accepted: [ScreenEmissionBatch] = []
    var navigationResponses: ExactJSONObject<JourneyReleaseJSONValue>?
    var failureResponses: ExactJSONObject<JourneyReleaseJSONValue>?

    init(base: ExperiencePresentationService, journal: JourneyRunJournal) { self.base = base; self.journal = journal }
    func journeyProfileRefreshDidComplete() { base.journeyProfileRefreshDidComplete() }
    func setJourneyPresentationAvailabilityHandler(_ handler: (@MainActor @Sendable () -> Void)?) { base.setJourneyPresentationAvailabilityHandler(handler) }
    func reserveJourneyPresentation(ownerDistinctId: String) -> (any JourneyPresentationReservation)? { base.reserveJourneyPresentation(ownerDistinctId: ownerDistinctId) }
    func ownsJourneyPresentation(owner: JourneyPresentationOwner) -> Bool { base.ownsJourneyPresentation(owner: owner) }
    func presentJourney(_ request: JourneyPresentationRequest) async -> JourneyPresentationResult {
        await base.presentJourney(JourneyPresentationRequest(release: request.release, delivery: request.delivery,
            pinnedArtifacts: request.pinnedArtifacts, screenId: request.screenId, owner: request.owner,
            reservation: request.reservation, presentationTraceContext: request.presentationTraceContext,
            onScreenChanged: request.onScreenChanged, onScreenDismissed: { screen, next, method in
                if method == "error" {
                    self.failureResponses = try? await self.journal.runs().first?.context.responses
                }
                return await request.onScreenDismissed(screen, next, method)
            }, onProductsUnavailable: request.onProductsUnavailable, onEmissionBatch: { batch in
                let committed = await request.onEmissionBatch(batch)
                if committed { self.accepted.append(batch) }
                return committed
            }, onPermissionEvent: request.onPermissionEvent, onPresentationRevealed: { screen in
                await request.onPresentationRevealed(screen)
                self.revealed = true
            }, onOutcome: request.onOutcome, onPresentationFinished: request.onPresentationFinished))
    }
    func navigateJourneyPresentation(owner: JourneyPresentationOwner, screenId: String, transition: JourneyReleaseJSONValue?) async -> JourneyPresentationNavigationResult {
        if base.ownsJourneyPresentation(owner: owner) {
            navigationResponses = try? await journal.runs().first?.context.responses
        }
        return await base.navigateJourneyPresentation(owner: owner, screenId: screenId, transition: transition)
    }
    func resolveJourneyPresentationAction(owner: JourneyPresentationOwner, action: [String: JourneyReleaseJSONValue], source: ScreenEmissionSource?) -> [String: JourneyReleaseJSONValue]? {
        base.resolveJourneyPresentationAction(owner: owner, action: action, source: source)
    }
    func dispatchJourneyPresentationAction(owner: JourneyPresentationOwner, action: [String: JourneyReleaseJSONValue], effectId: String) async -> JourneyPresentationActionResult {
        await base.dispatchJourneyPresentationAction(owner: owner, action: action, effectId: effectId)
    }
    func finishJourneyPresentation(owner: JourneyPresentationOwner) async { await base.finishJourneyPresentation(owner: owner) }
    func shutdownJourneyPresentation(ownerDistinctId: String) async { await base.shutdownJourneyPresentation(ownerDistinctId: ownerDistinctId) }
}
#endif
