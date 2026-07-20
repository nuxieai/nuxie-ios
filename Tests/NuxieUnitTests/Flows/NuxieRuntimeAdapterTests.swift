#if NUXIE_RUNTIME_ADAPTER_TESTS && !canImport(NuxieRuntime)
#error("test-runtime-adapter requires the packaged NuxieRuntime Clang module")
#endif

#if canImport(NuxieRuntime)
import Foundation
import Metal
import Nimble
import NuxieRuntime
import Quick
import UIKit
@testable import Nuxie

final class NuxieRuntimeAdapterTests: AsyncSpec {
    override class func spec() {
        describe("NuxieRuntimeAdapter") {
            it("validates the packaged ABI and maps every declared fixed-width value") {
                expect { try NuxieRuntimeABI.validate() }.notTo(throwError())

                expect(nuxieRuntimeStatus(NUX_STATUS_OK)).to(equal(.ok))
                expect(nuxieRuntimeStatus(NUX_STATUS_NULL_ARGUMENT)).to(equal(.nullArgument))
                expect(nuxieRuntimeStatus(NUX_STATUS_IMPORT_ERROR)).to(equal(.importError))
                expect(nuxieRuntimeStatus(NUX_STATUS_NOT_FOUND)).to(equal(.notFound))
                expect(nuxieRuntimeStatus(NUX_STATUS_RUNTIME_ERROR)).to(equal(.runtimeError))
                expect(nuxieRuntimeStatus(NUX_STATUS_INVALID_ARGUMENT)).to(equal(.invalidArgument))
                expect(nuxieRuntimeStatus(NUX_STATUS_ABI_MISMATCH)).to(equal(.abiMismatch))
                expect(nuxieRuntimeStatus(NUX_STATUS_SURFACE_ERROR)).to(equal(.surfaceError))
                expect(nuxieRuntimeStatus(UInt32.max)).to(equal(.unknown(UInt32.max)))

                let dispositions: [(UInt32, FlowRuntimeSurfaceDisposition)] = [
                    (NUX_SURFACE_DISPOSITION_NONE, .none),
                    (NUX_SURFACE_DISPOSITION_PRESENTED, .presented),
                    (NUX_SURFACE_DISPOSITION_SKIPPED_ZERO_SIZE, .skippedZeroSize),
                    (NUX_SURFACE_DISPOSITION_SKIPPED_TIMEOUT, .skippedTimeout),
                    (NUX_SURFACE_DISPOSITION_SKIPPED_OCCLUDED, .skippedOccluded),
                    (NUX_SURFACE_DISPOSITION_RECONFIGURED, .reconfigured),
                    (NUX_SURFACE_DISPOSITION_RECREATED, .recreated),
                    (NUX_SURFACE_DISPOSITION_DEVICE_LOST, .deviceLost),
                    (NUX_SURFACE_DISPOSITION_OUT_OF_MEMORY, .outOfMemory),
                    (NUX_SURFACE_DISPOSITION_FATAL, .fatal),
                ]
                for (rawValue, expected) in dispositions {
                    expect(nuxieRuntimeSurfaceDisposition(rawValue)).to(equal(expected))
                }
                expect(nuxieRuntimeSurfaceDisposition(UInt32.max))
                    .to(equal(.unknown(UInt32.max)))
            }

            it("fails closed when a native call omits its owned result") {
                var missingResult: OpaquePointer?
                expect {
                    try copyNuxieRuntimeResult(
                        callStatus: NUX_STATUS_OK,
                        result: &missingResult,
                        renderRequested: false
                    )
                }.to(throwError(NuxieRuntimeAdapterError.missingOperationResult))

                expect {
                    try copyNuxieRuntimeResult(
                        callStatus: NUX_STATUS_INVALID_ARGUMENT,
                        result: &missingResult,
                        renderRequested: false
                    )
                }.to(throwError { error in
                    guard case NuxieRuntimeAdapterError.callFailed(let status, let diagnostic) = error else {
                        fail("unexpected error: \(error)")
                        return
                    }
                    expect(status).to(equal(.invalidArgument))
                    expect(diagnostic.code).to(equal("nux_runtime.invalid_argument"))
                    expect(diagnostic.message).to(contain("no diagnostic result"))
                })
            }

            it("copies the native diagnostic for an invalid artifact") { @MainActor in
                let adapter = NuxieRuntimeAdapter()
                do {
                    _ = try await adapter.makeContext(
                        for: FlowRuntimeImportRequest(artifactBytes: Data([0x00, 0x01, 0x02]))
                    )
                    fail("expected import to fail")
                } catch NuxieRuntimeAdapterError.callFailed(let status, let diagnostic) {
                    expect(status).to(equal(.importError))
                    expect(diagnostic.code).to(equal("nux_runtime.import_error"))
                    expect(diagnostic.message).notTo(beEmpty())
                } catch {
                    fail("unexpected error: \(error)")
                }
            }

            it("copies native not-found diagnostics and rejects invalid frame deltas") { @MainActor in
                let fixtureBytes = try Self.fixtureBytes()
                let adapter = NuxieRuntimeAdapter()
                let context = try await adapter.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: fixtureBytes)
                )
                defer { context.dispose() }

                do {
                    _ = try await context.makeSession(
                        descriptor: FlowRenderSessionDescriptor(artboardName: "Missing")
                    )
                    fail("expected missing artboard selection to fail")
                } catch NuxieRuntimeAdapterError.callFailed(let status, let diagnostic) {
                    expect(status).to(equal(.notFound))
                    expect(diagnostic.code).to(equal("nux_runtime.not_found"))
                    expect(diagnostic.message).to(contain("Missing"))
                } catch {
                    fail("unexpected error: \(error)")
                }

                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor(artboardName: "Two")
                )
                defer { session.dispose() }

