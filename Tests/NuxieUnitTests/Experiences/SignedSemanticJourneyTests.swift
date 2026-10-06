#if canImport(UIKit) && NUXIE_HOSTED_INPUT_TESTS
import UIKit
import XCTest
@_spi(Testing) @_spi(Companion) @testable import Nuxie
@testable import NuxieTestSupport

/// Hosted UIKit activation, not a claim of VoiceOver traversal qualification.
@MainActor
final class SignedSemanticJourneyTests: XCTestCase {
    func testQualificationAdmissionIsExplicitAndDevelopmentOnly() {
        var testing = NuxieTestingOverrides()
        for environment in [Environment.development, .staging, .production] {
            let supported = JourneyReleaseRuntime.supported(
                environment: environment,
                testing: NuxieInternalConfiguration(testingOverrides: testing)
            )
            XCTAssertFalse(supported.supportedCapabilities.contains("experience-accessibility"))
        }
        testing.qualifyExperienceAccessibility = true
        for environment in [Environment.staging, .production] {
            let supported = JourneyReleaseRuntime.supported(
                environment: environment,
                testing: NuxieInternalConfiguration(testingOverrides: testing)
            )
            XCTAssertFalse(supported.supportedCapabilities.contains("experience-accessibility"))
        }
    }

    func testSignedSemanticActivationPersistsResponsesBeforeAuthoredNavigation() async throws {
        try await exercise(.success)
    }

    func testFailedSignedSemanticActionDoesNotCommitPartialResponses() async throws {
        try await exercise(.scriptFailure)
    }

    func testSignedAuthoredRolesExposeOneSecureEditorAndPersistNativeActions() async throws {
        try await exercise(.roles)
    }

    func testSignedConditionReadsResponseAndEventFromTheSameNativeEmission() async throws {
        try await exercise(.condition)
    }

    private enum Scenario: String {
        case condition = "rendered-semantic-screen-control-condition"
        case roles = "rendered-semantic-roles"
        case success = "rendered-semantic-screen-control"
        case scriptFailure = "rendered-semantic-screen-control-error"
    }

