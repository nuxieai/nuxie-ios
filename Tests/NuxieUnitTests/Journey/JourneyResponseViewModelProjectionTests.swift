import XCTest
@_spi(Testing) @testable import Nuxie

final class JourneyResponseViewModelProjectionTests: XCTestCase {
    private func projection(answers: ExactJSONObject<JourneyReleaseJSONValue> = [:]) -> JourneyResponseViewModelProjection {
        JourneyResponseViewModelProjection(screens: [
            .init(id: "choice", defaultViewModelName: "Choice", defaultInstanceId: "choice-instance", responseCaptures: ["goal"]),
            .init(id: "summary", defaultViewModelName: "Summary", defaultInstanceId: "summary-instance", responseCaptures: []),
            .init(id: "other", defaultViewModelName: "Other", defaultInstanceId: "other-instance", responseCaptures: [])
        ], defaults: [
            .init(viewModelName: "Choice", instanceId: "choice-instance", path: "response/values/goal", value: AnyCodable("")),
            .init(viewModelName: "Summary", instanceId: "summary-instance", path: "response/values/goal", value: AnyCodable("Choose a goal")),
            .init(viewModelName: "Choice", instanceId: "choice-instance", path: "vars/videoProgress", value: AnyCodable(0.5)),
            .init(viewModelName: "Other", instanceId: "other-instance", path: "vars/private", value: AnyCodable("private"))
        ], answers: answers)
    }

    private func emission(_ name: String, field: String = "goal", value: ScreenEmissionValue? = nil) -> ScreenEmission {
        var payload: [String: ScreenEmissionValue] = ["field": .string(field)]
        payload["value"] = value
        return .init(id: "emission", sequence: 1, occurredAt: "2026-09-24T00:00:00Z", name: name, payload: payload)
    }

    func testCommittedChoiceUpdatesReadOnlyConsumersWithoutTouchingVideoState() throws {
        var subject = projection()
        let fields = subject.accept([emission("$response_set", value: .string("Strength"))])
        XCTAssertEqual(fields, ["goal"])
        for screen in ["choice", "summary"] {
            let values = subject.values(screenID: screen)
            XCTAssertEqual(values.count, 1)
            XCTAssertEqual(values.first?.value.value as? String, "Strength")
            XCTAssertEqual(values.first?.path, "response/values/goal")
        }
        XCTAssertTrue(subject.values(screenID: "other").isEmpty)
    }

    func testLastCommittedChoiceWinsAndUnsetRestoresEachConsumersDefault() {
        var subject = projection()
        _ = subject.accept([emission("$response_set", value: .string("Strength")), emission("$response_set", value: .string("Endurance"))])
        XCTAssertEqual(subject.values(screenID: "choice").first?.value.value as? String, "Endurance")
        _ = subject.accept([emission("$response_unset")])
        XCTAssertEqual(subject.values(screenID: "choice").first?.value.value as? String, "")
        XCTAssertEqual(subject.values(screenID: "summary").first?.value.value as? String, "Choose a goal")
    }

    func testRestoredJournalAnswersAreVisibleBeforeAnyNewChoice() {
        let subject = projection(answers: ["goal": .string("Energy")])
        XCTAssertEqual(subject.values(screenID: "summary").first?.value.value as? String, "Energy")
    }

    func testOrdinaryEventsCannotWriteResponseBindings() {
        var subject = projection()
        let fields = subject.accept([emission("goal_selected", value: .string("Forged"))])
        XCTAssertTrue(fields.isEmpty)
        XCTAssertTrue(subject.values(screenID: "choice", fields: fields).isEmpty)
        XCTAssertEqual(subject.values(screenID: "choice").first?.value.value as? String, "")
    }
}
