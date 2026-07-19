import CryptoKit
import Darwin
import Foundation

enum BoundedFileIOError: Error, Equatable {
    case valueExceedsLimit(actual: Int, limit: Int)
}

enum BoundedFileVerificationError: Error, Equatable {
    case sizeMismatch(expected: Int, actual: Int)
    case sha256Mismatch(expected: String, actual: String)
}

struct BoundedFileDigest {
    let byteCount: Int
    let sha256: String
}

/// Bounds reads on one open file handle and publishes copies with an atomic rename.
enum BoundedFileIO {
    private static let chunkBytes = 64 * 1_024

    static func inspect(
        at url: URL,
        maximumBytes: Int
    ) throws -> BoundedFileDigest {
        try consume(at: url, maximumBytes: maximumBytes) { _ in }
    }

    static func read(
        at url: URL,
        maximumBytes: Int
    ) throws -> (data: Data, digest: BoundedFileDigest) {
        var data = Data()
        let digest = try consume(at: url, maximumBytes: maximumBytes) { chunk in
            data.append(chunk)
        }
        return (data, digest)
    }

    static func copy(
        from sourceURL: URL,
        to destinationURL: URL,
        maximumBytes: Int
    ) throws -> BoundedFileDigest {
        try copy(
            from: sourceURL,
            to: destinationURL,
            maximumBytes: maximumBytes,
            verification: nil
        )
    }

    static func copyVerified(
        from sourceURL: URL,
        to destinationURL: URL,
        expectedSize: Int,
        expectedSHA256: String,
        maximumBytes: Int
    ) throws -> BoundedFileDigest {
        try copy(
            from: sourceURL,
            to: destinationURL,
            maximumBytes: maximumBytes,
            verification: (expectedSize, expectedSHA256)
        )
    }

    private static func copy(
        from sourceURL: URL,
        to destinationURL: URL,
        maximumBytes: Int,
        verification: (size: Int, sha256: String)?
    ) throws -> BoundedFileDigest {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var shouldRemoveTemporaryFile = true
        defer {
            if shouldRemoveTemporaryFile {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        let destinationHandle = try FileHandle(forWritingTo: temporaryURL)
        do {
            let digest = try consume(
                at: sourceURL,
                maximumBytes: maximumBytes
            ) { chunk in
                try destinationHandle.write(contentsOf: chunk)
            }
            try destinationHandle.close()
            if let verification {
                guard digest.byteCount == verification.size else {
                    throw BoundedFileVerificationError.sizeMismatch(
                        expected: verification.size,
                        actual: digest.byteCount
                    )
                }
                guard digest.sha256.caseInsensitiveCompare(verification.sha256) == .orderedSame else {
                    throw BoundedFileVerificationError.sha256Mismatch(
                        expected: verification.sha256,
                        actual: digest.sha256
                    )
                }
            }
            try publish(temporaryURL: temporaryURL, to: destinationURL)
            shouldRemoveTemporaryFile = false
            return digest
        } catch {
            try? destinationHandle.close()
            throw error
        }
    }

    private static func consume(
        at url: URL,
        maximumBytes: Int,
        body: (Data) throws -> Void
    ) throws -> BoundedFileDigest {
        precondition(maximumBytes >= 0)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard fileSize <= UInt64(maximumBytes) else {
            throw BoundedFileIOError.valueExceedsLimit(
                actual: boundedInt(fileSize),
                limit: maximumBytes
            )
        }

        var hasher = SHA256()
        var byteCount = 0
        while true {
            let remainingBytes = maximumBytes - byteCount
            let readCount = remainingBytes >= chunkBytes
                ? chunkBytes
                : remainingBytes + 1
            let chunk = try handle.read(upToCount: readCount) ?? Data()
            guard !chunk.isEmpty else { break }

            let (nextByteCount, overflowed) = byteCount.addingReportingOverflow(chunk.count)
            guard !overflowed, nextByteCount <= maximumBytes else {
                throw BoundedFileIOError.valueExceedsLimit(
                    actual: overflowed ? Int.max : nextByteCount,
                    limit: maximumBytes
                )
            }
            byteCount = nextByteCount
            hasher.update(data: chunk)
            try body(chunk)
        }

        return BoundedFileDigest(
            byteCount: byteCount,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func publish(
        temporaryURL: URL,
        to destinationURL: URL
    ) throws {
        let result = temporaryURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return -1 }
                return Int(Darwin.rename(sourcePath, destinationPath))
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private static func boundedInt(_ value: UInt64) -> Int {
        value <= UInt64(Int.max) ? Int(value) : Int.max
    }
}
