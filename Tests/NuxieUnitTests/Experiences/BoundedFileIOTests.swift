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
                expect(digest.sha256).to(equal(SHA256Provider.hexDigest(source)))
            }

            it("promotes verified media by rename without copying its inode") {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let source = directory.appendingPathComponent("download.tmp")
                let target = directory.appendingPathComponent("verified")
                let bytes = Data(repeating: 7, count: 200_000)
                try bytes.write(to: source)
                let inode = try FileManager.default.attributesOfItem(atPath: source.path)[.systemFileNumber] as? NSNumber
                let digest = try BoundedFileIO.promoteVerified(from: source, to: target,
                    expectedSize: bytes.count, expectedSHA256: SHA256Provider.hexDigest(bytes), maximumBytes: bytes.count)
                expect(digest.byteCount).to(equal(bytes.count))
                expect(FileManager.default.fileExists(atPath: source.path)).to(beFalse())
                let promotedInode = try FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? NSNumber
                expect(promotedInode).to(equal(inode))
                expect(try Data(contentsOf: target)).to(equal(bytes))
            }

            it("preserves an existing cache object when promotion verification fails") {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let source = directory.appendingPathComponent("download.tmp")
                let target = directory.appendingPathComponent("verified")
                try Data([1, 2, 3]).write(to: source)
                try Data([9]).write(to: target)
                expect {
                    try BoundedFileIO.promoteVerified(from: source, to: target, expectedSize: 3,
                        expectedSHA256: SHA256Provider.hexDigest(Data([4, 5, 6])), maximumBytes: 3)
                }.to(throwError())
                expect(try Data(contentsOf: target)).to(equal(Data([9])))
                expect(try Data(contentsOf: source)).to(equal(Data([1, 2, 3])))
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
                        expectedSHA256: SHA256Provider.hexDigest(Data([4, 5, 6])),
                        maximumBytes: source.count
                    )
                }.to(throwError())
                expect(try Data(contentsOf: destinationURL)).to(equal(published))
            }
        }
    }
}
