import Foundation
import XCTest
@testable import Nuxie

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
        ("JourneyEvents.experiencePurchased", JourneyEvents.experiencePurchased),
        ("JourneyEvents.experienceShown", JourneyEvents.experienceShown),
        ("JourneyEvents.experienceTimedOut", JourneyEvents.experienceTimedOut),
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
        "$experience_purchased": "hidden: scheduled for pre-GA deletion",
        "$experience_shown": "experienceShown",
        "$experience_timed_out": "hidden: scheduled for pre-GA deletion",
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

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
