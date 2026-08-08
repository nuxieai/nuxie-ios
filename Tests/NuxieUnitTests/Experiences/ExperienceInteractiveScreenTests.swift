#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@testable import Nuxie

final class ExperienceInteractiveScreenTests: XCTestCase {
    func testRouterPreservesPhaseAndCommandOrderWithExactCorrelations() {
        var router = ExperienceInteractiveEffectRouter()
        let reported = ExperienceInteractiveReportedEvent(
            name: "opened",
            url: "",
            target: "",
            delay: 0,
            properties: []
        )
        let change = ExperienceInteractiveViewModelChange(
            origin: .runtime,
            correlationID: 77,
            ownerInstanceID: 4,
            propertyIndex: 2,
            value: .number(5)
        )
        let effects = router.project(
            reportedEvents: [reported],
            viewModelChanges: [change],
            hostCommands: scriptedCommands,
            declaredEventNames: ["purchase_tapped", "selection_changed"],
            validScreenIDs: ["screen_1", "screen_2"],
            correlationID: 42
        )

        XCTAssertEqual(effects.map(\.sequence), Array(0...6))
        XCTAssertEqual(effects.map(\.correlationID), [42, 77, 42, 42, 42, 42, 42])
        XCTAssertEqual(
            effects.map(\.kind),
            [
                .reportedEvent(reported),
                .viewModelChange(change),
                .responseSet(field: "plan", value: .string("pro")),
                .journeyEvent(name: "purchase_tapped", payload: Self.object([
                    ("placementIndex", .number(2)),
                    ("productId", .string("pro_annual")),
                ])),
                .journeyEvent(name: "selection_changed", payload: Self.object([
                    ("value", .string("annual"))
                ])),
                .hostCommand(name: "custom.analytics", payload: Self.object([
                    ("channel", .string("editor")),
                    ("sampled", .bool(true)),
                ])),
                .rejectedHostCommand(
                    name: "$response_set",
                    reason: "expected a non-empty string field and a value"
                ),
            ]
        )

        let next = router.project(
            reportedEvents: [],
            viewModelChanges: [],
            hostCommands: [ExperienceInteractiveHostCommand(
                name: "$navigate",
                payload: Self.object([
                    ("screenId", .string("screen_2")),
                    ("transition", .string("push")),
                ])
            )],
            declaredEventNames: [],
            validScreenIDs: ["screen_1", "screen_2"],
            correlationID: 100
        )
        XCTAssertEqual(next, [ExperienceInteractiveEffect(
            sequence: 7,
            correlationID: 100,
            kind: .navigate(screenID: "screen_2", transition: "push")
        )])
    }

    func testMalformedNavigationIsAProductRejectionAndDoesNotDropItsSiblings() {
        var router = ExperienceInteractiveEffectRouter()
        let effects = router.project(
            reportedEvents: [],
            viewModelChanges: [],
            hostCommands: [
                ExperienceInteractiveHostCommand(
                    name: "$navigate",
                    payload: Self.object([("screenId", .string("unsigned-screen"))])
                ),
                ExperienceInteractiveHostCommand(
                    name: "custom.after",
                    payload: .null
                ),
            ],
            declaredEventNames: [],
            validScreenIDs: ["screen_1"],
            correlationID: 9
        )

        XCTAssertEqual(effects, [
            ExperienceInteractiveEffect(
                sequence: 0,
                correlationID: 9,
                kind: .rejectedHostCommand(
                    name: "$navigate",
                    reason: "expected a declared screenId"
                )
            ),
            ExperienceInteractiveEffect(
                sequence: 1,
                correlationID: 9,
                kind: .hostCommand(name: "custom.after", payload: .null)
            ),
        ])
    }

    private var scriptedCommands: [ExperienceInteractiveHostCommand] {
        [
            ExperienceInteractiveHostCommand(
                name: "$response_set",
                payload: Self.object([
                    ("field", .string("plan")),
                    ("value", .string("pro")),
                ])
            ),
            ExperienceInteractiveHostCommand(
                name: "purchase_tapped",
                payload: Self.object([
                    ("placementIndex", .number(2)),
                    ("productId", .string("pro_annual")),
                ])
            ),
            ExperienceInteractiveHostCommand(
                name: "selection_changed",
                payload: Self.object([("value", .string("annual"))])
            ),
            ExperienceInteractiveHostCommand(
                name: "custom.analytics",
                payload: Self.object([
                    ("channel", .string("editor")),
                    ("sampled", .bool(true)),
                ])
            ),
            ExperienceInteractiveHostCommand(
                name: "$response_set",
                payload: Self.object([
                    ("field", .number(42)),
                    ("value", .string("rejected-in-swift")),
                ])
            ),
        ]
    }

    private static func object(
        _ fields: [(String, ExperienceInteractiveValue)]
    ) -> ExperienceInteractiveValue {
        .object(fields.map { ExperienceInteractiveField(key: $0.0, value: $0.1) })
    }
}
#endif