                do {
                    _ = try await session.perform(
                        .advance(FlowRuntimeFrameTime(timestamp: 1, delta: -.infinity)),
                        drawable: nil
                    )
                    fail("expected the invalid frame delta to fail")
                } catch NuxieRuntimeAdapterError.invalidFrameDelta(let delta) {
                    expect(delta).to(equal(-.infinity))
                } catch {
                    fail("unexpected error: \(error)")
                }
            }

            it("presents a known fixture and recovers the packaged surface lifecycle") { @MainActor in
                let fixtureBytes = try Self.fixtureBytes()
                let adapter = NuxieRuntimeAdapter()
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                let context = try await factory.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: fixtureBytes)
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor(artboardName: "Two")
                )
                defer {
                    session.dispose()
                }

                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 96, height: 96))
                let viewController = UIViewController()
                let view = FlowRuntimeSurfaceView(frame: window.bounds)
                viewController.view.addSubview(view)
                window.rootViewController = viewController
                window.makeKeyAndVisible()
                view.layoutIfNeeded()
                let size = FlowRuntimeSurfaceSizing.pixels(
                    width: view.bounds.width,
                    height: view.bounds.height,
                    scale: view.metalLayer.contentsScale
                )
                let surface: FlowRenderSurface
                do {
                    surface = try await session.attachAppleSurface(
                        to: FlowRuntimeAppleSurfaceTarget(layer: view.metalLayer, size: size)
                    )
                } catch {
                    fail("surface attach failed: \(String(reflecting: error))")
                    return
                }
                defer { surface.dispose() }
                expect(surface.attachmentResult.renderOutcome).to(equal(.notRequested))
                expect(surface.attachmentResult.surfaceDisposition).to(equal(.recreated))
                expect(view.metalLayer.device).notTo(beNil())
                expect(view.metalLayer.pixelFormat).to(equal(.bgra8Unorm))
                let initialDrawableSize = CGSize(
                    width: CGFloat(size.pixelWidth),
                    height: CGFloat(size.pixelHeight)
                )
                expect(view.metalLayer.drawableSize).to(equal(initialDrawableSize))

                let unavailable = try await session.perform(
                    .advanceAndRender(FlowRuntimeFrameTime(timestamp: 1, delta: 0))
                )
                expect(unavailable.renderOutcome).to(equal(.skipped))
                expect(unavailable.surfaceDisposition).to(equal(.skippedTimeout))

                let result: FlowRuntimeOperationResult
                do {
                    guard let drawable = view.metalLayer.nextDrawable() else {
                        fail("configured CAMetalLayer did not vend a drawable")
                        return
                    }
                    result = try await session.perform(
                        .advanceAndRender(FlowRuntimeFrameTime(timestamp: 2, delta: 0)),
                        drawable: surface.makeDrawableTarget(drawable, onCompleted: {})
                    )
                } catch {
                    fail("surface render failed: \(String(reflecting: error))")
                    return
                }
                expect(result.renderOutcome).to(equal(.presented))
                expect(result.surfaceDisposition).to(equal(.presented))

                let zeroSize = try await surface.resize(
                    to: FlowRuntimeSurfaceSize(pixelWidth: 0, pixelHeight: 0)
                )
                expect(zeroSize.surfaceDisposition).to(equal(.skippedZeroSize))
                expect(view.metalLayer.drawableSize).to(equal(initialDrawableSize))

                let zeroSizeFrame = try await session.perform(
                    .advanceAndRender(FlowRuntimeFrameTime(timestamp: 3, delta: 0))
                )
                expect(zeroSizeFrame.renderOutcome).to(equal(.skipped))
                expect(zeroSizeFrame.surfaceDisposition).to(equal(.skippedZeroSize))

                let resized = try await surface.resize(
                    to: FlowRuntimeSurfaceSize(pixelWidth: 64, pixelHeight: 48)
                )
                expect(resized.surfaceDisposition).to(equal(.reconfigured))
                expect(view.metalLayer.drawableSize).to(equal(CGSize(width: 64, height: 48)))

                let detached = try await surface.detach()
                expect(detached.surfaceDisposition).to(
                    equal(FlowRuntimeSurfaceDisposition.none)
                )
                expect(view.metalLayer.device).to(beNil())
                do {
                    _ = try await session.perform(
                        .advanceAndRender(FlowRuntimeFrameTime(timestamp: 4, delta: 0))
                    )
                    fail("expected rendering a detached surface to fail")
                } catch NuxieRuntimeAdapterError.callFailed(let status, let diagnostic) {
                    expect(status).to(equal(.surfaceError))
                    expect(diagnostic.code).to(equal("nux_runtime.surface_error"))
                    expect(diagnostic.message).to(contain("not attached"))
                } catch {
                    fail("unexpected error: \(error)")
                }

                let reattached = try await surface.reattach(
                    to: FlowRuntimeAppleSurfaceTarget(
                        layer: view.metalLayer,
                        size: FlowRuntimeSurfaceSize(pixelWidth: 64, pixelHeight: 48)
                    )
                )
                expect(reattached.surfaceDisposition).to(equal(.recreated))
                expect(view.metalLayer.device).notTo(beNil())

                guard let recoveredDrawable = view.metalLayer.nextDrawable() else {
                    fail("reattached CAMetalLayer did not vend a drawable")
                    return
                }
                let recovered = try await session.perform(
                    .advanceAndRender(FlowRuntimeFrameTime(timestamp: 5, delta: 0)),
                    drawable: surface.makeDrawableTarget(recoveredDrawable, onCompleted: {})
                )
                expect(recovered.renderOutcome).to(equal(.presented))
                expect(recovered.surfaceDisposition).to(equal(.presented))
            }

            it("preserves native children across parent-first disposal without borrowing the layer") { @MainActor in
                let fixtureBytes = try Self.fixtureBytes()
                let adapter = NuxieRuntimeAdapter()
                let context = try await adapter.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: fixtureBytes)
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor(artboardName: "Two")
                )
                var layer: CAMetalLayer? = CAMetalLayer()
                let weakLayer = WeakReference(layer)
                let attachment: FlowRuntimeSurfaceDriverAttachment
                if let layer {
                    attachment = try await session.attachAppleSurface(
                        to: FlowRuntimeAppleSurfaceTarget(
                            layer: layer,
                            size: FlowRuntimeSurfaceSize(pixelWidth: 8, pixelHeight: 8)
                        )
                    )
                } else {
                    fail("expected a live CAMetalLayer")
                    return
                }
                let surface = attachment.driver
                defer {
                    surface.dispose()
                    session.dispose()
                    context.dispose()
                }
                layer = nil
                expect(weakLayer.value).to(beNil())

                context.dispose()
                context.dispose()
                let childAfterContext = try await session.perform(
                    .advance(FlowRuntimeFrameTime(timestamp: 1, delta: 0)),
                    drawable: nil
                )
                expect(childAfterContext.surfaceDisposition).to(
                    equal(FlowRuntimeSurfaceDisposition.none)
                )
                do {
                    _ = try await context.makeSession(
                        descriptor: FlowRenderSessionDescriptor(artboardName: "Two")
                    )
                    fail("expected the disposed context handle to be unavailable")
                } catch NuxieRuntimeAdapterError.missingHandle(let name) {
                    expect(name).to(equal("runtime context"))
                } catch {
                    fail("unexpected error: \(error)")
                }

                session.dispose()
                session.dispose()
                let childAfterSession = try await surface.resize(
                    to: FlowRuntimeSurfaceSize(pixelWidth: 10, pixelHeight: 10)
                )
                expect(childAfterSession.surfaceDisposition).to(equal(.reconfigured))
                do {
                    _ = try await session.perform(
                        .advance(FlowRuntimeFrameTime(timestamp: 2, delta: 0)),
                        drawable: nil
                    )
                    fail("expected the disposed session handle to be unavailable")
                } catch NuxieRuntimeAdapterError.missingHandle(let name) {
                    expect(name).to(equal("render session"))
                } catch {
                    fail("unexpected error: \(error)")
                }

                surface.dispose()
                surface.dispose()
                do {
                    _ = try await surface.resize(
                        to: FlowRuntimeSurfaceSize(pixelWidth: 12, pixelHeight: 12)
                    )
                    fail("expected the disposed surface handle to be unavailable")
                } catch NuxieRuntimeAdapterError.missingHandle(let name) {
                    expect(name).to(equal("Apple surface"))
                } catch {
                    fail("unexpected error: \(error)")
                }
            }
        }
    }

    private static func fixtureBytes() throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(
            forResource: "nuxie_runtime_two_artboards.riv",
            withExtension: "base64",
            subdirectory: "Fixtures"
        ) ?? bundle.url(
            forResource: "nuxie_runtime_two_artboards.riv",
            withExtension: "base64"
        ) else {
            throw FixtureError.missing
        }
        let encoded = try Data(contentsOf: url)
        guard let decoded = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw FixtureError.invalidBase64
        }
        return decoded
    }
}

private enum FixtureError: Error {
    case missing
    case invalidBase64
}

private final class WeakReference<Value: AnyObject> {
    private(set) weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}
#endif
