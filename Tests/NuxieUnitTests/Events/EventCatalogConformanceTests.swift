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
    private struct OneOrMany<Value: Decodable>: Decodable {
        let values: [Value]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Value.self) {
                values = [value]
            } else {
                values = try container.decode([Value].self)
            }
        }
    }

    private struct CatalogProperty: Decodable {
        let type: String
        let required: Bool
        let source: String
    }

    private struct CatalogRow: Decodable {
        let lane: OneOrMany<String>
        let beforeSend: OneOrMany<String>
        let endpoint: OneOrMany<String>
        let persists: OneOrMany<Bool>
        let wire: OneOrMany<Bool>
        let constant: String?
        let status: String
        let properties: [String: CatalogProperty]
        let emitters: [String]
        let fixtures: [String]?
        let forwarding: String
    }

    private struct ExpectedSemantics: Equatable {
        let lane: [String]
        let beforeSend: [String]
        let endpoint: [String]
        let persists: [Bool]
        let wire: [Bool]
    }

    // Independent per-event pin for the two current durability paths:
    // ordinary EventLog capture and stable Journey/system-fact capture.
    private static let expectedSemanticRows = #"""
$app_action_requested	captureStableSystemEvent	governed	batch	true	true
$app_backgrounded	processCapture	governed	batch	true	true
$app_installed	processCapture	governed	batch	true	true
$app_opened	processCapture	governed	batch	true	true
$app_updated	processCapture	governed	batch	true	true
$customer_updated	captureStableSystemEvent	governed	batch	true	true
$experience_artifact_load_failed	processCapture	governed	batch	true	true
$experience_artifact_load_succeeded	processCapture	governed	batch	true	true
$experience_dismissed	processCapture	governed	batch	true	true
$experience_errored	processCapture	governed	batch	true	true
$experience_shown	processCapture	governed	batch	true	true
$experiment_exposure	captureStableSystemEvent	governed	batch	true	true
$feature_used	featureCommand|storePreparedEventInHistory	governed|governed	/event|none	true|true	true|false
$identify	processCapture	governed	batch	true	true
$journey_leg_started	captureStableSystemEvent	governed	batch	true	true
$journey_leg_completed	captureStableSystemEvent	governed	batch	true	true
$journey_milestone	captureStableSystemEvent	governed	batch	true	true
$notifications_denied	processCapture|captureStableSystemEvent	governed|governed	batch|batch	true|true	true|true
$notifications_enabled	processCapture|captureStableSystemEvent	governed|governed	batch|batch	true|true	true|true
$permission_denied	processCapture|captureStableSystemEvent	governed|governed	batch|batch	true|true	true|true
$permission_granted	processCapture|captureStableSystemEvent	governed|governed	batch|batch	true|true	true|true
$products_unavailable	captureStableSystemEvent	governed	batch	true	true
$purchase_cancelled	processCapture|captureStableSystemEvent	governed|governed	batch|batch	true|true	true|true
$purchase_completed	captureStableSystemEvent	governed	batch	true	true
$purchase_failed	processCapture|captureStableSystemEvent	governed|governed	batch|batch	true|true	true|true
$purchase_pending	processCapture	governed	batch	true	true
$purchase_synced	processCapture|captureStableSystemEvent	governed|governed	batch|batch	true|true	true|true
$restore_completed	processCapture|captureStableSystemEvent	governed|governed	batch|batch	true|true	true|true
$restore_failed	processCapture|captureStableSystemEvent	governed|governed	batch|batch	true|true	true|true
$restore_no_purchases	processCapture|captureStableSystemEvent	governed|governed	batch|batch	true|true	true|true
$screen_dismissed	captureStableSystemEvent	governed	batch	true	true
$screen_shown	captureStableSystemEvent	governed	batch	true	true
$tracking_authorized	processCapture|captureStableSystemEvent	governed|governed	batch|batch	true|true	true|true
$tracking_denied	processCapture|captureStableSystemEvent	governed|governed	batch|batch	true|true	true|true
"""#

    private static let declaredConstants: [(path: String, value: String)] = [
        ("JourneyEvents.appActionRequested", JourneyEvents.appActionRequested),
        ("JourneyEvents.customerUpdated", JourneyEvents.customerUpdated),
        ("JourneyEvents.experienceArtifactLoadFailed", JourneyEvents.experienceArtifactLoadFailed),
        ("JourneyEvents.experienceArtifactLoadSucceeded", JourneyEvents.experienceArtifactLoadSucceeded),
        ("JourneyEvents.experienceDismissed", JourneyEvents.experienceDismissed),
        ("JourneyEvents.experienceErrored", JourneyEvents.experienceErrored),
        ("JourneyEvents.experienceShown", JourneyEvents.experienceShown),
        ("JourneyEvents.experimentExposure", JourneyEvents.experimentExposure),
        ("JourneyEvents.journeyStarted", JourneyEvents.journeyStarted),
        ("JourneyEvents.journeyCompleted", JourneyEvents.journeyCompleted),
        ("JourneyEvents.journeyMilestone", JourneyEvents.journeyMilestone),
        ("SystemEventNames.appBackgrounded", SystemEventNames.appBackgrounded),
        ("SystemEventNames.appInstalled", SystemEventNames.appInstalled),
        ("SystemEventNames.appOpened", SystemEventNames.appOpened),
        ("SystemEventNames.appUpdated", SystemEventNames.appUpdated),
        ("SystemEventNames.featureUsed", SystemEventNames.featureUsed),
        ("SystemEventNames.identify", SystemEventNames.identify),
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
        "$experience_artifact_load_failed": "experienceLoadFailed",
        "$experience_artifact_load_succeeded": "hidden: successful artifact load is noise",
        "$experience_dismissed": "experienceDismissed",
        "$experience_errored": "experienceErrored",
        "$experience_shown": "experienceShown",
        "$experiment_exposure": "experimentExposure",
        "$feature_used": "featureUsed",
        "$identify": "hidden: identity and PII event",
        "$journey_leg_started": "journeyStarted",
        "$journey_leg_completed": "journeyCompleted",
        "$journey_milestone": "milestoneReached",
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

    func testEveryCatalogPathKeepsItsPinnedProductionSemantics() throws {
        let catalog = try loadCatalog()
        let expected = try Self.parseExpectedSemantics()
        XCTAssertEqual(Set(catalog.keys), Set(expected.keys))

        for (eventName, row) in catalog {
            let actual = ExpectedSemantics(
                lane: row.lane.values,
                beforeSend: row.beforeSend.values,
                endpoint: row.endpoint.values,
                persists: row.persists.values,
                wire: row.wire.values
            )
            XCTAssertEqual(actual, expected[eventName], eventName)
        }
    }

    func testCanonicalPropertyContractsMatchProductionShapes() throws {
        let catalog = try loadCatalog()

        let exposure = try XCTUnwrap(catalog[JourneyEvents.experimentExposure])
        for property in [
            "journey_id",
            "experience_id",
            "experience_version",
            "leg_id",
            "leg_generation",
            "experiment_key",
            "variant_key",
            "is_holdout",
            "assignment_source",
        ] {
            XCTAssertEqual(exposure.properties[property]?.required, true, property)
        }

        let started = try XCTUnwrap(catalog[JourneyEvents.journeyStarted])
        for property in [
            "journey_id",
            "experience_id",
            "experience_version_id",
            "leg_id",
            "leg_generation",
            "started_at",
        ] {
            XCTAssertEqual(started.properties[property]?.required, true, property)
        }

        let completed = try XCTUnwrap(catalog[JourneyEvents.journeyCompleted])
        for property in [
            "journey_id",
            "experience_id",
            "experience_version_id",
            "leg_id",
            "leg_generation",
            "started_at",
            "completed_at",
            "outcome",
            "outputs",
        ] {
            XCTAssertEqual(completed.properties[property]?.required, true, property)
        }

        let milestone = try XCTUnwrap(catalog[JourneyEvents.journeyMilestone])
        for property in [
            "journey_id",
            "experience_id",
            "experience_version_id",
            "leg_id",
            "leg_generation",
            "milestone_id",
        ] {
            XCTAssertEqual(milestone.properties[property]?.required, true, property)
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
            _ = await log.captureAndRouteSystemEvent(.init(
                name: eventName,
                properties: experienceProperties,
                eventId: UUID().uuidString,
                distinctId: "customer-1"
            ))
        }

        let featureProperties: [String: Any] = [
            "feature_id": "feature-1",
            "amount": 2.0,
            "entity_id": "entity-1",
        ]
        let enrichedFeatureProperties = await log.prepareEventProperties(featureProperties)
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

    private static func parseExpectedSemantics() throws -> [String: ExpectedSemantics] {
        var result: [String: ExpectedSemantics] = [:]
        for line in expectedSemanticRows.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 6 else {
                throw NSError(
                    domain: "EventCatalogConformanceTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Malformed semantic pin: \(line)"]
                )
            }
            func strings(_ field: Substring) -> [String] {
                field.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            }
            func booleans(_ field: Substring) throws -> [Bool] {
                try strings(field).map { value in
                    switch value {
                    case "true": true
                    case "false": false
                    default:
                        throw NSError(
                            domain: "EventCatalogConformanceTests",
                            code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "Invalid boolean pin: \(value)"]
                        )
                    }
                }
            }
            let eventName = String(fields[0])
            result[eventName] = ExpectedSemantics(
                lane: strings(fields[1]),
                beforeSend: strings(fields[2]),
                endpoint: strings(fields[3]),
                persists: try booleans(fields[4]),
                wire: try booleans(fields[5])
            )
        }
        return result
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
        let journeyService = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/Nuxie/Journey/JourneyService.swift"
            ),
            encoding: .utf8
        )
        let journeyLifecycleProducers = [
            ("    private func handlePresentationScreenChanged(",
             "SystemEventNames.screenShown"),
            ("    private func handlePresentationScreenDismissed(",
             "SystemEventNames.screenDismissed"),
            ("    private func handlePresentationProductsUnavailable(",
             "SystemEventNames.productsUnavailable"),
        ]
        for (signature, event) in journeyLifecycleProducers {
            let body = try functionBody(in: journeyService, startingWith: signature)
            XCTAssertTrue(body.contains(event), "\(event) left its real producer")
            XCTAssertTrue(
                body.contains("handlePresentationLifecycleEvent("),
                "\(event) no longer enters Journey's stable lifecycle capture"
            )
        }

        let permissionBody = try functionBody(
            in: journeyService,
            startingWith: "    private func handlePresentationPermissionEvent("
        )
        XCTAssertTrue(permissionBody.contains("name: eventName"))
        XCTAssertTrue(permissionBody.contains("events.captureAndRouteSystemEvent("))

        let presentationCaptureBody = try functionBody(
            in: journeyService,
            startingWith: "    private func capturePresentationEvent("
        )
        XCTAssertTrue(presentationCaptureBody.contains("presentationPublications.capture("))

        let publicationCoordinator = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/Nuxie/Journey/Execution/JourneyPresentationPublicationCoordinator.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(
            publicationCoordinator.contains("events.captureAndRouteSystemEventBatch("),
            "Journey presentation facts must use the stable batch capture lane"
        )

        let controller = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/Nuxie/Experiences/ExperienceViewController.swift"
            ),
            encoding: .utf8
        )
        let permissionProducers = [
            ("    func performRequestNotifications(", [
                "notificationPermissionEventName(",
                "dispatchNotificationPermissionEvent(",
            ]),
            ("    func performRequestPermission(", [
                "requestPermissionEventName(",
                "dispatchRequestPermissionEvent(",
            ]),
            ("    func performRequestTracking(", [
                "trackingPermissionEventName(",
                "dispatchTrackingPermissionEvent(",
            ]),
        ]
        for (signature, requiredCalls) in permissionProducers {
            let body = try functionBody(in: controller, startingWith: signature)
            for requiredCall in requiredCalls {
                XCTAssertTrue(body.contains(requiredCall), "Missing \(requiredCall) in \(signature)")
            }
        }
        let permissionMappings = [
            ("    func notificationPermissionEventName(", [
                "SystemEventNames.notificationsEnabled",
                "SystemEventNames.notificationsDenied",
            ]),
            ("    func requestPermissionEventName(", [
                "SystemEventNames.permissionGranted",
                "SystemEventNames.permissionDenied",
            ]),
            ("    func trackingPermissionEventName(", [
                "SystemEventNames.trackingAuthorized",
                "SystemEventNames.trackingDenied",
            ]),
        ]
        for (signature, eventNames) in permissionMappings {
            let body = try functionBody(in: controller, startingWith: signature)
            for eventName in eventNames {
                XCTAssertTrue(
                    body.contains(eventName),
                    "Missing \(eventName) in \(signature)"
                )
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
