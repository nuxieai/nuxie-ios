#if canImport(UIKit)
import Foundation
@testable import Nuxie
import UIKit
import XCTest
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

@MainActor
final class FlowTextInputOverlayBridgeTests: XCTestCase {
    @MainActor
    private struct Harness {
        let bridge: FlowTextInputOverlayBridge
        let surfaceView: UIView
        let artifact: LoadedFlowArtifact
        let bootstrap: FlowRuntimeBootstrap
        let writes: WriteRecorder

        func field() throws -> UITextField {
            try XCTUnwrap(
                surfaceView.subviews.first {
                    $0.accessibilityIdentifier == "nuxie-text-input-text-input/screen_1/email_input"
                } as? UITextField
            )
        }

        func rebind() {
            bridge.bind(
                screenId: "screen_1",
                artifact: artifact,
                surfaceView: surfaceView,
                bootstrap: bootstrap,
                textWriter: writes.write
            )
        }
    }

    @MainActor
    private final class WriteRecorder {
        struct Write: Equatable {
            let text: String
            let runName: String
        }

        private(set) var writes: [Write] = []
        var result: Result<FlowRuntimeOperationResult, Error> = .success(
            FlowRuntimeOperationResult(
                renderOutcome: .notRequested,
                isDirty: true,
                isSettled: false,
                wakeAfter: 0
            )
        )

        func write(
            _ text: String,
            _ runName: String,
            _ completion: @escaping @MainActor (
                Result<FlowRuntimeOperationResult, Error>
            ) -> Void
        ) {
            writes.append(Write(text: text, runName: runName))
            completion(result)
        }
    }

    private enum TestError: FlowRuntimeSessionFailureDisposition {
        case missingRun

        var invalidatesSession: Bool { false }
    }

    private enum TerminalTestError: Error {
        case failed
    }

    private var commits: [(input: FlowArtifactTextInput, text: String)] = []

    override func setUp() {
        super.setUp()
        commits = []
    }

    func testBindSeedsNamedTextRunAndLaysOutFromBootstrapGeometry() throws {
        let harness = try makeHarness()
        let field = try harness.field()

        XCTAssertEqual(
            harness.writes.writes,
            [.init(text: "levi@nuxie.dev", runName: "email_input Run")]
        )
        // The authored artboard starts at (10, 20). The shared contain/center
        // transform, not manifest dimensions, maps (30, 60) to (20, 40).
        XCTAssertEqual(field.frame.origin.x, 20, accuracy: 0.001)
        XCTAssertEqual(field.frame.origin.y, 40, accuracy: 0.001)
        XCTAssertEqual(field.frame.width, 150, accuracy: 0.001)
        XCTAssertEqual(field.frame.height, 40, accuracy: 0.001)
        XCTAssertFalse(field.isHidden)
    }

    func testScalarGeometryOutputUpdatesLeafIdentityBeforeLayout() throws {
        let harness = try makeHarness()
        let field = try harness.field()
        let result = FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: false,
            orderedOutputs: [
                FlowRuntimeOutput(
                    sequence: 1,
                    cycle: 1,
                    phase: .viewModelChanges,
                    payload: .viewModelChange(FlowRuntimeStateChange(
                        instanceID: instanceID(3),
                        path: "x",
                        value: .number(80),
                        originMutationID: nil
                    ))
                ),
                FlowRuntimeOutput(
                    sequence: 2,
                    cycle: 1,
                    phase: .hostWork,
                    payload: .hostCommand(
                        name: "typed",
                        payload: .object(.empty)
                    )
                ),
            ]
        )

        let stateResult = harness.bridge.consume(result)
        harness.bridge.layout()

