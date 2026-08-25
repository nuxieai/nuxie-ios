import Foundation
import XCTest

@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private actor CatalogForwardingRecorder {
    private var events: [DurableForwardingEvent] = []

    func record(_ event: DurableForwardingEvent) { events.append(event) }
    func snapshot() -> [DurableForwardingEvent] { events }
}

final class EventCatalogConformanceTests: XCTestCase {
    private struct CatalogProperty: Decodable {
        let type: String
        let required: Bool
        let source: String
    }

    private struct CatalogRow: Decodable {
        let constant: String?
        let status: String
        let properties: [String: CatalogProperty]
        let emitters: [String]
        let fixtures: [String]?
        let forwarding: String
    }

    private static let declaredConstants: [(path: String, value: String)] = [
        ("JourneyEvents.appActionRequested", JourneyEvents.appActionRequested),
        ("JourneyEvents.customerUpdated", JourneyEvents.customerUpdated),
        ("JourneyEvents.eventSent", JourneyEvents.eventSent),
        ("JourneyEvents.experienceArtifactLoadFailed", JourneyEvents.experienceArtifactLoadFailed),
        ("JourneyEvents.experienceArtifactLoadSucceeded", JourneyEvents.experienceArtifactLoadSucceeded),
        ("JourneyEvents.experienceDismissed", JourneyEvents.experienceDismissed),
        ("JourneyEvents.experienceErrored", JourneyEvents.experienceErrored),
        ("JourneyEvents.experienceShown", JourneyEvents.experienceShown),
        ("JourneyEvents.experimentExposure", JourneyEvents.experimentExposure),
        ("JourneyEvents.experimentExposureError", JourneyEvents.experimentExposureError),
        ("JourneyEvents.experimentExposureFallback", JourneyEvents.experimentExposureFallback),
        ("JourneyEvents.journeyClaimed", JourneyEvents.journeyClaimed),
        ("JourneyEvents.journeyConverted", JourneyEvents.journeyConverted),
        ("JourneyEvents.journeyEffectCompleted", JourneyEvents.journeyEffectCompleted),
        ("JourneyEvents.journeyEffectRequested", JourneyEvents.journeyEffectRequested),
        ("JourneyEvents.journeyEnrolled", JourneyEvents.journeyEnrolled),
        ("JourneyEvents.journeyExited", JourneyEvents.journeyExited),
        ("JourneyEvents.journeyHandoff", JourneyEvents.journeyHandoff),
        ("JourneyEvents.journeyMilestone", JourneyEvents.journeyMilestone),
        ("JourneyEvents.journeyParked", JourneyEvents.journeyParked),
        ("JourneyEvents.journeySuperseded", JourneyEvents.journeySuperseded),
        ("JourneyEvents.journeyTransition", JourneyEvents.journeyTransition),
        ("SystemEventNames.appBackgrounded", SystemEventNames.appBackgrounded),
        ("SystemEventNames.appInstalled", SystemEventNames.appInstalled),
        ("SystemEventNames.appOpened", SystemEventNames.appOpened),
        ("SystemEventNames.appUpdated", SystemEventNames.appUpdated),
        ("SystemEventNames.featureUsed", SystemEventNames.featureUsed),
        ("SystemEventNames.identify", SystemEventNames.identify),
        ("SystemEventNames.journeyStarted", SystemEventNames.journeyStarted),
        ("SystemEventNames.notificationsDenied", SystemEventNames.notificationsDenied),
        ("SystemEventNames.notificationsEnabled", SystemEventNames.notificationsEnabled),
        ("SystemEventNames.permissionDenied", SystemEventNames.permissionDenied),
        ("SystemEventNames.permissionGranted", SystemEventNames.permissionGranted),
        ("SystemEventNames.productsUnavailable", SystemEventNames.productsUnavailable),
        ("SystemEventNames.purchaseCancelled", SystemEventNames.purchaseCancelled),
        ("SystemEventNames.purchaseCompleted", SystemEventNames.purchaseCompleted),
        ("SystemEventNames.purchaseFailed", SystemEventNames.purchaseFailed),
        ("SystemEventNames.purchasePending", SystemEventNames.purchasePending),
        ("SystemEventNames.purchaseSynced", SystemEventNames.purchaseSynced),
        ("SystemEventNames.responseSet", SystemEventNames.responseSet),
        ("SystemEventNames.responseUnset", SystemEventNames.responseUnset),
        ("SystemEventNames.restoreCompleted", SystemEventNames.restoreCompleted),
        ("SystemEventNames.restoreFailed", SystemEventNames.restoreFailed),
        ("SystemEventNames.restoreNoPurchases", SystemEventNames.restoreNoPurchases),
        ("SystemEventNames.screenDismissed", SystemEventNames.screenDismissed),
        ("SystemEventNames.screenShown", SystemEventNames.screenShown),
        ("SystemEventNames.trackingAuthorized", SystemEventNames.trackingAuthorized),
        ("SystemEventNames.trackingDenied", SystemEventNames.trackingDenied),
    ]

