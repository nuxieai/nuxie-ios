import Foundation
import Nimble
import Quick
@testable import Nuxie

final class BoundedFileIOTests: QuickSpec {
    override class func spec() {
        describe("BoundedFileIO") {
            it("accepts an Int.max bound without overflowing its read size") {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                defer { try? FileManager.default.removeItem(at: directory) }
                let sourceURL = directory.appendingPathComponent("source.bin")
                let source = Data([1, 2, 3])
                try source.write(to: sourceURL)

                let digest = try BoundedFileIO.inspect(
                    at: sourceURL,
                    maximumBytes: .max
                )

                expect(digest.byteCount).to(equal(source.count))
                expect(digest.sha256).to(equal(FlowArtifactStore.sha256Hex(source)))
            }

            it("keeps the published destination unchanged when verification fails") {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                defer { try? FileManager.default.removeItem(at: directory) }
                let sourceURL = directory.appendingPathComponent("source.bin")
                let destinationURL = directory.appendingPathComponent("published.bin")
                let source = Data([1, 2, 3])
                let published = Data([9, 9, 9])
                try source.write(to: sourceURL)
                try published.write(to: destinationURL)

                expect {
                    try BoundedFileIO.copyVerified(
                        from: sourceURL,
                        to: destinationURL,
                        expectedSize: source.count,
                        expectedSHA256: FlowArtifactStore.sha256Hex(Data([4, 5, 6])),
                        maximumBytes: source.count
                    )
                }.to(throwError())
                expect(try Data(contentsOf: destinationURL)).to(equal(published))
            }
        }
    }
}