        XCTAssertEqual(field.frame.origin.x, 70, accuracy: 0.001)
        XCTAssertFalse(field.isHidden)
        XCTAssertEqual(stateResult.orderedOutputs.map(\.sequence), [2])
    }

    func testMalformedRuntimeGeometryUpdateHidesAndDiagnosesControl() throws {
        let harness = try makeHarness()
        let field = try harness.field()
        var diagnostics: [FlowRuntimeDiagnostic] = []
        harness.bridge.onDiagnostic = { diagnostics.append($0) }
        let result = FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: false,
            orderedOutputs: [
                FlowRuntimeOutput(
                    sequence: 1,
                    cycle: 1,
                    phase: .viewModelChanges,
                    payload: .viewModelChange(FlowRuntimeStateChange(
                        instanceID: instanceID(3),
                        path: "width",
                        value: .string("not-a-number"),
                        originMutationID: nil
                    ))
                ),
                FlowRuntimeOutput(
                    sequence: 2,
                    cycle: 1,
                    phase: .hostWork,
                    payload: .hostCommand(name: "kept", payload: .object(.empty))
                ),
            ]
        )

        let projected = harness.bridge.consume(result)
        harness.bridge.layout()

        XCTAssertTrue(field.isHidden)
        XCTAssertEqual(projected.orderedOutputs.map(\.sequence), [2])
        XCTAssertEqual(
            diagnostics.map(\.code),
            ["nuxie_ios.text_input_geometry_bind_failed"]
        )
    }

    func testProvisionalBootstrapGeometryRecoversFromFirstAdvanceOutputs() throws {
        let artifact = try makeArtifact()
        let surfaceView = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let recorder = WriteRecorder()
        let bridge = FlowTextInputOverlayBridge()
        var diagnostics: [FlowRuntimeDiagnostic] = []
        bridge.onDiagnostic = { diagnostics.append($0) }

        let valid = makeBootstrap()
        var provisionalNodes = valid.values.nodes
        provisionalNodes[5] = FlowRuntimeValueNode(value: .scalar(.number(0)))
        provisionalNodes[6] = FlowRuntimeValueNode(value: .scalar(.number(0)))
        let provisional = FlowRuntimeBootstrap(
            player: valid.player,
            catalog: valid.catalog,
            values: FlowRuntimeValueArena(
                nodes: provisionalNodes,
                roots: valid.values.roots
            )
        )
        bridge.bind(
            screenId: "screen_1",
            artifact: artifact,
            surfaceView: surfaceView,
            bootstrap: provisional,
            textWriter: recorder.write
        )
        let field = try XCTUnwrap(surfaceView.subviews.first as? UITextField)
        XCTAssertTrue(field.isHidden)

        let projected = bridge.consume(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: false,
            orderedOutputs: [
                FlowRuntimeOutput(
                    sequence: 1,
                    cycle: 1,
                    phase: .viewModelChanges,
                    payload: .viewModelChange(FlowRuntimeStateChange(
                        instanceID: instanceID(3),
                        path: "width",
                        value: .number(150),
                        originMutationID: nil
                    ))
                ),
                FlowRuntimeOutput(
                    sequence: 2,
                    cycle: 1,
                    phase: .viewModelChanges,
                    payload: .viewModelChange(FlowRuntimeStateChange(
                        instanceID: instanceID(3),
                        path: "height",
                        value: .number(40),
                        originMutationID: nil
                    ))
                ),
            ]
        ))
        // Result projection updates reserved geometry without making UIKit
        // visible before the screen routes the rest of the result phases.
        XCTAssertTrue(field.isHidden)
        bridge.layout()

        XCTAssertTrue(projected.orderedOutputs.isEmpty)
        XCTAssertFalse(field.isHidden)
        XCTAssertEqual(field.frame.width, 225, accuracy: 0.001)
        XCTAssertEqual(field.frame.height, 40, accuracy: 0.001)
        XCTAssertEqual(
            diagnostics.map(\.code),
            ["nuxie_ios.text_input_geometry_bind_failed"]
        )
    }

    func testMalformedGeometryStillFiltersExactLeafShortPaths() throws {
        let artifact = try makeArtifact()
        let surfaceView = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let recorder = WriteRecorder()
        let bridge = FlowTextInputOverlayBridge()
        var diagnostics: [FlowRuntimeDiagnostic] = []
        bridge.onDiagnostic = { diagnostics.append($0) }

        let valid = makeBootstrap()
        var malformedNodes = valid.values.nodes
        // The leaf identity and field graph remain discoverable, but width is
        // no longer a usable authored geometry scalar.
        malformedNodes[5] = FlowRuntimeValueNode(
            value: .scalar(.string("not-a-number"))
        )
        let malformed = FlowRuntimeBootstrap(
            player: valid.player,
            catalog: valid.catalog,
            values: FlowRuntimeValueArena(
                nodes: malformedNodes,
                roots: valid.values.roots
            )
        )
        bridge.bind(
            screenId: "screen_1",
            artifact: artifact,
            surfaceView: surfaceView,
            bootstrap: malformed,
            textWriter: recorder.write
        )

        let projected = bridge.consume(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: false,
            orderedOutputs: [
                FlowRuntimeOutput(
                    sequence: 1,
                    cycle: 1,
                    phase: .viewModelChanges,
                    payload: .viewModelChange(FlowRuntimeStateChange(
                        instanceID: instanceID(3),
                        path: "x",
                        value: .number(80),
                        originMutationID: nil
                    ))
                ),
                FlowRuntimeOutput(
                    sequence: 2,
                    cycle: 1,
                    phase: .hostWork,
                    payload: .hostCommand(name: "kept", payload: .object(.empty))
                ),
            ]
        ))
        bridge.layout()

        XCTAssertEqual(projected.orderedOutputs.map(\.sequence), [2])
        XCTAssertTrue(try XCTUnwrap(surfaceView.subviews.first as? UITextField).isHidden)
        XCTAssertEqual(
            diagnostics.map(\.code),
            ["nuxie_ios.text_input_geometry_bind_failed"]
        )
    }

    func testUndeclaredReservedChildFiltersItsEntireDirectOutputSubtree() throws {
        let artifact = try makeArtifact(includeInput: false)
        let surfaceView = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let recorder = WriteRecorder()
        let bridge = FlowTextInputOverlayBridge()
        bridge.bind(
            screenId: "screen_1",
            artifact: artifact,
            surfaceView: surfaceView,
            bootstrap: makeBootstrap(),
            textWriter: recorder.write
        )

        let projected = bridge.consume(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: false,
            orderedOutputs: [
                FlowRuntimeOutput(
                    sequence: 1,
                    cycle: 1,
                    phase: .viewModelChanges,
                    payload: .viewModelChange(FlowRuntimeStateChange(
                        instanceID: instanceID(3),
                        path: "debugOpacity",
                        value: .number(0.5),
                        originMutationID: nil
                    ))
                ),
                FlowRuntimeOutput(
                    sequence: 2,
                    cycle: 1,
                    phase: .hostWork,
                    payload: .hostCommand(name: "kept", payload: .object(.empty))
                ),
            ]
        ))

        XCTAssertTrue(surfaceView.subviews.isEmpty)
        XCTAssertTrue(recorder.writes.isEmpty)
        XCTAssertEqual(projected.orderedOutputs.map(\.sequence), [2])
    }

    func testUndeclaredChildReplacementReservesAdvertisedIdentity() throws {
        let artifact = try makeArtifact(includeInput: false)
        let surfaceView = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let recorder = WriteRecorder()
        let bridge = FlowTextInputOverlayBridge()
        bridge.bind(
            screenId: "screen_1",
            artifact: artifact,
            surfaceView: surfaceView,
            bootstrap: makeBootstrap(),
            textWriter: recorder.write
        )
        let projected = bridge.consume(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: false,
            orderedOutputs: [
                FlowRuntimeOutput(
                    sequence: 1,
                    cycle: 1,
                    phase: .viewModelChanges,
                    payload: .viewModelChange(FlowRuntimeStateChange(
                        instanceID: instanceID(2),
                        path: "futureInput",
                        value: nil,
                        viewModelReference: FlowRuntimeViewModelReference(
                            schemaID: "TextInput",
                            instanceID: instanceID(7)
                        ),
                        originMutationID: nil
                    ))
                ),
                FlowRuntimeOutput(
                    sequence: 2,
                    cycle: 1,
                    phase: .viewModelChanges,
                    payload: .viewModelChange(FlowRuntimeStateChange(
                        instanceID: instanceID(7),
                        path: "replacementOnlyField",
                        value: .number(9),
                        originMutationID: nil
                    ))
                ),
                FlowRuntimeOutput(
                    sequence: 3,
                    cycle: 1,
                    phase: .hostWork,
                    payload: .hostCommand(name: "kept", payload: .object(.empty))
                ),
            ]
        ))

        XCTAssertEqual(projected.orderedOutputs.map(\.sequence), [3])
    }

    func testDuplicateInputIDsAreDiagnosedAndDisabledWithoutTrapping() throws {
        let artifact = try makeArtifact(duplicateInput: true)
        let surfaceView = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let recorder = WriteRecorder()
        let bridge = FlowTextInputOverlayBridge()
        var diagnostics: [FlowRuntimeDiagnostic] = []
        bridge.onDiagnostic = { diagnostics.append($0) }

        bridge.bind(
            screenId: "screen_1",
            artifact: artifact,
            surfaceView: surfaceView,
            bootstrap: makeBootstrap(),
            textWriter: recorder.write
        )

        XCTAssertTrue(surfaceView.subviews.isEmpty)
        XCTAssertTrue(recorder.writes.isEmpty)
        XCTAssertEqual(
            diagnostics.map(\.code),
            ["nuxie_ios.text_input_duplicate_id"]
        )
    }

    func testOuterGeometryViewModelReplacementRebindsFromResultArena() throws {
        let harness = try makeHarness()
        let field = try harness.field()
        let replacement = replacementGeometryArena(
            containerID: instanceID(4),
            inputID: instanceID(5),
            x: 100
        )
        let result = FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: false,
            orderedOutputs: [
                FlowRuntimeOutput(
                    sequence: 1,
                    cycle: 1,
                    phase: .viewModelChanges,
                    payload: .viewModelChange(FlowRuntimeStateChange(
                        instanceID: instanceID(1),
                        path: "nuxieTextInputs",
                        value: nil,
                        viewModelReference: FlowRuntimeViewModelReference(
                            schemaID: "TextInputs",
                            instanceID: instanceID(4)
                        ),
                        originMutationID: nil
                    ))
                ),
            ],
            values: replacement
        )

        harness.bridge.consume(result)
        harness.bridge.layout()

        XCTAssertEqual(field.frame.origin.x, 90, accuracy: 0.001)
        XCTAssertFalse(field.isHidden)
    }

    func testMalformedOuterReplacementStillReservesAdvertisedIdentity() throws {
        let harness = try makeHarness()
        let field = try harness.field()
        var diagnostics: [FlowRuntimeDiagnostic] = []
        harness.bridge.onDiagnostic = { diagnostics.append($0) }
        let result = FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: false,
            orderedOutputs: [
                FlowRuntimeOutput(
                    sequence: 1,
                    cycle: 1,
                    phase: .viewModelChanges,
                    payload: .viewModelChange(FlowRuntimeStateChange(
                        instanceID: instanceID(1),
                        path: "nuxieTextInputs",
                        value: nil,
                        viewModelReference: FlowRuntimeViewModelReference(
                            schemaID: "TextInputs",
                            instanceID: instanceID(4)
                        ),
                        originMutationID: nil
                    ))
                ),
                FlowRuntimeOutput(
                    sequence: 2,
                    cycle: 1,
                    phase: .viewModelChanges,
                    payload: .viewModelChange(FlowRuntimeStateChange(
                        instanceID: instanceID(4),
                        path: "replacementOnlyField",
                        value: .number(9),
                        originMutationID: nil
                    ))
                ),
                FlowRuntimeOutput(
                    sequence: 3,
                    cycle: 1,
                    phase: .hostWork,
                    payload: .hostCommand(name: "kept", payload: .object(.empty))
                ),
            ]
        )

        let projected = harness.bridge.consume(result)
        harness.bridge.layout()

        XCTAssertTrue(field.isHidden)
        XCTAssertEqual(projected.orderedOutputs.map(\.sequence), [3])
        XCTAssertEqual(
            diagnostics.map(\.code),
            ["nuxie_ios.text_input_outer_view_model_rebind_failed"]
        )
    }

    func testInnerInputViewModelReplacementHidesAndDiagnosesControl() throws {
        let harness = try makeHarness()
        let field = try harness.field()
        var diagnostics: [FlowRuntimeDiagnostic] = []
        harness.bridge.onDiagnostic = { diagnostics.append($0) }
        let result = FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: false,
            orderedOutputs: [
                FlowRuntimeOutput(
                    sequence: 1,
                    cycle: 1,
                    phase: .viewModelChanges,
                    payload: .viewModelChange(FlowRuntimeStateChange(
                        instanceID: instanceID(2),
                        path: "input_email_input_60a86a84",
                        value: nil,
                        viewModelReference: FlowRuntimeViewModelReference(
                            schemaID: "TextInput",
                            instanceID: instanceID(6)
                        ),
                        originMutationID: nil
                    ))
                ),
                FlowRuntimeOutput(
                    sequence: 2,
                    cycle: 1,
                    phase: .viewModelChanges,
                    payload: .viewModelChange(FlowRuntimeStateChange(
                        instanceID: instanceID(6),
                        path: "replacementOnlyField",
                        value: .number(9),
                        originMutationID: nil
                    ))
                ),
                FlowRuntimeOutput(
                    sequence: 3,
                    cycle: 1,
                    phase: .hostWork,
                    payload: .hostCommand(name: "kept", payload: .object(.empty))
                ),
            ]
        )

        let projected = harness.bridge.consume(result)
        harness.bridge.layout()

        XCTAssertTrue(field.isHidden)
        XCTAssertEqual(projected.orderedOutputs.map(\.sequence), [3])
        XCTAssertEqual(
            diagnostics.map(\.code),
            ["nuxie_ios.text_input_inner_view_model_replacement"]
        )
    }

    func testMissingNamedTextRunFailureIsControlLocalAndNonterminal() throws {
        let artifact = try makeArtifact()
        let surfaceView = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let recorder = WriteRecorder()
        recorder.result = .failure(TestError.missingRun)
        let bridge = FlowTextInputOverlayBridge()
        var diagnostics: [FlowRuntimeDiagnostic] = []
        bridge.onDiagnostic = { diagnostics.append($0) }

        bridge.bind(
            screenId: "screen_1",
            artifact: artifact,
            surfaceView: surfaceView,
            bootstrap: makeBootstrap(),
            textWriter: recorder.write
        )

        let field = try XCTUnwrap(surfaceView.subviews.first as? UITextField)
        XCTAssertTrue(field.isHidden)
        XCTAssertEqual(
            diagnostics.map(\.code),
            ["nuxie_ios.text_run_bind_failed"]
        )
    }

    func testSecureEntryKeepsUIKitGlyphsAndClearsRuntimeTextRun() throws {
        let artifact = try makeArtifact(secure: true)
        let surfaceView = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let recorder = WriteRecorder()
        let bridge = FlowTextInputOverlayBridge()

        bridge.bind(
            screenId: "screen_1",
            artifact: artifact,
            surfaceView: surfaceView,
            bootstrap: makeBootstrap(),
            textWriter: recorder.write
        )

        let field = try XCTUnwrap(surfaceView.subviews.first as? UITextField)
        XCTAssertTrue(field.isSecureTextEntry)
        XCTAssertEqual(field.text, "levi@nuxie.dev")
        XCTAssertEqual(
            recorder.writes,
            [.init(text: "", runName: "email_input Run")]
        )
        XCTAssertNotEqual(field.textColor, UIColor.clear)
    }

    func testEndEditingCommitsChangedTextOnceAndRebindPreservesBaseline() throws {
        let harness = try makeHarness()
        let field = try harness.field()

        field.text = "typed@nuxie.dev"
        harness.bridge.textFieldDidEndEditing(field)
        harness.bridge.textFieldDidEndEditing(field)

        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.input.responseFieldKey, "email")
        XCTAssertEqual(commits.first?.text, "typed@nuxie.dev")
        harness.rebind()
        let rebound = try harness.field()
        XCTAssertEqual(rebound.text, "typed@nuxie.dev")
        harness.bridge.textFieldDidEndEditing(rebound)
        XCTAssertEqual(commits.count, 1)
    }

    func testKeyboardPolicyAndShiftMathRemainUIKitOwned() throws {
        let harness = try makeHarness()
        XCTAssertEqual(try harness.field().keyboardType, .emailAddress)
        XCTAssertEqual(
            FlowTextInputOverlayBridge.keyboardShift(
                controlFrameInWindow: CGRect(x: 0, y: 480, width: 300, height: 50),
                currentShift: 0,
                keyboardMinY: 500,
                padding: 12
            ),
            42
        )
        XCTAssertEqual(
            FlowTextInputOverlayBridge.keyboardShift(
                controlFrameInWindow: CGRect(x: 0, y: 440, width: 300, height: 50),
                currentShift: 40,
                keyboardMinY: 500,
                padding: 12
            ),
            42
        )
    }

    func testResponseSetEventMapsCommittedValues() throws {
        let input = try XCTUnwrap(try makeArtifact().manifest.textInputs.first)
        let event = try XCTUnwrap(
            FlowScreenViewController.responseSetEvent(for: input, text: "typed@nuxie.dev")
        )
        XCTAssertEqual(event.name, SystemEventNames.responseSet)
        XCTAssertEqual(event.properties["field"] as? String, "email")
        XCTAssertEqual(event.properties["value"] as? String, "typed@nuxie.dev")
        XCTAssertEqual(event.screenId, "screen_1")
        XCTAssertEqual(event.componentId, "text-input/screen_1/email_input")
    }

    #if SWIFT_PACKAGE
    func testRuntimeScreenRoutesCreationFamiliesInHostOrder() async throws {
        let bootstrap = screenBootstrap()
        let creation = FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: false,
            orderedOutputs: [
                FlowRuntimeOutput(
                    sequence: 1,
                    cycle: 1,
                    phase: .reportedEvents,
                    payload: .reportedEvent(
                        name: "reported",
                        eventType: 0,
                        delay: 0,
                        properties: [
                            FlowRuntimeEventProperty(
                                name: "component_id",
                                value: .string("hero")
                            ),
                        ],
                        openURL: nil
                    )
                ),
                FlowRuntimeOutput(
                    sequence: 2,
                    cycle: 1,
                    phase: .reportedEvents,
                    payload: .reportedEvent(
                        name: nil,
                        eventType: 0,
                        delay: 0,
                        properties: [],
                        openURL: FlowRuntimeOpenURL(
                            url: "https://nuxie.dev",
                            target: "_blank"
                        )
                    )
                ),
                FlowRuntimeOutput(
                    sequence: 3,
                    cycle: 1,
                    phase: .hostWork,
                    payload: .hostCommand(
                        name: "host-command",
                        payload: .object(FlowRuntimeHostObject(fields: [
                            FlowRuntimeHostObjectField(
                                name: "screenId",
                                value: .string("screen_1")
                            ),
                            FlowRuntimeHostObjectField(
                                name: "value",
                                value: .number(42)
                            ),
                        ]))
                    )
                ),
            ],
            bootstrap: bootstrap
        )
        let adapter = FakeFlowRuntimeAdapter(
            operationResults: [],
            bootstrap: bootstrap,
            creationResult: creation
        )
        let context = try await FlowRuntimeContextFactory(adapter: adapter)
            .makeContext(for: FlowRuntimeImportRequest(artifactBytes: Data([0x52])))
        let session = try await context.makeSession(
            descriptor: FlowRenderSessionDescriptor(artboardName: "Paywall")
        )
        let artifact = try makeArtifact(includeInput: false)
        let recorder = ScreenDelegateRecorder()
        let controller = try FlowScreenViewController(
            flow: artifact.flow,
            artifact: artifact,
            screen: artifact.manifest.entry,
            delegate: recorder
        )

        try await controller.mountRuntimeSession(session)

        XCTAssertEqual(
            recorder.calls,
            [
                "event:reported:hero",
                "link:https://nuxie.dev:_blank",
                "event:host-command:",
            ]
        )
        XCTAssertEqual(recorder.events.last?.properties["value"] as? Double, 42)
        await controller.shutdownRuntimeSession()
    }

    func testRuntimeScreenDrainsCanonicalStateInFIFOOrder() async throws {
        let bootstrap = screenBootstrap()
        let adapter = FakeFlowRuntimeAdapter(
            operationResults: [
                .success(stateResult(
                    sequence: 1,
                    cycle: 1,
                    value: "runtime-one"
                )),
                .success(stateResult(
                    sequence: 2,
                    cycle: 2,
                    value: "runtime-two"
                )),
            ],
            bootstrap: bootstrap
        )
        let context = try await FlowRuntimeContextFactory(adapter: adapter)
            .makeContext(for: FlowRuntimeImportRequest(artifactBytes: Data([0x52])))
        let session = try await context.makeSession(
            descriptor: FlowRenderSessionDescriptor(artboardName: "Paywall")
        )
        let artifact = try makeArtifact(includeInput: false)
        let recorder = ScreenDelegateRecorder()
        let controller = try FlowScreenViewController(
            flow: artifact.flow,
            artifact: artifact,
            screen: artifact.manifest.entry,
            delegate: recorder
        )
        let title = VmPathRef(viewModelName: "Main", path: "title")
        XCTAssertTrue(controller.applyValue(
            path: title,
            value: "one",
            screenId: "screen_1",
            instanceId: "main"
        ))
        XCTAssertTrue(controller.applyValue(
            path: title,
            value: "two",
            screenId: "screen_1",
            instanceId: "main"
        ))

        try await controller.mountRuntimeSession(session)
        let driver = try XCTUnwrap(
            adapter.contextDrivers.first?.sessionDrivers.first
        )
        for _ in 0..<1_000 where driver.performedOperations.count < 2 {
            await Task.yield()
        }

        XCTAssertEqual(driver.performedOperations.count, 2)
        let batches: [FlowRuntimeStateBatch] = driver.performedOperations.compactMap {
            operation -> FlowRuntimeStateBatch? in
            guard case .stateBatch(let batch) = operation else { return nil }
            return batch
        }
        XCTAssertEqual(batches.count, 2)
        let mutations: [FlowRuntimeStateMutation] = batches.flatMap(\.mutations)
        XCTAssertEqual(
            mutations,
            [
                FlowRuntimeStateMutation.setValue(
                    instance: .existing(instanceID(10)),
                    path: "title",
                    value: .string("one")
                ),
                FlowRuntimeStateMutation.setValue(
                    instance: .existing(instanceID(10)),
                    path: "title",
                    value: .string("two")
                ),
            ]
        )
        XCTAssertEqual(
            recorder.calls.filter { $0.hasPrefix("state:") },
            ["state:title", "state:title"]
        )
        XCTAssertFalse(recorder.calls.contains("advance"))
        await controller.shutdownRuntimeSession()
    }

    func testRuntimeScreenAbandonsLocalStateFailureAndContinuesFIFO() async throws {
        let bootstrap = screenBootstrap()
        let adapter = FakeFlowRuntimeAdapter(
            operationResults: [
                .failure(TestError.missingRun),
                .success(stateResult(
                    sequence: 1,
                    cycle: 1,
                    value: "runtime-two"
                )),
            ],
            bootstrap: bootstrap
        )
        let context = try await FlowRuntimeContextFactory(adapter: adapter)
            .makeContext(for: FlowRuntimeImportRequest(artifactBytes: Data([0x52])))
        let session = try await context.makeSession(
            descriptor: FlowRenderSessionDescriptor(artboardName: "Paywall")
        )
        let artifact = try makeArtifact(includeInput: false)
        let recorder = ScreenDelegateRecorder()
        let controller = try FlowScreenViewController(
            flow: artifact.flow,
            artifact: artifact,
            screen: artifact.manifest.entry,
            delegate: recorder
        )
        var terminalFailures = 0
        controller.onRuntimeFailure = { _ in terminalFailures += 1 }
        let title = VmPathRef(viewModelName: "Main", path: "title")
        XCTAssertTrue(controller.applyValue(
            path: title,
            value: "one",
            screenId: "screen_1",
            instanceId: "main"
        ))
        XCTAssertTrue(controller.applyValue(
            path: title,
            value: "two",
            screenId: "screen_1",
            instanceId: "main"
        ))

        try await controller.mountRuntimeSession(session)
        let driver = try XCTUnwrap(
            adapter.contextDrivers.first?.sessionDrivers.first
        )
        for _ in 0..<1_000 where driver.performedOperations.count < 2 {
            await Task.yield()
        }

        XCTAssertEqual(driver.performedOperations.count, 2)
        XCTAssertEqual(terminalFailures, 0)
        XCTAssertEqual(
            recorder.calls.filter { $0.hasPrefix("state:") },
            ["state:title"]
        )
        await controller.shutdownRuntimeSession()
    }

    func testRuntimeScreenShutdownSuppressesQueuedStateCancellation() async throws {
        let bootstrap = screenBootstrap()
        let attachmentGate = FakeFlowRuntimeSurfaceAttachmentGate()
        let adapter = FakeFlowRuntimeAdapter(
            operationResults: [],
            bootstrap: bootstrap,
            surfaceAttachmentGate: attachmentGate
        )
        let context = try await FlowRuntimeContextFactory(adapter: adapter)
            .makeContext(for: FlowRuntimeImportRequest(artifactBytes: Data([0x52])))
        let session = try await context.makeSession(
            descriptor: FlowRenderSessionDescriptor(artboardName: "Paywall")
        )
        let artifact = try makeArtifact(includeInput: false)
        let controller = try FlowScreenViewController(
            flow: artifact.flow,
            artifact: artifact,
            screen: artifact.manifest.entry,
            delegate: nil
        )
        var terminalFailures = 0
        controller.onRuntimeFailure = { _ in terminalFailures += 1 }
        XCTAssertTrue(controller.applyValue(
            path: VmPathRef(viewModelName: "Main", path: "title"),
            value: "queued",
            screenId: "screen_1",
            instanceId: "main"
        ))

        let mount = Task { @MainActor in
            try await controller.mountRuntimeSession(session)
        }
        await attachmentGate.waitUntilAttachmentIsSuspended()
        let shutdown = Task { @MainActor in
            await controller.shutdownRuntimeSession()
        }
        await Task.yield()
        attachmentGate.resumeAttachment()

        await shutdown.value
        do {
            try await mount.value
            XCTFail("Expected shutdown to cancel the in-progress mount")
        } catch is CancellationError {
            // Expected: teardown owns the cancellation, not runtime failure.
        }
        XCTAssertEqual(terminalFailures, 0)
    }

    func testNonRenderDeviceLossTerminatesCanonicalStateLane() async throws {
        let bootstrap = screenBootstrap()
        let adapter = FakeFlowRuntimeAdapter(
            operationResults: [
                .success(
                    FlowRuntimeOperationResult(
                        renderOutcome: .notRequested,
                        surfaceDisposition: .deviceLost,
                        isDirty: false,
                        isSettled: true
                    )
                ),
            ],
            bootstrap: bootstrap,
            creationResult: FlowRuntimeOperationResult(
                renderOutcome: .notRequested,
                isDirty: false,
                isSettled: true,
                bootstrap: bootstrap
            )
        )
        let context = try await FlowRuntimeContextFactory(adapter: adapter)
            .makeContext(for: FlowRuntimeImportRequest(artifactBytes: Data([0x52])))
        let session = try await context.makeSession(
            descriptor: FlowRenderSessionDescriptor(artboardName: "Paywall")
        )
        let artifact = try makeArtifact(includeInput: false)
        let controller = try FlowScreenViewController(
            flow: artifact.flow,
            artifact: artifact,
            screen: artifact.manifest.entry,
            delegate: nil
        )
        let terminalFailure = expectation(description: "terminal device loss")
        var failures: [FlowRuntimeHostError] = []
        controller.onRuntimeFailure = { error in
            if let hostError = error as? FlowRuntimeHostError {
                failures.append(hostError)
            }
            terminalFailure.fulfill()
        }

        try await controller.mountRuntimeSession(session)
        let title = VmPathRef(viewModelName: "Main", path: "title")
        XCTAssertTrue(controller.applyValue(
            path: title,
            value: "first",
            screenId: "screen_1",
            instanceId: "main"
        ))
        await fulfillment(of: [terminalFailure], timeout: 1)

        XCTAssertEqual(
            failures,
            [.unrecoverableSurface(.deviceLost)]
        )
        XCTAssertFalse(controller.applyValue(
            path: title,
            value: "must-not-queue",
            screenId: "screen_1",
            instanceId: "main"
        ))
        await controller.shutdownRuntimeSession()
    }

    func testConcurrentRuntimeScreenShutdownCallersAwaitTerminalHostCleanup() async throws {
        let bootstrap = screenBootstrap()
        let detachmentGate = FakeFlowRuntimeSurfaceDetachmentGate()
        let adapter = FakeFlowRuntimeAdapter(
            operationResults: [.failure(TerminalTestError.failed)],
            bootstrap: bootstrap,
            surfaceDetachmentGate: detachmentGate
        )
        let context = try await FlowRuntimeContextFactory(adapter: adapter)
            .makeContext(for: FlowRuntimeImportRequest(artifactBytes: Data([0x52])))
        let session = try await context.makeSession(
            descriptor: FlowRenderSessionDescriptor(artboardName: "Paywall")
        )
        let artifact = try makeArtifact(includeInput: false)
        let controller = try FlowScreenViewController(
            flow: artifact.flow,
            artifact: artifact,
            screen: artifact.manifest.entry,
            delegate: nil
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()

        let terminalFailure = expectation(description: "terminal failure")
        controller.onRuntimeFailure = { _ in terminalFailure.fulfill() }
        try await controller.mountRuntimeSession(session)
        XCTAssertTrue(controller.applyValue(
            path: VmPathRef(viewModelName: "Main", path: "title"),
            value: "terminal",
            screenId: "screen_1",
            instanceId: "main"
        ))
        await fulfillment(of: [terminalFailure], timeout: 1)
        await detachmentGate.waitUntilDetachmentIsSuspended()

        var didFinishFirstShutdown = false
        var didFinishSecondShutdown = false
        let firstShutdown = Task { @MainActor in
            await controller.shutdownRuntimeSession()
            didFinishFirstShutdown = true
        }
        let secondShutdown = Task { @MainActor in
            await controller.shutdownRuntimeSession()
            didFinishSecondShutdown = true
        }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(didFinishFirstShutdown)
        XCTAssertFalse(didFinishSecondShutdown)
        XCTAssertFalse(adapter.lifecycleRecorder.events.contains(.sessionDisposed))

        detachmentGate.resumeDetachment()
        await firstShutdown.value
        await secondShutdown.value
        XCTAssertTrue(didFinishFirstShutdown)
        XCTAssertTrue(didFinishSecondShutdown)
        XCTAssertEqual(
            adapter.lifecycleRecorder.events.filter { $0 == .surfaceDetached }.count,
            1
        )
        XCTAssertEqual(
            adapter.lifecycleRecorder.events.filter { $0 == .sessionDisposed }.count,
            1
        )
        window.isHidden = true
    }
    #endif

    private func makeHarness() throws -> Harness {
        let bridge = FlowTextInputOverlayBridge()
        bridge.onCommitText = { [weak self] input, text in
            self?.commits.append((input, text))
        }
        let surfaceView = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let recorder = WriteRecorder()
        let harness = Harness(
            bridge: bridge,
            surfaceView: surfaceView,
            artifact: try makeArtifact(),
            bootstrap: makeBootstrap(),
            writes: recorder
        )
        harness.rebind()
        return harness
    }

    private func makeArtifact(
        secure: Bool = false,
        includeInput: Bool = true,
        duplicateInput: Bool = false
    ) throws -> LoadedFlowArtifact {
        let manifestJSON = secure
            ? Self.manifestJSON.replacingOccurrences(
                of: "\"keyboardType\": \"email-address\",",
                with: "\"keyboardType\": \"email-address\", \"secureTextEntry\": true,"
            )
            : Self.manifestJSON
        var manifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(manifestJSON.utf8))
                as? [String: Any]
        )
        var textInputs = try XCTUnwrap(manifestObject["textInputs"] as? [[String: Any]])
        if !includeInput {
            textInputs = []
        } else if duplicateInput, let first = textInputs.first {
            textInputs.append(first)
        }
        manifestObject["textInputs"] = textInputs
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifestObject,
            options: [.sortedKeys]
        )
        let manifest = try JSONDecoder().decode(FlowArtifactManifest.self, from: manifestData)
        let remoteFlow = RemoteFlow(
            id: "flow-overlay-tests",
            flowArtifact: FlowArtifact(
                url: "https://example.com/flow-overlay-tests",
                buildId: "build-overlay-tests",
                manifest: BuildManifest(
                    totalFiles: 1,
                    totalSize: 1,
                    contentHash: "test",
                    files: [
                        BuildFile(
                            path: "flow.riv",
                            size: 1,
                            contentType: "application/octet-stream"
                        ),
                    ]
                )
            ),
            screens: [
                RemoteFlowScreen(
                    id: "screen_1",
                    defaultViewModelName: "Main",
                    defaultInstanceId: "main"
                ),
            ],
            viewModelValues: nil
        )
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return LoadedFlowArtifact(
            flow: Flow(remoteFlow: remoteFlow, products: []),
            directoryURL: root,
            rivURL: root.appendingPathComponent("flow.riv"),
            manifestURL: root.appendingPathComponent("nuxie-manifest.json"),
            manifest: manifest,
            assetURLsByRiveUniqueName: [:],
            source: .cachedArtifact,
            authorizationEvidence: FlowRuntimeAuthorizationEvidence(
                signedContentBytes: manifestData,
                signatureEnvelopeBytes: nil,
                selectedKey: nil
            )
        )
    }

    private func makeBootstrap() -> FlowRuntimeBootstrap {
        FlowRuntimeBootstrap(
            player: FlowRuntimePlayerMetadata(
                kind: .stateMachine,
                selection: .authoredDefaultStateMachine,
                index: 0,
                artboardName: "Paywall",
                playerName: "State Machine 1",
                bounds: FlowRuntimeArtboardBounds(
                    minX: 10,
                    minY: 20,
                    maxX: 400,
                    maxY: 864
                )
            ),
            catalog: FlowRuntimeCatalog(
                schemas: [],
                templates: [],
                instances: [
                    FlowRuntimeInstance(
                        id: instanceID(1),
                        schemaID: "Main",
                        name: "Default",
                        isRoot: true,
                        valueRootIndex: 0
                    ),
                    FlowRuntimeInstance(
                        id: instanceID(2),
                        schemaID: "TextInputs",
                        name: nil,
                        isRoot: false,
                        valueRootIndex: 1
                    ),
                    FlowRuntimeInstance(
                        id: instanceID(3),
                        schemaID: "TextInput",
                        name: nil,
                        isRoot: false,
                        valueRootIndex: 2
                    ),
                ]
            ),
            values: geometryArena(
                rootID: instanceID(1),
                containerID: instanceID(2),
                inputID: instanceID(3),
                x: 30
            )
        )
    }

    private func screenBootstrap() -> FlowRuntimeBootstrap {
        FlowRuntimeBootstrap(
            player: FlowRuntimePlayerMetadata(
                kind: .staticArtboard,
                selection: .staticArtboard,
                index: nil,
                artboardName: "Paywall",
                playerName: nil,
                bounds: FlowRuntimeArtboardBounds(
                    minX: 0,
                    minY: 0,
                    maxX: 390,
                    maxY: 844
                )
            ),
            catalog: FlowRuntimeCatalog(
                schemas: [
                    FlowRuntimeSchema(
                        id: "Main",
                        name: "Main",
                        properties: [
                            FlowRuntimeSchemaProperty(
                                schemaID: "Main",
                                propertyID: "title",
                                name: "title",
                                kind: .string
                            ),
                        ]
                    ),
                ],
                templates: [],
                instances: [
                    FlowRuntimeInstance(
                        id: instanceID(10),
                        schemaID: "Main",
                        name: "Default",
                        isRoot: true,
                        valueRootIndex: 0
                    ),
                ]
            ),
            values: FlowRuntimeValueArena(
                nodes: [
                    FlowRuntimeValueNode(value: .viewModel(
                        schemaID: "Main",
                        instanceID: instanceID(10),
                        fields: [
                            FlowRuntimeValueEdge(key: "title", nodeIndex: 1),
                        ]
                    )),
                    FlowRuntimeValueNode(value: .scalar(.string("initial"))),
                ],
                roots: [
                    FlowRuntimeValueRoot(
                        instanceID: instanceID(10),
                        nodeIndex: 0
                    ),
                ]
            )
        )
    }

    private func stateResult(
        sequence: UInt64,
        cycle: UInt64,
        value: String
    ) -> FlowRuntimeOperationResult {
        FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: false,
            orderedOutputs: [
                FlowRuntimeOutput(
                    sequence: sequence,
                    cycle: cycle,
                    phase: .viewModelChanges,
                    payload: .viewModelChange(FlowRuntimeStateChange(
                        instanceID: instanceID(10),
                        path: "title",
                        value: .string(value),
                        originMutationID: nil
                    ))
                ),
            ]
        )
    }

    private func geometryArena(
        rootID: FlowRuntimeInstanceID,
        containerID: FlowRuntimeInstanceID,
        inputID: FlowRuntimeInstanceID,
        x: Double
    ) -> FlowRuntimeValueArena {
        let nodes = geometryNodes(
            containerID: containerID,
            inputID: inputID,
            x: x,
            nodeOffset: 1
        )
        return FlowRuntimeValueArena(
            nodes: [
                FlowRuntimeValueNode(value: .viewModel(
                    schemaID: "Main",
                    instanceID: rootID,
                    fields: [FlowRuntimeValueEdge(key: "nuxieTextInputs", nodeIndex: 1)]
                )),
            ] + nodes,
            roots: [
                FlowRuntimeValueRoot(instanceID: rootID, nodeIndex: 0),
                FlowRuntimeValueRoot(instanceID: containerID, nodeIndex: 1),
                FlowRuntimeValueRoot(instanceID: inputID, nodeIndex: 2),
            ]
        )
    }

    private func replacementGeometryArena(
        containerID: FlowRuntimeInstanceID,
        inputID: FlowRuntimeInstanceID,
        x: Double
    ) -> FlowRuntimeValueArena {
        FlowRuntimeValueArena(
            nodes: geometryNodes(containerID: containerID, inputID: inputID, x: x),
            roots: [
                FlowRuntimeValueRoot(instanceID: containerID, nodeIndex: 0),
                FlowRuntimeValueRoot(instanceID: inputID, nodeIndex: 1),
            ]
        )
    }

    private func geometryNodes(
        containerID: FlowRuntimeInstanceID,
        inputID: FlowRuntimeInstanceID,
        x: Double,
        nodeOffset: Int = 0
    ) -> [FlowRuntimeValueNode] {
        [
            FlowRuntimeValueNode(value: .viewModel(
                schemaID: "TextInputs",
                instanceID: containerID,
                fields: [
                    FlowRuntimeValueEdge(
                        key: "input_email_input_60a86a84",
                        nodeIndex: nodeOffset + 1
                    ),
                ]
            )),
            FlowRuntimeValueNode(value: .viewModel(
                schemaID: "TextInput",
                instanceID: inputID,
                fields: [
                    FlowRuntimeValueEdge(key: "x", nodeIndex: nodeOffset + 2),
                    FlowRuntimeValueEdge(key: "y", nodeIndex: nodeOffset + 3),
                    FlowRuntimeValueEdge(key: "width", nodeIndex: nodeOffset + 4),
                    FlowRuntimeValueEdge(key: "height", nodeIndex: nodeOffset + 5),
                    FlowRuntimeValueEdge(key: "rotation", nodeIndex: nodeOffset + 6),
                    FlowRuntimeValueEdge(key: "scaleX", nodeIndex: nodeOffset + 7),
                    FlowRuntimeValueEdge(key: "scaleY", nodeIndex: nodeOffset + 8),
                ]
            )),
            FlowRuntimeValueNode(value: .scalar(.number(x))),
            FlowRuntimeValueNode(value: .scalar(.number(60))),
            FlowRuntimeValueNode(value: .scalar(.number(100))),
            FlowRuntimeValueNode(value: .scalar(.number(40))),
            FlowRuntimeValueNode(value: .scalar(.number(0))),
            FlowRuntimeValueNode(value: .scalar(.number(1.5))),
            FlowRuntimeValueNode(value: .scalar(.number(1))),
        ]
    }

    private func instanceID(_ rawValue: UInt64) -> FlowRuntimeInstanceID {
        FlowRuntimeInstanceID(rawValue: rawValue)!
    }

    private static let manifestJSON = """
    {
      "version": 1,
      "flowId": "flow-overlay-tests",
      "buildId": "build-overlay-tests",
      "renderer": "rive",
      "riv": {
        "path": "flow.riv",
        "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
        "sizeBytes": 1
      },
      "entry": {
        "screenId": "screen_1",
        "artboardId": "screen_1",
        "artboardName": "Paywall",
        "width": 390,
        "height": 844
      },
      "screens": [
        {
          "screenId": "screen_1",
          "artboardId": "screen_1",
          "artboardName": "Paywall",
          "width": 390,
          "height": 844
        }
      ],
      "assets": { "images": [], "fonts": [] },
      "textInputs": [
        {
          "inputId": "text-input/screen_1/email_input",
          "screenId": "screen_1",
          "artboardId": "screen_1",
          "viewNodeId": "email_input",
          "renderedNodeId": "email_input",
          "riveTextObjectKey": "artboard/screen_1/email_input/text",
          "riveTextRunObjectKey": "artboard/screen_1/email_input/text-run",
          "riveTextName": "email_input",
          "riveTextRunName": "email_input Run",
          "geometry": {
            "xPath": "nuxieTextInputs/input_email_input_60a86a84/x",
            "yPath": "nuxieTextInputs/input_email_input_60a86a84/y",
            "widthPath": "nuxieTextInputs/input_email_input_60a86a84/width",
            "heightPath": "nuxieTextInputs/input_email_input_60a86a84/height",
            "rotationPath": "nuxieTextInputs/input_email_input_60a86a84/rotation",
            "scaleXPath": "nuxieTextInputs/input_email_input_60a86a84/scaleX",
            "scaleYPath": "nuxieTextInputs/input_email_input_60a86a84/scaleY"
          },
          "style": {
            "fontFamily": "Inter",
            "fontWeight": "400",
            "fontStyle": "normal",
            "fontSize": 17,
            "lineHeight": 24,
            "letterSpacing": 0,
            "color": 4279179050,
            "fontAssetRiveUniqueName": "font-inter-400-normal-f5eccb28-0",
            "textAlign": "left"
          },
          "value": "levi@nuxie.dev",
          "placeholder": "you@example.com",
          "editable": true,
          "keyboardType": "email-address",
          "responseFieldKey": "email"
        }
      ]
    }
    """
}

#if SWIFT_PACKAGE
@MainActor
private final class ScreenDelegateRecorder: FlowScreenViewControllerDelegate {
    private(set) var calls: [String] = []
    private(set) var events: [FlowRendererEvent] = []

    func flowScreenViewControllerDidAdvance(
        _ controller: FlowScreenViewController
    ) {
        calls.append("advance")
    }

    func flowScreenViewController(
        _ controller: FlowScreenViewController,
        didEmitEvent event: FlowRendererEvent
    ) {
        events.append(event)
        calls.append(
            "event:\(event.name):\(event.componentId ?? "")"
        )
    }

    func flowScreenViewController(
        _ controller: FlowScreenViewController,
        didEmitViewModelChange change: FlowRendererViewModelChange
    ) {
        calls.append("state:\(change.path.path)")
    }

    func flowScreenViewController(
        _ controller: FlowScreenViewController,
        didRequestOpenLink request: FlowRendererOpenLinkRequest
    ) {
        calls.append(
            "link:\(request.urlString):\(request.target ?? "")"
        )
    }
}
#endif
#endif
