#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import Nimble
import NuxieRuntimeFFI
import Quick
@testable import NuxieRuntime

final class NuxieRuntimeModuleTests: AsyncSpec {
    override class func spec() {
        describe("NuxieRuntime Swift module") {
            it("serializes operations in submission order") {
                let executor = NuxieRuntimeSerialExecutor()
                let recorder = RuntimeOrderRecorder()

                executor.enqueue { recorder.append(1) }
                executor.enqueue { recorder.append(2) }
                let values = try await executor.call {
                    recorder.append(3)
                    return recorder.values
                }

                expect(values).to(equal([1, 2, 3]))
            }

            it("maps known and unknown FFI status values") {
                expect(nuxieRuntimeStatus(NUX_STATUS_OK)).to(equal(.ok))
                expect(
                    nuxieRuntimeStatus(NUX_STATUS_RUNTIME_IDENTITY_MISMATCH)
                ).to(equal(.runtimeIdentityMismatch))
                expect(nuxieRuntimeStatus(UInt32.max)).to(equal(.unknown(UInt32.max)))
            }

            it("pins Swift import storage for the synchronous FFI call") {
                let request = NuxieRuntimeImportRequest(
                    packageBytes: Data([1, 2, 3]),
                    expectedExperienceId: "experience-id",
                    expectedBuildId: "build-id",
                    candidateKeys: [
                        .init(
                            keyId: "key-id",
                            ed25519PublicKeyBytes: Data(repeating: 7, count: 32)
                        )
                    ],
                    externalAssets: [
                        .init(
                            kind: .image,
                            assetId: 42,
                            required: true,
                            provided: true,
                            uniqueName: Data("hero".utf8),
                            sourceKey: Data("asset-key".utf8),
                            expectedSHA256: Data("digest".utf8),
                            bytes: Data([9, 8])
                        )
                    ]
                )

                withNuxieRuntimeFFIImportRequest(request) { ffi in
                    expect(ffi.pointee.package_bytes.len).to(equal(3))
                    expect(String(cString: ffi.pointee.expected_experience_id))
                        .to(equal("experience-id"))
                    expect(String(cString: ffi.pointee.expected_build_id))
                        .to(equal("build-id"))
                    expect(ffi.pointee.candidate_key_count).to(equal(1))
                    expect(ffi.pointee.external_asset_count).to(equal(1))
                    expect(ffi.pointee.external_assets.pointee.asset_id).to(equal(42))
                    expect(ffi.pointee.external_assets.pointee.kind).to(
                        equal(UInt32(NUX_EXPERIENCE_EXTERNAL_ASSET_KIND_IMAGE))
                    )
                }
            }
        }
    }
}

private final class RuntimeOrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    var values: [Int] {
        lock.withLock { storage }
    }

    func append(_ value: Int) {
        lock.withLock { storage.append(value) }
    }
}
#endif
