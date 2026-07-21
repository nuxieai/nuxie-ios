import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class FlowRuntimeTraceTests: QuickSpec {
    override class func spec() {
        describe("FlowRuntimeTraceRecorder") {
            it("records navigation and binding entries in deterministic step order") {
                let recorder = FlowRuntimeTraceRecorder()

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

                expect(trace.schemaVersion).to(equal(FlowRuntimeTrace.currentSchemaVersion))
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
                let recorder = FlowRuntimeTraceRecorder()

                recorder.recordEvent(
                    name: "$flow_shown",
                    properties: [
                        "flow_id": "flow-1",
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
                expect(entry?.name).to(equal("$flow_shown"))
                expect(entry?.screenId).to(equal("screen-entry"))
                expect(entry?.output).to(equal("{\"flow_id\":\"flow-1\",\"nested\":{\"a\":1,\"b\":2},\"screen_id\":\"screen-entry\"}"))
            }

            it("ingests tracked events and supports codable round-trip") {
                let recorder = FlowRuntimeTraceRecorder()
                recorder.ingestTrackedEvents([
                    (name: "$flow_artifact_load_succeeded", properties: ["flow_id": "flow-abc"]),
                    (name: "$flow_dismissed", properties: ["flow_id": "flow-abc"]),
                ])

                let trace = recorder.trace(
                    fixtureId: "fixture-round-trip",
                    runtime: "native"
                )

                let data = try! JSONEncoder().encode(trace)
                let decoded = try! JSONDecoder().decode(FlowRuntimeTrace.self, from: data)

                expect(decoded).to(equal(trace))
                expect(decoded.entries.map(\.kind)).to(equal([.event, .event]))
            }

            it("records renderer screen change notifications") {
                let recorder = FlowRuntimeTraceRecorder()

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
}
