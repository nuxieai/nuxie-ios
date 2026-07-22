import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class ResponseFormControllerTests: QuickSpec {
    override class func spec() {
        func record(
            schemaId: String = "schema-1",
            schemaVersion: Int = 2,
            state: String = "draft",
            values: [String: AnyCodable] = ["email": AnyCodable("a@b.c")]
        ) -> ResponseRecordPayload {
            ResponseRecordPayload(
                id: "resp-1",
                campaignId: "camp-1",
                journeySessionId: "journey-1",
                customerId: "cust-1",
                responseSchemaId: schemaId,
                responseSchemaVersionId: "sv-1",
                schemaVersion: schemaVersion,
                state: state,
                values: values,
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0),
                submittedAt: nil,
                abandonedAt: nil
            )
        }

        describe("paths") {
            it("addresses the response view model") {
                expect(ResponseFormController.schemaIdPath) == VmPathRef(viewModelName: "vm", path: "response/schemaId")
                expect(ResponseFormController.schemaVersionPath) == VmPathRef(viewModelName: "vm", path: "response/schemaVersion")
                expect(ResponseFormController.statePath) == VmPathRef(viewModelName: "vm", path: "response/state")
                expect(ResponseFormController.valuePath(forKey: "email"))
                    == VmPathRef(viewModelName: "vm", path: "response/values/email")
            }
        }

        describe("readRuntimeContext") {
            it("reads schema id, version, and state through the lookup") {
                let values: [String: Any] = [
                    "response/schemaId": "schema-1",
                    "response/schemaVersion": NSNumber(value: 2),
                    "response/state": "draft",
                ]
                let context = ResponseFormController.readRuntimeContext { path in
                    values[path.path]
                }
                expect(context.schemaId) == "schema-1"
                expect(context.schemaVersion) == 2
                expect(context.state) == "draft"
            }
        }

        describe("contextMatches") {
            let context = ResponseFormController.RuntimeContext(
                schemaId: "schema-1", schemaVersion: 2, state: "draft"
            )

            it("requires the schema id to match") {
                expect(ResponseFormController.contextMatches(context, responseSchemaId: "schema-1", schemaVersion: 2)) == true
                expect(ResponseFormController.contextMatches(context, responseSchemaId: "other", schemaVersion: 2)) == false
            }

            it("only compares versions when both sides have one") {
                expect(ResponseFormController.contextMatches(context, responseSchemaId: "schema-1", schemaVersion: nil)) == true
                expect(ResponseFormController.contextMatches(context, responseSchemaId: "schema-1", schemaVersion: 3)) == false
                let versionless = ResponseFormController.RuntimeContext(
                    schemaId: "schema-1", schemaVersion: nil, state: nil
                )
                expect(ResponseFormController.contextMatches(versionless, responseSchemaId: "schema-1", schemaVersion: 3)) == true
            }
        }

        describe("draftPatches") {
            it("writes the field value then marks the draft state") {
                let patches = ResponseFormController.draftPatches(key: "email", resolvedValue: "a@b.c")
                expect(patches.count) == 2
                expect(patches[0].path) == ResponseFormController.valuePath(forKey: "email")
                expect(patches[0].value as? String) == "a@b.c"
                expect(patches[1].path) == ResponseFormController.statePath
                expect(patches[1].value as? String) == "draft"
            }
        }

        describe("recordPatches") {
            it("patches state and schema version") {
                let patches = ResponseFormController.recordPatches(for: record(state: "submitted"))
                expect(patches.count) == 2
                expect(patches[0].path) == ResponseFormController.statePath
                expect(patches[0].value as? String) == "submitted"
                expect(patches[1].path) == ResponseFormController.schemaVersionPath
                expect(patches[1].value as? Int) == 2
            }

            it("includes the touched field value when present") {
                let patches = ResponseFormController.recordPatches(
                    for: record(),
                    touchedFieldKey: "email"
                )
                expect(patches.count) == 3
                expect(patches[2].path) == ResponseFormController.valuePath(forKey: "email")
                expect(patches[2].value as? String) == "a@b.c"
            }

            it("skips the touched field when the record has no value for it") {
                let patches = ResponseFormController.recordPatches(
                    for: record(values: [:]),
                    touchedFieldKey: "email"
                )
                expect(patches.count) == 2
            }
        }

        describe("response cache") {
            it("keys entries by schema id and version") {
                expect(ResponseFormController.cacheKey(responseSchemaId: "s", schemaVersion: 3)) == "s:3"
            }

            it("adds a serializable entry preserving existing ones") {
                let existing: [String: Any] = ["other:1": ["state": "submitted"]]
                let updated = ResponseFormController.updatedResponseCache(existing, adding: record())
                expect(updated.count) == 2
                let entry = updated["schema-1:2"] as? [String: Any]
                expect(entry?["responseId"] as? String) == "resp-1"
                expect(entry?["responseSchemaId"] as? String) == "schema-1"
                expect(entry?["schemaVersion"] as? Int) == 2
                expect(entry?["state"] as? String) == "draft"
                expect((entry?["values"] as? [String: Any])?["email"] as? String) == "a@b.c"
            }

            it("starts a cache from nil") {
                let updated = ResponseFormController.updatedResponseCache(nil, adding: record())
                expect(updated.count) == 1
            }
        }

        describe("hasDraftResponses") {
            it("detects non-empty drafts only") {
                let draft: [String: Any] = [
                    "s:1": ["state": "draft", "values": ["email": "a@b.c"]] as [String: Any]
                ]
                let emptyDraft: [String: Any] = [
                    "s:1": ["state": "draft", "values": [:] as [String: Any]] as [String: Any]
                ]
                let submitted: [String: Any] = [
                    "s:1": ["state": "submitted", "values": ["email": "a@b.c"]] as [String: Any]
                ]
                expect(ResponseFormController.hasDraftResponses(draft)) == true
                expect(ResponseFormController.hasDraftResponses(emptyDraft)) == false
                expect(ResponseFormController.hasDraftResponses(submitted)) == false
                expect(ResponseFormController.hasDraftResponses(nil)) == false
            }
        }

        describe("synthesizedSetResponseField") {
            it("builds the action from the $response_set payload") {
                let action = ResponseFormController.synthesizedSetResponseField(
                    schemaId: "schema-1",
                    eventProperties: ["field": "email", "value": "a@b.c"]
                )
                expect(action?.responseSchemaId) == "schema-1"
                expect(action?.key) == "email"
                expect(action?.value.value as? String) == "a@b.c"
                expect(action?.schemaVersion).to(beNil())
            }

            it("returns nil for missing schema, field, or value") {
                expect(ResponseFormController.synthesizedSetResponseField(
                    schemaId: nil,
                    eventProperties: ["field": "email", "value": "x"]
                )).to(beNil())
                expect(ResponseFormController.synthesizedSetResponseField(
                    schemaId: "",
                    eventProperties: ["field": "email", "value": "x"]
                )).to(beNil())
                expect(ResponseFormController.synthesizedSetResponseField(
                    schemaId: "s",
                    eventProperties: ["field": "", "value": "x"]
                )).to(beNil())
                expect(ResponseFormController.synthesizedSetResponseField(
                    schemaId: "s",
                    eventProperties: ["field": "email"]
                )).to(beNil())
            }
        }
    }
}
