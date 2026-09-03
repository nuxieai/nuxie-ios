import CryptoKit
import Foundation

struct JourneyReleaseStoragePaths: Sendable {
    let objects: URL
    let admission: URL?

    static func resolve(
        customStoragePath: URL?,
        cachesDirectory: URL,
        applicationSupportDirectory: URL?
    ) -> Self {
        if let customStoragePath {
            let root = customStoragePath.appendingPathComponent(
                "nuxie_journey_releases",
                isDirectory: true
            )
            return Self(
                objects: root.appendingPathComponent("objects", isDirectory: true),
                admission: root.appendingPathComponent("admission", isDirectory: true)
            )
        }
        return Self(
            objects: cachesDirectory
                .appendingPathComponent("nuxie_journey_releases", isDirectory: true)
                .appendingPathComponent("objects", isDirectory: true),
            admission: applicationSupportDirectory.map {
                $0.appendingPathComponent("nuxie", isDirectory: true)
                    .appendingPathComponent("journey_release_admission", isDirectory: true)
            }
        )
    }
}

struct JourneyReleaseHighWaterKey: Hashable, Sendable {
    let appId: String
    let environment: String
    let experienceId: String
}

struct JourneyReleaseHighWaterMark: Codable, Equatable, Sendable {
    let publishedAtSeq: Int
    let experienceVersionId: String
    let buildId: String
    let versionNumber: Int
    let publishedAt: String
    let descriptorSHA256: String
}

protocol JourneyReleaseHighWaterStore: Sendable {
    func admitActiveBatch(
        _ candidates: [JourneyReleaseHighWaterKey: JourneyReleaseHighWaterMark]
    ) async throws
    func highWater(
        for key: JourneyReleaseHighWaterKey
    ) async throws -> JourneyReleaseHighWaterMark?
}

actor InMemoryJourneyReleaseHighWaterStore: JourneyReleaseHighWaterStore {
    private var values: [JourneyReleaseHighWaterKey: JourneyReleaseHighWaterMark] = [:]

    func admitActiveBatch(
        _ candidates: [JourneyReleaseHighWaterKey: JourneyReleaseHighWaterMark]
    ) throws {
        for (key, candidate) in candidates {
            guard candidate.publishedAtSeq >= 0,
                  values[key].map({ current in
                      candidate.publishedAtSeq > current.publishedAtSeq
                          || candidate == current
                  }) ?? true else {
                throw JourneyReleaseAuthenticationError.replayRejected
            }
        }
        for (key, candidate) in candidates {
            if values[key].map({ candidate.publishedAtSeq > $0.publishedAtSeq }) ?? true {
                values[key] = candidate
            }
        }
    }

    func highWater(for key: JourneyReleaseHighWaterKey) -> JourneyReleaseHighWaterMark? {
        values[key]
    }
}

struct UnavailableJourneyReleaseHighWaterStore: JourneyReleaseHighWaterStore {
    func admitActiveBatch(
        _ candidates: [JourneyReleaseHighWaterKey: JourneyReleaseHighWaterMark]
    ) throws {
        _ = candidates
        throw JourneyReleaseAuthenticationError.replayRejected
    }

    func highWater(
        for key: JourneyReleaseHighWaterKey
    ) throws -> JourneyReleaseHighWaterMark? {
        throw JourneyReleaseAuthenticationError.replayRejected
    }
}

/// Durable replay authority. A cross-instance and cross-process target lock
/// covers read/compare/atomic-write so admission survives SDK and app restarts.
struct PersistentJourneyReleaseHighWaterStore: JourneyReleaseHighWaterStore {
    private let directory: URL
    private let lockScope: CacheFilesystemLockScope

    init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        lockScope = CacheFilesystemLockScope(cacheRootURL: self.directory)
        try FileManager.default.createDirectory(
            at: self.directory,
            withIntermediateDirectories: true
        )
    }

    func admitActiveBatch(
        _ candidates: [JourneyReleaseHighWaterKey: JourneyReleaseHighWaterMark]
    ) async throws {
        let targetURL = ledgerURL
        try await SharedCachePathCoordinator.shared.withExclusiveAccess(
            to: targetURL,
            lockScope: lockScope
        ) {
            var ledger = try Self.readLedger(targetURL)
            for (key, candidate) in candidates {
                let digest = Self.digest(for: key)
                guard candidate.publishedAtSeq >= 0,
                      ledger[digest].map({ current in
                          candidate.publishedAtSeq > current.publishedAtSeq
                              || candidate == current
                      }) ?? true else {
                    throw JourneyReleaseAuthenticationError.replayRejected
                }
            }
            for (key, candidate) in candidates {
                let digest = Self.digest(for: key)
                if ledger[digest].map({ candidate.publishedAtSeq > $0.publishedAtSeq }) ?? true {
                    ledger[digest] = candidate
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(ledger)
            try bytes.write(to: targetURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    func highWater(
        for key: JourneyReleaseHighWaterKey
    ) async throws -> JourneyReleaseHighWaterMark? {
        let targetURL = ledgerURL
        return try await SharedCachePathCoordinator.shared.withExclusiveAccess(
            to: targetURL,
            lockScope: lockScope
        ) {
            try Self.readLedger(targetURL)[Self.digest(for: key)]
        }
    }

    private var ledgerURL: URL {
        directory.appendingPathComponent("high-water-v1.json")
    }

    private static func digest(for key: JourneyReleaseHighWaterKey) -> String {
        let identity = "\(key.appId)\u{0}\(key.environment)\u{0}\(key.experienceId)"
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func readLedger(
        _ url: URL
    ) throws -> [String: JourneyReleaseHighWaterMark] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw JourneyReleaseAuthenticationError.replayRejected
        }
        guard let ledger = try? JSONDecoder().decode(
            [String: JourneyReleaseHighWaterMark].self,
            from: data
        ), ledger.allSatisfy({ key, value in
                  key.count == 64 && key.allSatisfy { $0.isHexDigit && !$0.isUppercase }
                      && value.publishedAtSeq >= 0
                      && value.descriptorSHA256.count == 64
                      && value.descriptorSHA256.allSatisfy {
                          $0.isHexDigit && !$0.isUppercase
                      }
                      && !value.experienceVersionId.isEmpty
                      && !value.buildId.isEmpty
                      && value.versionNumber >= 0
                      && !value.publishedAt.isEmpty
              }) else {
            throw JourneyReleaseAuthenticationError.replayRejected
        }
        return ledger
    }
}