    func testSharedLinkOpenStatesThroughWindowedPresentation() async throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/events/link-open-states.json")
        let vectors = try XCTUnwrap(try object(at: path)["cases"] as? [[String: Any]])
        for vector in vectors {
            let link = try XCTUnwrap(vector["link"] as? [String: Any])
            let expected = try XCTUnwrap(vector["expected"] as? [String: Any])
            // Broken Journey expressions run through JourneyService in JourneyPresentationLifecycleTests.
            if link["kind"] as? String == "journey", expected["opened"] as? Bool == false { continue }
            try await exercise(.success, linkVector: vector)
        }
    }

    func testRuntimeLinkRecordsBeforeSameFrameCompletion() async throws {
        try await exercise(.success, linkVector: ["name": "runtime-complete", "state": "settled", "complete": true,
            "link": ["kind": "runtime", "url": ["type": "String", "value": "https://example.test/path"], "target": "_self", "canOpen": true],
            "expected": ["destination": "in_app", "opened": true, "recorded": true]])
    }

    private func exercise(_ scenario: Scenario, linkVector: [String: Any]? = nil) async throws {
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
            "schemaVersion": "nuxie.journey-plane-profile.v2", "status": "ok",
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
            XCTAssertEqual(error as? JourneyReleaseAuthenticationError, .unsupportedCapabilities(["experience-accessibility"]))
        }
        var testing = NuxieTestingOverrides()
        testing.qualifyExperienceAccessibility = true
        let candidate = JourneyReleaseRuntime.supported(
            environment: .development,
            testing: NuxieInternalConfiguration(testingOverrides: testing)
        )
        let catalog = JourneyProfileCatalog(authorizationKeys: keys, supportedRuntime: candidate,
            highWaterStore: InMemoryJourneyReleaseHighWaterStore())
        let prepared = try await catalog.prepare(profile, authority: authority)
        let executionSnapshot = try linkVector.map { try linkSnapshot(prepared.snapshot, vector: $0) } ?? prepared.snapshot
        let screenless = linkVector?["state"] as? String == "screenless"
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
        let references = [try XCTUnwrap(render["nux"] as? [String: Any])]
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
        let presentations = ExperiencePresentationService(experiences: experiences, eventLog: events, identity: identity)
        let storageScope = JourneyStorageScope(authority: authority)
        let journal = try JourneyRunJournal(directory: directory, distinctId: owner, storageScope: storageScope)
        let observer = SemanticJourneyPresenter(base: presentations, journal: journal)
        let continuationFinished = XCTestExpectation(description: "Routed link execution finished")
        let journeys = JourneyService(identity: identity, events: events, dateProvider: SystemDateProvider(),
            sleepProvider: SystemSleepProvider(), journalDirectory: directory, storageScope: storageScope,
            featureAccess: { _ in nil }, dispatcher: JourneyEffectDispatcher(identity: identity, events: events),
            presenter: observer, pinnedReleaseAuthenticator: { entry, reference in
                try JourneyReleaseVerifier().authenticateJourney(envelopeBytes: JSONEncoder().encode(entry.envelope),
                    authorizationKeys: keys, expectedIdentity: entry.locator.identity, expectedLegId: reference.legId,
                    supportedRuntime: candidate, replayPolicy: .pinned(experienceVersionId: reference.versionId,
                        buildId: entry.locator.buildId, descriptorSHA256: reference.descriptorSha256))
            }, timezones: try XCTUnwrap(SignedTimezoneBundle.installed),
            onPresentationContinuationFinished: { continuationFinished.fulfill() })
        let shutdownGate = LinkShutdownGate()
        var profileClearTask: Task<Void, Never>?
        defer { shutdownGate.release(); profileClearTask?.cancel() }
        let linkProbe = LinkHandoffProbe()
        if let linkVector {
            let link = try XCTUnwrap(linkVector["link"] as? [String: Any])
            presentations.linkHandoff = { _, host in
                linkProbe.destinations.append(host == nil ? "external" : "in_app")
                return link["canOpen"] as? Bool ?? true
            }
        }
        do {
            await events.subscribeCommitted { event in await journeys.handleEvent(event) }
            try await events.configure(configuration: configuration)
            let artifacts = try await experiences.prepareJourneyProfile(prepared.snapshot)
            let didCommit = await experiences.commitJourneyProfile(artifacts, generation: 1, admission: nil)
            XCTAssertTrue(didCommit)
            await journeys.initialize()
            await journeys.profileDidCommit(executionSnapshot, artifacts: artifacts.artifacts,
                authority: authority, admissionGeneration: 1, distinctId: owner)
            await journeys.onAppBecameActive()
            if !screenless { try await waitUntil("Signed controls must reach the UIKit accessibility container") {
                observer.revealed && (scenario == .roles
                    ? self.semanticElements(in: presentations.currentExperienceViewController?.view).count == 10
                    : self.button(in: presentations.currentExperienceViewController?.view) != nil)
            }
            }
            if let linkVector {
                try await assertLinkState(linkVector, presentations: presentations, observer: observer, events: events, probe: linkProbe, continuationFinished: continuationFinished, retire: { reason, afterHandoff in
                    switch reason {
                    case "identity_change":
                        if afterHandoff {
                            await journeys.handleUserChange(from: owner, to: "replacement-owner")
                        } else {
                            identity.setDistinctId("replacement-owner")
                        }
                    case "identity_roundtrip":
                        if afterHandoff {
                            await journeys.handleUserChange(from: owner, to: "replacement-owner")
                            await journeys.handleUserChange(from: "replacement-owner", to: owner)
                        } else {
                            identity.setDistinctId("replacement-owner")
                            identity.setDistinctId(owner)
                        }
                    case "profile_clear":
                        if linkVector["beforeShutdown"] as? Bool == true {
                            if afterHandoff {
                                shutdownGate.release()
                                await profileClearTask?.value
                            } else {
                                observer.beforeShutdown = { await shutdownGate.hold() }
                                profileClearTask = Task { await journeys.profileDidClear(distinctId: owner) }
                                do {
                                    try await self.waitUntil("Profile clear must advance its fence before shutdown") { shutdownGate.entered }
                                } catch { XCTFail("Profile clear never reached shutdown: \(error)") }
                            }
                        } else if !afterHandoff { await journeys.profileDidClear(distinctId: owner) }
                    default: XCTFail("Unknown retirement \(reason)")
                    }
                })
            } else if scenario == .roles {
                try await assertAuthoredRoles(in: presentations.currentExperienceViewController?.view,
                    observer: observer, journal: journal)
            } else {
                let button = try XCTUnwrap(button(in: presentations.currentExperienceViewController?.view))
                XCTAssertTrue(button.accessibilityTraits.contains(.button))
                let activationStartedAt = Date()
                XCTAssertTrue(button.accessibilityActivate())
                if scenario == .success || scenario == .condition {
                    try await waitUntil("Authored navigation must follow durable emission admission") { observer.navigationResponses != nil && observer.accepted.count == 1 }
                    XCTAssertEqual(observer.navigationResponses?["selection"], .string("pro"))
                    XCTAssertEqual(observer.accepted.first?.emissions.map(\.name), [JourneyResponseControlNames.responseSet, "script_control_activated"])
                    for emission in try XCTUnwrap(observer.accepted.first).emissions {
                        let occurredAt = try XCTUnwrap(JourneyPresentationEventProjector.date(emission.occurredAt))
                        // Millisecond wire precision must not move an action before
                        // its activation or the display that made it possible.
                        XCTAssertGreaterThanOrEqual(occurredAt.timeIntervalSince1970,
                            activationStartedAt.timeIntervalSince1970 - 0.001)
                        XCTAssertLessThanOrEqual(occurredAt, Date())
                    }
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
        if linkVector != nil, let controller = linkProbe.controller {
            try await waitUntil("Link fixture UIKit teardown must finish before the next test") {
                controller.view.window == nil && !controller.isBeingDismissed
            }
        }
        await events.close()
    }

    // Execution fixtures retain verified scene bytes and replace only the Journey graph.
    private func linkSnapshot(_ snapshot: JourneyProfileCatalog.Snapshot, vector: [String: Any]) throws -> JourneyProfileCatalog.Snapshot {
        let original = try XCTUnwrap(snapshot.releasesByDigest.values.first)
        let d = original.descriptor
        let leg = d.leg
        let screenID = try XCTUnwrap(leg.screens.first?.id)
        let link = try XCTUnwrap(vector["link"] as? [String: Any])
        let journey = link["kind"] as? String == "journey"
        let screenless = vector["state"] as? String == "screenless"
        let complete = vector["complete"] as? Bool == true
        if !journey && !complete { return snapshot }
        let value = try ExactJSONCodec.decode(JourneyReleaseJSONValue.self,
            from: JSONSerialization.data(withJSONObject: link["url"]!, options: .fragmentsAllowed))
        let steps: [Journey.Step] = [
            .init(kind: .action, id: "present", action: ["type": .string("navigate"), "screenId": .string(screenID)], outlets: [:], outcome: nil),
            .init(kind: .action, id: "link", action: ["type": .string("open_link"), "url": value, "target": .string(link["target"] as? String ?? "")], outlets: ["next": "done"], outcome: nil),
            .init(kind: .complete, id: "done", action: nil, outlets: nil, outcome: "completed")]
        let nextLeg = Journey(schemaVersion: leg.schemaVersion, id: leg.id, entryCondition: leg.entryCondition,
            entryStepId: screenless ? "link" : "present", steps: steps.filter { (!screenless || $0.id != "present") && (journey || $0.id != "link") },
            routes: screenless ? [] : [.init(host: .init(kind: .screen, screenId: screenID), eventName: "table_link", entryStepId: journey ? "link" : "done")],
            screens: screenless ? [] : leg.screens, policy: leg.policy, offers: screenless ? [] : leg.offers, facts: leg.facts,
            inputs: leg.inputs, outputs: leg.outputs, completionOutputs: leg.completionOutputs)
        let descriptor = JourneyReleaseDescriptor(schemaVersion: d.schemaVersion, identity: d.identity, metadata: d.metadata,
            presentation: d.presentation, leg: nextLeg, products: d.products, placements: d.placements,
            viewModelValues: d.viewModelValues, screenBehaviors: screenless ? [] : d.screenBehaviors, render: screenless ? nil : d.render,
            requirements: screenless ? nil : d.requirements, provenance: d.provenance)
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor)) as? [String: Any])
        if screenless { wire["render"] = NSNull(); wire["requirements"] = NSNull() }
        try JourneyReleaseSchemaValidator.validate(wire)
        let release = AuthenticatedJourneyRelease(authenticatedKeyID: original.authenticatedKeyID, exactDescriptorBytes: original.exactDescriptorBytes,
            descriptorSHA256: original.descriptorSHA256, descriptor: descriptor, publishedAtSeqToPromote: original.publishedAtSeqToPromote)
        return .init(profile: snapshot.profile, releasesByDigest: [original.descriptorSHA256: release])
    }

    private func assertLinkState(_ vector: [String: Any], presentations: ExperiencePresentationService,
                                 observer: SemanticJourneyPresenter, events: EventLog, probe: LinkHandoffProbe,
                                 continuationFinished: XCTestExpectation, retire: @escaping (String, Bool) async -> Void) async throws {
        let state = try XCTUnwrap(vector["state"] as? String)
        let retirement = state == "owner_retired" ? try XCTUnwrap(vector["retirement"] as? String) : ""
        let link = try XCTUnwrap(vector["link"] as? [String: Any])
        let expected = try XCTUnwrap(vector["expected"] as? [String: Any])
        if state != "screenless" {
            let request = try XCTUnwrap(observer.lastRequest)
            let controller = try XCTUnwrap(presentations.currentExperienceViewController)
            probe.controller = controller
            try await waitUntil("Presentation must settle before link handoff") { controller.view.window != nil && !controller.isBeingPresented }
            func screen(in controller: UIViewController) -> ExperienceScreenViewController? {
                if let screen = controller as? ExperienceScreenViewController { return screen }
                return controller.children.compactMap { screen(in: $0) }.first
            }
            let source = try XCTUnwrap(screen(in: controller))
            var top: UIViewController = controller
            let changeState = {
                switch state {
                case "sheet_active":
                    let sheet = UIViewController(); sheet.modalPresentationStyle = .pageSheet
                    await withCheckedContinuation { continuation in controller.present(sheet, animated: false) { continuation.resume() } }
                    top = sheet
                case "button_dismissing": controller.performDismiss()
                // iOS has no separate paused_foreground state; reuse swipe dismissal.
                case "swipe_dismissing", "paused_foreground":
                    controller.dismiss(animated: true) { probe.dismissalCompleted = true }
                    XCTAssertTrue(controller.isBeingDismissed)
                case "host_dismissed": await presentations.dismissCurrentExperienceFromHost()
                case "owner_retired":
                    await retire(retirement, false)
                    if retirement == "identity_change" || vector["beforeShutdown"] as? Bool == true {
                        XCTAssertTrue(presentations.ownsJourneyPresentation(owner: request.owner))
                        XCTAssertTrue(controller.view.window != nil)
                        XCTAssertFalse(controller.linkPresentationIsClosing)
                    }
                case "presentation_finished": await presentations.finishJourneyPresentation(owner: request.owner)
                case "background": presentations.onAppDidEnterBackground()
                default: break
                }
            }
            presentations.linkHandoff = { _, host in
                probe.destinations.append(host == nil ? "external" : "in_app")
                if let host { XCTAssertTrue(host === top) }
                if state == "owner_retired" { await retire(retirement, true) }
                return link["canOpen"] as? Bool ?? true
            }
            let journey = link["kind"] as? String == "journey"
            if journey { observer.beforeLink = changeState }
            else { observer.beforeBatch = changeState }
            let expression = try XCTUnwrap(link["url"] as? [String: Any])
            let url = try XCTUnwrap(expression["value"] as? String)
            var effects = [ExperienceInteractiveEffect(sequence: 0, correlationID: 991,
                kind: .reportedEvent(.init(localIndex: 0, coreType: 128, name: "table_link", url: "", target: "", delay: 0, properties: [])))]
            if !journey { effects.append(.init(sequence: 1, correlationID: 991,
                kind: .reportedEvent(.init(localIndex: 1, coreType: 131, name: "", url: url, target: link["target"] as? String ?? "", delay: 0, properties: [])))) }
            await source.deliverStep(effects: effects)
            try await waitUntil("Runtime frame must settle") { observer.finishedBatch }
        }
        if state == "owner_retired" {
            if link["kind"] as? String == "journey" {
                await fulfillment(of: [continuationFinished], timeout: 5)
            } else {
                try await waitUntil("Runtime link recording must finish before the negative assertion") { observer.finishedLinkRecording }
            }
        }
        for _ in 0..<100 {
            if await events.getRecentEvents().filter { $0.name == JourneyEvents.linkOpened }.count == (expected["recorded"] as? Bool == true ? 1 : 0) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let records = await events.getRecentEvents().filter { $0.name == JourneyEvents.linkOpened }
        XCTAssertEqual(records.count, expected["recorded"] as? Bool == true ? 1 : 0, "\(vector["name"]!)")
        if let record = records.first {
            let properties = try XCTUnwrap(try JSONSerialization.jsonObject(with: record.properties) as? [String: Any])
            XCTAssertEqual(properties["destination"] as? String, expected["destination"] as? String)
        }
        if expected["opened"] as? Bool == true {
            XCTAssertEqual(probe.destinations, [try XCTUnwrap(expected["destination"] as? String)], "\(vector["name"]!)")
        }
        XCTAssertEqual(probe.destinations.count, (expected["opened"] as? Bool == true || link["canOpen"] as? Bool == false) ? 1 : 0)
        if vector["complete"] as? Bool == true {
            for _ in 0..<100 where await events.getRecentEvents().filter { $0.name == JourneyEvents.journeyCompleted }.count == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
            let ordered = await events.getRecentEvents().reversed().map(\.name)
            XCTAssertLessThan(try XCTUnwrap(ordered.firstIndex(of: JourneyEvents.linkOpened)), try XCTUnwrap(ordered.firstIndex(of: JourneyEvents.journeyCompleted)))
        }
        if state == "swipe_dismissing" || state == "paused_foreground" {
            try await waitUntil("UIKit dismissal must finish before fixture teardown") { probe.dismissalCompleted }
        }
        presentations.onAppBecameActive()
    }

    @MainActor private final class LinkShutdownGate {
        var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor private final class LinkHandoffProbe {
        weak var controller: ExperienceViewController?
        var destinations: [String] = []
        var dismissalCompleted = false
    }

    private func assertAuthoredRoles(in view: UIView?, observer: SemanticJourneyPresenter,
                                     journal: JourneyRunJournal) async throws {
        let elements = semanticElements(in: view)
        XCTAssertEqual(elements.compactMap(\.accessibilityLabel).sorted(), [
            "Annual plan", "Choose your plan", "Continue", "Password", "Plan option", "Plan option", "Seats", "Unavailable",
            "Optional extras", "Choose the options that suit you.",
        ].sorted())
        let field = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Password" } as? UITextField)
        XCTAssertTrue(field.isSecureTextEntry)
        XCTAssertEqual(field.attributedPlaceholder?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor,
                       field.textColor)
        XCTAssertEqual(field.text, "")
        XCTAssertEqual(elements.filter { $0 is UITextField }.count, 1)
        let selected = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Annual plan" })
        XCTAssertTrue(selected.accessibilityTraits.contains(.selected))
        XCTAssertEqual(selected.accessibilityValue, "1")
        var publishedValues: [String?] = []
        for (index, expectedValue) in ["0", "1"].enumerated() {
            XCTAssertTrue(selected.accessibilityActivate())
            // A working checkbox updates within a frame or two. Keep the known failure
            // short: a long idle wait before the seats step below made it flaky.
            _ = await eventually(within: 2) { selected.accessibilityValue == expectedValue }
            publishedValues.append(selected.accessibilityValue)
            try await waitUntil("Each toggle must emit exactly one accepted authored event") {
                observer.accepted.flatMap(\.emissions).filter { $0.name == "plan_toggled" }.count == index + 1
            }
        }
        // Known failure, UNIV-3761 (https://universe.basis.dev/issue/UNIV-3761):
        // apple-runtime 0.10.12 writes the check state only from numbers, and this
        // fixture binds `checked` to a boolean, so the value stays "1". Regenerate the
        // fixture with a number binding, then remove this expectation; being strict,
        // it fails once the checkbox toggles again.
        XCTExpectFailure("UNIV-3761: the fixture binds the check state to a boolean") {
            XCTAssertEqual(publishedValues, ["0", "1"], "Checkbox activation must publish its changed checked state")
        }
        let heading = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Choose your plan" })
        XCTAssertTrue(heading.accessibilityTraits.contains(.header))
        let mixed = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Optional extras" })
        XCTAssertEqual(mixed.accessibilityValue, "Mixed, Required")
        XCTAssertFalse(mixed.accessibilityTraits.contains(.selected))
        let disabled = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Unavailable" })
        XCTAssertTrue(disabled.accessibilityTraits.contains(.notEnabled))
        XCTAssertFalse(disabled.accessibilityActivate())
        let repeated = elements.filter { $0.accessibilityLabel == "Plan option" }
        XCTAssertEqual(Set(repeated.map(ObjectIdentifier.init)).count, 2)
        let seats = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Seats" } as? ExperienceSemanticAccessibilityElement)
        XCTAssertTrue(seats.accessibilityTraits.contains(.adjustable))
        XCTAssertEqual(seats.accessibilityValue, "3 seats")
        let initialCaptureID = try XCTUnwrap(seats.captureID)
        seats.accessibilityIncrement()
        try await waitUntil("The authored increment must reach the Journey emission boundary") {
            observer.accepted.flatMap(\.emissions).filter { $0.name == "seat_increased" }.count == 1
        }
        // Durable emission admission precedes presentation of the resulting frame.
        // A second action must target that new capture, not the retired revision.
        try await waitUntil("Increment must present a refreshed adjustable capture") {
            seats.captureID != nil && seats.captureID != initialCaptureID
        }
        seats.accessibilityDecrement()
        try await waitUntil("The authored decrement must reach the Journey emission boundary") {
            observer.accepted.flatMap(\.emissions).filter { $0.name == "seat_decreased" }.count == 1
        }
        XCTAssertTrue(field.becomeFirstResponder())
        field.text = "typed-password"
        field.sendActions(for: .editingChanged)
        XCTAssertTrue(field.resignFirstResponder())
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
            ["plan_toggled"], ["plan_toggled"],
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

    /// Whether `condition` holds within `seconds`.
    private func eventually(within seconds: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        return condition()
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
    var lastRequest: JourneyPresentationRequest?
    var beforeLink: (() async -> Void)?
    var beforeBatch: (() async -> Void)?
    var beforeShutdown: (() async -> Void)?
    var finishedBatch = false
    var finishedLinkRecording = false
    var revealed = false
    var accepted: [ScreenEmissionBatch] = []
    var navigationResponses: ExactJSONObject<JourneyReleaseJSONValue>?
    var failureResponses: ExactJSONObject<JourneyReleaseJSONValue>?

    init(base: ExperiencePresentationService, journal: JourneyRunJournal) { self.base = base; self.journal = journal }
    func openJourneyLink(owner: JourneyPresentationOwner, request: ExperienceRendererOpenLinkRequest) async -> ExperienceRendererOpenLinkRequest? {
        let change = beforeLink; beforeLink = nil
        await change?()
        return await base.openJourneyLink(owner: owner, request: request)
    }
    func journeyProfileRefreshDidComplete() { base.journeyProfileRefreshDidComplete() }
    func setJourneyPresentationAvailabilityHandler(_ handler: (@MainActor @Sendable () -> Void)?) { base.setJourneyPresentationAvailabilityHandler(handler) }
    func reserveJourneyPresentation(ownerDistinctId: String) -> (any JourneyPresentationReservation)? { base.reserveJourneyPresentation(ownerDistinctId: ownerDistinctId) }
    func ownsJourneyPresentation(owner: JourneyPresentationOwner) -> Bool { base.ownsJourneyPresentation(owner: owner) }
    func presentJourney(_ request: JourneyPresentationRequest) async -> JourneyPresentationResult {
        lastRequest = request
        return await base.presentJourney(JourneyPresentationRequest(fences: request.fences, release: request.release, delivery: request.delivery,
            pinnedArtifacts: request.pinnedArtifacts, screenId: request.screenId, owner: request.owner,
            reservation: request.reservation, presentationTraceContext: request.presentationTraceContext,
            onScreenChanged: request.onScreenChanged, onScreenDismissed: { screen, next, method in
                if method == "error" {
                    self.failureResponses = try? await self.journal.runs().first?.context.responses
                }
                return await request.onScreenDismissed(screen, next, method)
            }, onProductsUnavailable: request.onProductsUnavailable, onLinkOpened: { link in
                await request.onLinkOpened(link)
                await MainActor.run { self.finishedLinkRecording = true }
            }, onEmissionBatch: { batch, frameSources in
                let change = self.beforeBatch; self.beforeBatch = nil
                await change?()
                let committed = await request.onEmissionBatch(batch, frameSources)
                self.finishedBatch = true
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
    func cancelJourneyBackNavigation(owner: JourneyPresentationOwner) { base.cancelJourneyBackNavigation(owner: owner) }
    func resolveJourneyPresentationAction(owner: JourneyPresentationOwner, action: [String: JourneyReleaseJSONValue], source: ScreenEmissionSource?, eventSource: ExperienceResolvedEventSource?) -> [String: JourneyReleaseJSONValue]? {
        base.resolveJourneyPresentationAction(owner: owner, action: action, source: source, eventSource: eventSource)
    }
    func dispatchJourneyPresentationAction(owner: JourneyPresentationOwner, action: [String: JourneyReleaseJSONValue], effectId: String) async -> JourneyPresentationActionResult {
        await base.dispatchJourneyPresentationAction(owner: owner, action: action, effectId: effectId)
    }
    func finishJourneyPresentation(owner: JourneyPresentationOwner) async { await base.finishJourneyPresentation(owner: owner) }
    func shutdownJourneyPresentation(ownerDistinctId: String) async {
        let hold = beforeShutdown; beforeShutdown = nil
        await hold?()
        await base.shutdownJourneyPresentation(ownerDistinctId: ownerDistinctId)
    }
}
#endif
