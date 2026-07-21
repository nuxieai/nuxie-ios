import Foundation
import Quick
import Nimble
@testable import Nuxie

final class FlowViewModelStateCoordinatorTests: QuickSpec {
    override class func spec() {
        func makeRemoteFlow(
            values: [RemoteFlowViewModelValue] = [],
            screens: [RemoteFlowScreen]? = nil,
            handlers: RemoteFlowHandlerMap = [:]
        ) -> RemoteFlow {
            RemoteFlow(
                id: "flow-runtime",
                flowArtifact: FlowArtifact(
                    url: "https://example.com/flow/runtime",
                    manifest: BuildManifest(
                        totalFiles: 1,
                        totalSize: 100,
                        contentHash: "runtime-hash",
                        files: [BuildFile(path: "flow.riv", size: 100, contentType: "application/octet-stream")]
                    )
                ),
                screens: screens ?? [
                    RemoteFlowScreen(
                        id: "screen-1",
                        defaultViewModelName: "Runtime",
                        defaultInstanceId: "runtime-instance"
                    )
                ],
                handlers: handlers,
                viewModelValues: values
            )
        }

        func value(
            viewModelName: String = "Runtime",
            instanceId: String? = "runtime-instance",
            instanceName: String? = "Runtime",
            path: String,
            _ rawValue: Any
        ) -> RemoteFlowViewModelValue {
            RemoteFlowViewModelValue(
                viewModelName: viewModelName,
                instanceId: instanceId,
                instanceName: instanceName,
                path: path,
                value: AnyCodable(rawValue)
            )
        }

        func path(
            _ propertyPath: String,
            viewModelName: String? = "Runtime",
            isRelative: Bool? = nil
        ) -> VmPathRef {
            VmPathRef(viewModelName: viewModelName, path: propertyPath, isRelative: isRelative)
        }

        func ints(_ rawValue: Any?) -> [Int]? {
            guard let array = rawValue as? [Any] else { return nil }
            return array.compactMap { item in
                if let int = item as? Int { return int }
                if let number = item as? NSNumber { return number.intValue }
                return nil
            }
        }

        describe("ExperienceViewModelStateCoordinator") {
            it("hydrates and reads path/value entries without a schema bucket") {
                let coordinator = ExperienceViewModelStateCoordinator(screens: makeRemoteFlow(values: [
                    value(path: "title", "Welcome"),
                    value(path: "paywall/selectedProductId", "draft:paywall:0"),
                ]))

                expect(coordinator.getValue(path: path("title"), screenId: "screen-1") as? String)
                    .to(equal("Welcome"))
                expect(coordinator.getValue(path: path("paywall/selectedProductId"), screenId: "screen-1") as? String)
                    .to(equal("draft:paywall:0"))
            }

            it("writes path/value entries and persists a compact snapshot") {
                let coordinator = ExperienceViewModelStateCoordinator(screens: makeRemoteFlow(values: [
                    value(path: "title", "Before"),
                ]))

                expect(coordinator.setValue(path: path("title"), value: "After", screenId: "screen-1"))
                    .to(beTrue())
                expect(coordinator.setValue(
                    path: path("count"),
                    value: AnyCodable(["literal": 3] as [String: Any]),
                    screenId: "screen-1"
                ))
                    .to(beTrue())

                let snapshot = coordinator.getSnapshot()
                let valuesByPath = Dictionary(uniqueKeysWithValues: snapshot.values.map { ($0.path, $0.value.value) })
                expect(valuesByPath["title"] as? String).to(equal("After"))
                expect(valuesByPath["count"] as? Int).to(equal(3))
                expect(snapshot.viewModelInstances.first?.viewModelId).to(equal("Runtime"))
            }

            it("keeps instance-scoped values separate") {
                let coordinator = ExperienceViewModelStateCoordinator(screens: makeRemoteFlow(values: [
                    value(instanceId: "welcome-instance", instanceName: "Welcome", path: "title", "Welcome"),
                    value(instanceId: "paywall-instance", instanceName: "Paywall", path: "title", "Paywall"),
                ]))

                expect(coordinator.getValue(
                    path: path("title"),
                    screenId: "screen-1",
                    instanceId: "welcome-instance"
                ) as? String)
                    .to(equal("Welcome"))
                expect(coordinator.getValue(
                    path: path("title"),
                    screenId: "screen-1",
                    instanceId: "paywall-instance"
                ) as? String)
                    .to(equal("Paywall"))
            }

            it("resolves relative paths through the provided instance id") {
                let coordinator = ExperienceViewModelStateCoordinator(screens: makeRemoteFlow(values: [
                    value(
                        viewModelName: "Reason Item",
                        instanceId: "reason-0",
                        instanceName: nil,
                        path: "value",
                        "Too expensive"
                    ),
                ]))

                expect(coordinator.getValue(
                    path: path("value", viewModelName: nil, isRelative: true),
                    screenId: "screen-1",
                    instanceId: "reason-0"
                ) as? String)
                    .to(equal("Too expensive"))
            }

            it("resolves omitted default view model names from the screen default instance") {
                let coordinator = ExperienceViewModelStateCoordinator(screens: makeRemoteFlow(
                    values: [
                        value(
                            viewModelName: "Nested",
                            instanceId: "nested-instance",
                            instanceName: nil,
                            path: "title",
                            "Nested title"
                        ),
                    ],
                    screens: [
                        RemoteFlowScreen(
                            id: "screen-1",
                            defaultViewModelName: nil,
                            defaultInstanceId: "nested-instance"
                        ),
                    ]
                ))

                expect(coordinator.getValue(
                    path: path("title", viewModelName: nil, isRelative: true),
                    screenId: "screen-1"
                ) as? String)
                    .to(equal("Nested title"))
            }

            it("does not reuse the screen default instance for explicit refs to another view model") {
                let coordinator = ExperienceViewModelStateCoordinator(screens: makeRemoteFlow(
                    values: [
                        value(
                            viewModelName: "Runtime",
                            instanceId: "runtime-instance",
                            instanceName: "Runtime",
                            path: "title",
                            "Runtime title"
                        ),
                        value(
                            viewModelName: "Other",
                            instanceId: "other-instance",
                            instanceName: "Other",
                            path: "title",
                            "Other title"
                        ),
                    ],
                    screens: [
                        RemoteFlowScreen(
                            id: "screen-1",
                            defaultViewModelName: "Runtime",
                            defaultInstanceId: "runtime-instance"
                        ),
                    ]
                ))

                expect(coordinator.setValue(
                    path: path("title", viewModelName: "Other"),
                    value: "Updated other",
                    screenId: "screen-1"
                ))
                    .to(beTrue())
                expect(coordinator.getValue(
                    path: path("title", viewModelName: "Other"),
                    screenId: "screen-1",
                    instanceId: "other-instance"
                ) as? String)
                    .to(equal("Updated other"))
                expect(coordinator.getValue(
                    path: path("title", viewModelName: "Runtime"),
                    screenId: "screen-1",
                    instanceId: "runtime-instance"
                ) as? String)
                    .to(equal("Runtime title"))
            }

            it("tracks fire-trigger action paths as trigger paths") {
                let pulse = path("pulse")
                let coordinator = ExperienceViewModelStateCoordinator(screens: makeRemoteFlow(
                    handlers: [
                        "screen-1": [
                            JourneyEventHandler(
                                id: "handler-trigger",
                                eventName: "screen_shown",
                                actions: [
                                    .fireTrigger(FireTriggerAction(path: pulse)),
                                ]
                            ),
                        ],
                    ]
                ))

                expect(coordinator.isTriggerPath(path: pulse, screenId: "screen-1")).to(beTrue())
                expect(coordinator.isTriggerPath(path: path("title"), screenId: "screen-1")).to(beFalse())
            }

            it("supports list operations on path refs") {
                let coordinator = ExperienceViewModelStateCoordinator(screens: makeRemoteFlow())

                _ = coordinator.setValue(path: path("items"), value: [1, 2, 3], screenId: nil)
                _ = coordinator.setListValue(
                    path: path("items"),
                    operation: "move",
                    payload: ["from": 0, "to": 2],
                    screenId: nil
                )
                expect(ints(coordinator.getValue(path: path("items"), screenId: nil)))
                    .to(equal([2, 3, 1]))

                _ = coordinator.setListValue(
                    path: path("items"),
                    operation: "set",
                    payload: ["index": 1, "value": 9],
                    screenId: nil
                )
                expect(ints(coordinator.getValue(path: path("items"), screenId: nil)))
                    .to(equal([2, 9, 1]))

                _ = coordinator.setListValue(
                    path: path("items"),
                    operation: "clear",
                    payload: [:],
                    screenId: nil
                )
                expect(ints(coordinator.getValue(path: path("items"), screenId: nil)))
                    .to(equal([]))
            }
        }
    }
}