    // Authority: the parent repo's forwarding spec revision 3 curation table.
    // This deliberate duplication pins the forwarding decision for every event.
    private static let expectedForwardingByEvent: [String: String] = [
        "$app_action_requested": "hidden: delivered through didRequestAppAction",
        "$app_backgrounded": "appBackgrounded",
        "$app_installed": "appInstalled",
        "$app_opened": "appOpened",
        "$app_updated": "appUpdated",
        "$customer_updated": "hidden: identity and PII rider",
        "$event_sent": "hidden: authored event remains Nuxie-internal",
        "$experience_artifact_load_failed": "experienceLoadFailed",
        "$experience_artifact_load_succeeded": "hidden: successful artifact load is noise",
        "$experience_dismissed": "experienceDismissed",
        "$experience_errored": "experienceErrored",
        "$experience_shown": "experienceShown",
        "$experiment_exposure": "experimentExposure",
        "$experiment_exposure_error": "experimentError",
        "$experiment_exposure_fallback": "hidden: default-variant diagnostic is not an exposure",
        "$feature_used": "featureUsed",
        "$identify": "hidden: identity and PII event",
        "$journey_claimed": "hidden: journey ownership protocol",
        "$journey_converted": "journeyConverted",
        "$journey_effect_completed": "hidden: journey effect protocol",
        "$journey_effect_requested": "hidden: journey effect protocol",
        "$journey_enrolled": "journeyStarted",
        "$journey_exited": "journeyEnded",
        "$journey_handoff": "hidden: journey ownership protocol",
        "$journey_milestone": "milestoneReached",
        "$journey_parked": "hidden: journey checkpoint protocol",
        "$journey_started": "hidden: retired runtime control",
        "$journey_superseded": "journeyEnded",
        "$journey_transition": "hidden: journey state-sync protocol",
        "$notifications_denied": "permissionResolved",
        "$notifications_enabled": "permissionResolved",
        "$permission_denied": "permissionResolved",
        "$permission_granted": "permissionResolved",
        "$products_unavailable": "productsUnavailable",
        "$purchase_cancelled": "purchaseCancelled",
        "$purchase_completed": "purchaseCompleted",
        "$purchase_failed": "purchaseFailed",
        "$purchase_pending": "purchasePending",
        "$purchase_synced": "purchaseSynced",
        "$response_set": "hidden: local response control state",
        "$response_unset": "hidden: local response control state",
        "$restore_completed": "restoreCompleted",
        "$restore_failed": "restoreFailed",
        "$restore_no_purchases": "restoreNoPurchases",
        "$screen_dismissed": "screenDismissed",
        "$screen_shown": "screenShown",
        "$tracking_authorized": "permissionResolved",
        "$tracking_denied": "permissionResolved",
    ]

    func testDeclaredConstantsAppearInCatalog() throws {
        let catalog = try loadCatalog()
        let sourceDeclarations = try loadSourceDeclarations()

        XCTAssertEqual(
            sourceDeclarations.count,
            Self.declaredConstants.count,
            "The compile-time declaration list is stale relative to the canonical source files"
        )

        for declaration in Self.declaredConstants {
            XCTAssertEqual(
                sourceDeclarations[declaration.path],
                declaration.value,
                "Source declaration changed or is missing for \(declaration.path)"
            )
            XCTAssertNotNil(
                catalog[declaration.value],
                "Missing catalog row for \(declaration.path) = \(declaration.value)"
            )
        }
    }

    func testCatalogConstantPathsResolveToDeclarations() throws {
        let catalog = try loadCatalog()
        let declarationsByPath = Dictionary(
            uniqueKeysWithValues: Self.declaredConstants.map { ($0.path, $0.value) }
        )

        XCTAssertEqual(
            Self.declaredConstants.count,
            catalog.count,
            "Update the compile-time declaration list whenever the event catalog changes"
        )
        for (eventName, row) in catalog {
            guard let constant = row.constant else { continue }
            XCTAssertEqual(
                declarationsByPath[constant],
                eventName,
                "Catalog constant \(constant) does not resolve to \(eventName)"
            )
        }
    }

