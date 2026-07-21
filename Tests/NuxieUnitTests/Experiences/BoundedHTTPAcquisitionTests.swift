import Foundation
import Nimble
import Quick
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private final class StreamingHTTPController: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stops = 0

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    func recordStop() {
        lock.lock()
        stops += 1
        lock.unlock()
    }

}

private final class StreamingURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (StreamingURLProtocol) -> Void

    private static let lock = NSLock()
    private static var handler: Handler?
    private static var stopHandler: (() -> Void)?
    private let stateLock = NSLock()
    private var stopped = false
    private var resolvedStopHandler: (() -> Void)?

    static func configure(
        handler: @escaping Handler,
        stopHandler: @escaping () -> Void
    ) {
        lock.lock()
        self.handler = handler
        self.stopHandler = stopHandler
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
        stopHandler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        resolvedStopHandler = Self.stopHandler
        Self.lock.unlock()
        DispatchQueue.global().async { [self] in
            handler?(self)
        }
    }

    override func stopLoading() {
        stateLock.lock()
        let wasStopped = stopped
        stopped = true
        stateLock.unlock()
        guard !wasStopped else { return }

        resolvedStopHandler?()
    }

    func send(response: HTTPURLResponse) {
        guard !isStopped else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func send(data: Data) {
        guard !isStopped else { return }
        client?.urlProtocol(self, didLoad: data)
    }

    func finish() {
        guard !isStopped else { return }
        client?.urlProtocolDidFinishLoading(self)
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }
}