    func testEveryNonDeletedOrRetiredEventHasAnEmitter() throws {
        for (eventName, row) in try loadCatalog()
            where row.status != "delete" && row.status != "retired" {
            XCTAssertFalse(
                row.emitters.isEmpty,
                "Event \(eventName) with status \(row.status) has no production emitter"
            )
        }
    }

    func testCanonicalPropertyContractsMatchProductionShapes() throws {
        let catalog = try loadCatalog()
        let effect = try XCTUnwrap(catalog["$journey_effect_requested"]?.properties["effect"])
        XCTAssertEqual(effect.type, "object")
        XCTAssertTrue(effect.required)
        XCTAssertEqual(
            effect.source,
            "structured effect descriptor handled by JourneyRunner.handleServerEffect"
        )

        let experienceVersion = try XCTUnwrap(
            catalog["$experiment_exposure"]?.properties["experience_version"]
        )
        XCTAssertEqual(experienceVersion.type, "String")
        XCTAssertTrue(experienceVersion.required)

        let convertedExperienceID = try XCTUnwrap(
            catalog["$journey_converted"]?.properties["experience_id"]
        )
        XCTAssertEqual(convertedExperienceID.type, "String")
        XCTAssertTrue(convertedExperienceID.required)
        XCTAssertEqual(
            convertedExperienceID.source,
            "required on both paths since nuxie-ios#369: the device path supplies it from JourneySnapshot and the server down-fact decode rejects payloads missing it"
        )

        let convertedExperienceVersion = try XCTUnwrap(
            catalog["$journey_converted"]?.properties["experience_version"]
        )
        XCTAssertEqual(convertedExperienceVersion.type, "String")
        XCTAssertTrue(convertedExperienceVersion.required)
        XCTAssertEqual(
            convertedExperienceVersion.source,
            "required on both paths since nuxie-ios#369: the device path supplies it from JourneySnapshot and the server down-fact decode rejects payloads missing it"
        )

        let effectRequested = try XCTUnwrap(catalog["$journey_effect_requested"])
        XCTAssertTrue(
            (effectRequested.fixtures ?? []).contains("fixtures/journeys/effects/round-trip.json"),
            "the effect round-trip vector pins the request shape, including the required epoch"
        )
        XCTAssertEqual(effectRequested.properties["epoch"]?.required, true)

        // The pin must bite the vector's content, not just the catalog's
        // reference: every required effect-request property appears in the
        // fixture's request payload.
        let effectFixtureURL = repositoryRoot
            .appendingPathComponent("fixtures/journeys/effects/round-trip.json")
        let effectFixture = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: effectFixtureURL)
            ) as? [String: Any]
        )
        let effectRequest = try XCTUnwrap(effectFixture["request"] as? [String: Any])
        XCTAssertEqual(effectRequest["event"] as? String, "$journey_effect_requested")
        let effectRequestProperties = try XCTUnwrap(
            effectRequest["properties"] as? [String: Any]
        )
        for (name, property) in effectRequested.properties where property.required {
            XCTAssertNotNil(
                effectRequestProperties[name],
                "round-trip.json request omits required property '\(name)'"
            )
        }
    }

    func testForwardingMatchesRevisionThreeCurationTableExactly() throws {
        let actual = try loadCatalog().mapValues(\.forwarding)

        XCTAssertEqual(
            Set(actual.keys),
            Set(Self.expectedForwardingByEvent.keys),
            "Catalog and revision 3 forwarding pin must contain exactly the same events"
        )
        XCTAssertEqual(
            actual,
            Self.expectedForwardingByEvent,
            "Every event must keep its revision 3 forwarding decision"
        )
    }

    func testCurationClassifiesEveryCatalogEventExactlyOnce() throws {
        let catalog = try loadCatalog()
        let forwarded = Set(catalog.compactMap { name, row in
            row.forwarding.hasPrefix("hidden:") ? nil : name
        })
        let hidden = Set(catalog.compactMap { name, row in
            row.forwarding.hasPrefix("hidden:") ? name : nil
        })

        XCTAssertTrue(ActivityCuration.curatedNames.isDisjoint(with: ActivityCuration.hiddenNames))
        XCTAssertEqual(ActivityCuration.curatedNames, forwarded)
        XCTAssertEqual(ActivityCuration.hiddenNames, hidden)
        XCTAssertEqual(ActivityCuration.classifiedNames, Set(catalog.keys))
    }

    func testAdmissionTicketEventsDurablyCaptureAndCurateThroughTheirRealLanes() async throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nuxie-admission-ticket-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }

        let configuration = NuxieConfiguration(apiKey: "test-api-key")
        configuration.testingOverrides.customStoragePath = storageURL
        configuration.testingOverrides.flushAt = 10_000
        let identity = MockIdentityService()
        identity.setDistinctId("customer-1")
        let log = EventLog(
            identity: identity,
            sessions: MockSessionService(),
            dateProvider: MockDateProvider(),
            apiClient: MockNuxieApiForQueue()
        )
        let recorder = CatalogForwardingRecorder()
        await log.subscribeForwarding { event in await recorder.record(event) }
        try await log.configure(configuration: configuration)

        let experienceProperties: [String: Any] = [
            "experience_id": "experience-1",
            "experience_version": "version-1",
            "journey_id": "journey-1",
        ]
        let captureLaneEvents: [(String, [String: Any])] = [
            (SystemEventNames.screenShown, experienceProperties.merging([
                "screen_id": "screen-1",
            ]) { _, new in new }),
            (SystemEventNames.screenDismissed, experienceProperties.merging([
                "screen_id": "screen-1",
            ]) { _, new in new }),
            (SystemEventNames.productsUnavailable, experienceProperties.merging([
                "product_ids": ["product-1", "product-2"],
            ]) { _, new in new }),
        ]
        for event in captureLaneEvents {
            log.trackWithoutRouting(
                event.0,
                properties: event.1,
                distinctIdOverride: "customer-1"
            )
        }

        let permissionEvents = [
            SystemEventNames.notificationsDenied,
            SystemEventNames.notificationsEnabled,
            SystemEventNames.permissionDenied,
            SystemEventNames.permissionGranted,
            SystemEventNames.trackingAuthorized,
            SystemEventNames.trackingDenied,
        ]
        for eventName in permissionEvents {
            _ = try await log.trackForTrigger(eventName, properties: experienceProperties)
        }

        let featureProperties: [String: Any] = [
            "feature_id": "feature-1",
            "amount": 2.0,
            "entity_id": "entity-1",
        ]
        let enrichedFeatureProperties = await log.prepareTriggerProperties(featureProperties)
        await log.storePreparedEventInHistory(NuxieEvent(
            id: "feature-use-1",
            name: SystemEventNames.featureUsed,
            distinctId: "customer-1",
            properties: enrichedFeatureProperties
        ))
        await log.drain()

        let expectedNames = captureLaneEvents.map(\.0)
            + permissionEvents
            + [SystemEventNames.featureUsed]
        let durable = await recorder.snapshot()
        XCTAssertEqual(durable.map(\.event.forwardingName), expectedNames)
        XCTAssertEqual(
            durable.compactMap {
                ActivityCuration.activity(
                    internalName: $0.event.forwardingName,
                    properties: $0.event.properties
                )?.wireName
            }.count,
            expectedNames.count,
            "Every newly durable admission-ticket event must retain a curation case"
        )
        let storedNames = Set(await log.getRecentEvents(limit: 100).map(\.name))
        XCTAssertTrue(Set(expectedNames).isSubset(of: storedNames))
        await log.close()

        try assertAdmissionTicketProducerCapturesRemainWired()
    }

    private func loadCatalog() throws -> [String: CatalogRow] {
        let url = repositoryRoot.appendingPathComponent("fixtures/events/catalog.json")
        return try JSONDecoder().decode(
            [String: CatalogRow].self,
            from: Data(contentsOf: url)
        )
    }

    private func loadSourceDeclarations() throws -> [String: String] {
        let files = [
            (owner: "SystemEventNames", path: "Sources/Nuxie/Events/SystemEventNames.swift"),
            (owner: "JourneyEvents", path: "Sources/Nuxie/Journey/Events/JourneyEvents.swift"),
        ]
        var declarations: [String: String] = [:]

        for file in files {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(file.path),
                encoding: .utf8
            )
            for line in source.split(separator: "\n") {
                guard let declaration = line.range(of: "static let "),
                      let assignment = line.range(of: " = \"$", range: declaration.upperBound..<line.endIndex),
                      let valueEnd = line[assignment.upperBound...].firstIndex(of: "\"") else {
                    continue
                }
                let symbol = line[declaration.upperBound..<assignment.lowerBound]
                let value = "$" + line[assignment.upperBound..<valueEnd]
                declarations["\(file.owner).\(symbol)"] = String(value)
            }
        }

        return declarations
    }

    private func assertAdmissionTicketProducerCapturesRemainWired() throws {
        let runner = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/Nuxie/Journey/Execution/JourneyRunner.swift"
            ),
            encoding: .utf8
        )
        let runnerCaptures = [
            ("    private func dispatchScreenChanged(", "SystemEventNames.screenShown"),
            ("    func handleScreenDismissed(", "SystemEventNames.screenDismissed"),
            ("    private func dispatchProductsUnavailableEvent(",
             "SystemEventNames.productsUnavailable"),
        ]
        for (signature, event) in runnerCaptures {
            let body = try functionBody(in: runner, startingWith: signature)
            XCTAssertTrue(body.contains(event), "\(event) left its real producer")
            XCTAssertEqual(
                body.components(separatedBy: "eventLog.trackWithoutRouting(").count - 1,
                1,
                "\(event) no longer enters the processCapture lane"
            )
        }

        let journeyService = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/Nuxie/Journey/JourneyService.swift"
            ),
            encoding: .utf8
        )
        let scopedPermissionBody = try functionBody(
            in: journeyService,
            startingWith: "  func handleScopedPermissionEvent("
        )
        XCTAssertTrue(scopedPermissionBody.contains("name: eventName"))
        XCTAssertTrue(scopedPermissionBody.contains("trackScopedEvent("))
        XCTAssertTrue(scopedPermissionBody.contains("persistToHistory: true"))
        XCTAssertTrue(scopedPermissionBody.contains("applyBeforeSend: true"))

        let unsupportedPermissionBody = try functionBody(
            in: journeyService,
            startingWith: "  func handleUnsupportedScopedRequestPermission("
        )
        XCTAssertTrue(
            unsupportedPermissionBody.contains("name: SystemEventNames.permissionDenied")
        )
        XCTAssertTrue(unsupportedPermissionBody.contains("trackScopedEvent("))
        XCTAssertTrue(unsupportedPermissionBody.contains("persistToHistory: true"))
        XCTAssertTrue(unsupportedPermissionBody.contains("applyBeforeSend: true"))

        let controller = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/Nuxie/Experiences/ExperienceViewController.swift"
            ),
            encoding: .utf8
        )
        let permissionProducers = [
            ("    func performRequestNotifications(", [
                "SystemEventNames.notificationsEnabled",
                "SystemEventNames.notificationsDenied",
                "dispatchNotificationPermissionEvent(",
            ]),
            ("    func performRequestPermission(", [
                "SystemEventNames.permissionGranted",
                "SystemEventNames.permissionDenied",
                "dispatchRequestPermissionEvent(",
            ]),
            ("    func performRequestTracking(", [
                "SystemEventNames.trackingAuthorized",
                "SystemEventNames.trackingDenied",
                "dispatchTrackingPermissionEvent(",
            ]),
        ]
        for (signature, requiredCalls) in permissionProducers {
            let body = try functionBody(in: controller, startingWith: signature)
            for requiredCall in requiredCalls {
                XCTAssertTrue(body.contains(requiredCall), "Missing \(requiredCall) in \(signature)")
            }
        }

        let sdk = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/Nuxie/NuxieSDK.swift"),
            encoding: .utf8
        )
        let acceptedFeatureBody = try functionBody(
            in: sdk,
            startingWith: "  private func captureAcceptedFeatureUse("
        )
        XCTAssertTrue(
            acceptedFeatureBody.contains("name: SystemEventNames.featureUsed")
        )
        XCTAssertTrue(
            acceptedFeatureBody.contains("await eventLog.storePreparedEventInHistory(prepared)"),
            "Accepted feature use must remain durable"
        )
    }

    private func functionBody(
        in source: String,
        startingWith signature: String
    ) throws -> Substring {
        let signatureRange = try XCTUnwrap(source.range(of: signature), signature)
        let openBrace = try XCTUnwrap(
            source[signatureRange.lowerBound...].firstIndex(of: "{"),
            signature
        )
        var depth = 0
        for index in source.indices[openBrace...] {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return source[openBrace...index] }
            default:
                break
            }
        }
        throw NSError(
            domain: "EventCatalogConformanceTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unterminated function: \(signature)"]
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