final class BoundedHTTPAcquisitionTests: AsyncSpec {
    override class func spec() {
        func streamingSession() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StreamingURLProtocol.self]
            configuration.urlCache = nil
            return URLSession(configuration: configuration)
        }

        func temporaryDirectory() throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
            return url
        }

        describe("BoundedHTTPAcquisition") {
            it("streams through the injected URL session") {
                let url = URL(string: "https://assets.nuxie.test/injected-session.bin")!
                let payload = Data([1, 2, 3, 4])
                let temporaryDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: temporaryDirectory,
                    withIntermediateDirectories: true
                )
                defer {
                    try? FileManager.default.removeItem(at: temporaryDirectory)
                    StubURLProtocol.reset()
                }
                var observedHeader: String?
                StubURLProtocol.register(
                    matcher: { $0.url == url },
                    handler: { request in
                        observedHeader = request.value(forHTTPHeaderField: "X-Injected-Session")
                        let response = HTTPURLResponse(
                            url: url,
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: ["Content-Length": "\(payload.count)"]
                        )!
                        return (response, payload)
                    }
                )
                let session = TestURLSessionProvider.createTestSession(
                    additionalHeaders: ["X-Injected-Session": "preserved"]
                )

                let download = try await BoundedHTTPAcquisition.download(
                    from: url,
                    using: session,
                    maximumBytes: payload.count,
                    temporaryDirectory: temporaryDirectory
                )
                defer { try? FileManager.default.removeItem(at: download.temporaryURL) }

                expect(observedHeader).to(equal("preserved"))
                expect(download.byteCount).to(equal(payload.count))
                expect(try Data(contentsOf: download.temporaryURL)).to(equal(payload))
            }

            it("cancels a delayed chunked response and removes its temporary file") {
                let url = URL(string: "https://assets.nuxie.test/delayed.bin")!
                let directory = try temporaryDirectory()
                defer {
                    StreamingURLProtocol.reset()
                    try? FileManager.default.removeItem(at: directory)
                }
                let controller = StreamingHTTPController()
                let session = streamingSession()
                StreamingURLProtocol.configure(
                    handler: { protocolInstance in
                        let response = HTTPURLResponse(
                            url: url,
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: nil
                        )!
                        protocolInstance.send(response: response)
                        protocolInstance.send(data: Data([1]))
                        controller.started.signal()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                            protocolInstance.send(data: Data([2, 3]))
                            protocolInstance.finish()
                        }
                    },
                    stopHandler: controller.recordStop
                )
                let task = Task.detached {
                    try await BoundedHTTPAcquisition.download(
                        from: url,
                        using: session,
                        maximumBytes: 4,
                        temporaryDirectory: directory
                    )
                }
                expect(controller.started.wait(timeout: .now() + 2)).to(equal(.success))

                task.cancel()

                await expect {
                    try await task.value
                }.to(throwError(CancellationError()))
                // Cancellation propagates to the URL protocol asynchronously —
                // poll instead of asserting immediately (load-sensitive race
                // that flaked the macOS lane).
                await expect { controller.stopCount }
                    .toEventually(equal(1), timeout: .seconds(3))
                await expect {
                    try FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil
                    )
                }.toEventually(beEmpty(), timeout: .seconds(3))
            }

            it("rejects Content-Length before receiving body bytes") {
                let url = URL(string: "https://assets.nuxie.test/header-limit.bin")!
                let directory = try temporaryDirectory()
                defer {
                    StreamingURLProtocol.reset()
                    try? FileManager.default.removeItem(at: directory)
                }
                let controller = StreamingHTTPController()
                StreamingURLProtocol.configure(
                    handler: { protocolInstance in
                        let response = HTTPURLResponse(
                            url: url,
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: ["Content-Length": "8"]
                        )!
                        protocolInstance.send(response: response)
                        protocolInstance.send(data: Data(repeating: 1, count: 8))
                        protocolInstance.finish()
                    },
                    stopHandler: controller.recordStop
                )

                await expect {
                    try await BoundedHTTPAcquisition.download(
                        from: url,
                        using: streamingSession(),
                        maximumBytes: 4,
                        temporaryDirectory: directory
                    )
                }.to(
                    throwError(
                        BoundedHTTPAcquisitionError.declaredValueExceedsLimit(
                            actual: 8,
                            limit: 4
                        )
                    )
                )
                expect(
                    try FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil
                    )
                ).to(beEmpty())
            }

            it("bounds a chunked body and cleans up after the limit error") {
                let url = URL(string: "https://assets.nuxie.test/chunk-limit.bin")!
                let directory = try temporaryDirectory()
                defer {
                    StreamingURLProtocol.reset()
                    try? FileManager.default.removeItem(at: directory)
                }
                let controller = StreamingHTTPController()
                StreamingURLProtocol.configure(
                    handler: { protocolInstance in
                        let response = HTTPURLResponse(
                            url: url,
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: nil
                        )!
                        protocolInstance.send(response: response)
                        protocolInstance.send(data: Data([1, 2]))
                        protocolInstance.send(data: Data([3, 4]))
                        protocolInstance.finish()
                    },
                    stopHandler: controller.recordStop
                )

                await expect {
                    try await BoundedHTTPAcquisition.download(
                        from: url,
                        using: streamingSession(),
                        maximumBytes: 3,
                        temporaryDirectory: directory
                    )
                }.to(
                    throwError(
                        BoundedHTTPAcquisitionError.valueExceedsLimit(
                            actual: 4,
                            limit: 3
                        )
                    )
                )
                expect(
                    try FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil
                    )
                ).to(beEmpty())
            }

            it("does not start a request when already cancelled") {
                let url = URL(string: "https://assets.nuxie.test/cancelled-before-start.bin")!
                let directory = try temporaryDirectory()
                defer {
                    StreamingURLProtocol.reset()
                    try? FileManager.default.removeItem(at: directory)
                }
                let controller = StreamingHTTPController()
                StreamingURLProtocol.configure(
                    handler: { protocolInstance in
                        let response = HTTPURLResponse(
                            url: url,
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: ["Content-Length": "1"]
                        )!
                        protocolInstance.send(response: response)
                        protocolInstance.send(data: Data([1]))
                        protocolInstance.finish()
                    },
                    stopHandler: controller.recordStop
                )
                let gate = DispatchSemaphore(value: 0)
                let session = streamingSession()
                let task = Task.detached {
                    gate.wait()
                    return try await BoundedHTTPAcquisition.download(
                        from: url,
                        using: session,
                        maximumBytes: 1,
                        temporaryDirectory: directory
                    )
                }

                task.cancel()
                gate.signal()

                await expect {
                    try await task.value
                }.to(throwError(CancellationError()))
                expect(controller.stopCount).to(equal(0))
                expect(
                    try FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil
                    )
                ).to(beEmpty())
            }

            it("has one terminal result across response and cancellation races") {
                let url = URL(string: "https://assets.nuxie.test/response-cancel-race.bin")!
                for _ in 0..<10 {
                    let directory = try temporaryDirectory()
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let controller = StreamingHTTPController()
                    StreamingURLProtocol.configure(
                        handler: { protocolInstance in
                            let response = HTTPURLResponse(
                                url: url,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Length": "1"]
                            )!
                            protocolInstance.send(response: response)
                            controller.started.signal()
                            DispatchQueue.global().async {
                                protocolInstance.send(data: Data([1]))
                                protocolInstance.finish()
                            }
                        },
                        stopHandler: controller.recordStop
                    )
                    let session = streamingSession()
                    let task = Task.detached {
                        try await BoundedHTTPAcquisition.download(
                            from: url,
                            using: session,
                            maximumBytes: 1,
                            temporaryDirectory: directory
                        )
                    }
                    expect(controller.started.wait(timeout: .now() + 2))
                        .to(equal(.success))
                    task.cancel()

                    do {
                        let download = try await task.value
                        try FileManager.default.removeItem(at: download.temporaryURL)
                    } catch is CancellationError {
                        // Either completion is valid at the response/cancel boundary.
                    } catch {
                        fail("Unexpected terminal error: \(error)")
                    }
                    expect(controller.stopCount).to(beLessThanOrEqualTo(1))
                    expect(
                        try FileManager.default.contentsOfDirectory(
                            at: directory,
                            includingPropertiesForKeys: nil
                        )
                    ).to(beEmpty())
                }
                StreamingURLProtocol.reset()
            }
        }
    }
}
