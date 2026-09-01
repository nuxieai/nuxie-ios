import CryptoKit
import Foundation

struct ExperienceReleaseStoragePaths: Sendable {
    let objects: URL
    let admission: URL?

    static func resolve(
        customStoragePath: URL?,
        cachesDirectory: URL,
        applicationSupportDirectory: URL?
    ) -> Self {
        if let customStoragePath {
            let root = customStoragePath.appendingPathComponent(
                "nuxie_release_delivery",
                isDirectory: true
            )
            return Self(
                objects: root.appendingPathComponent("objects", isDirectory: true),
                admission: root.appendingPathComponent("admission", isDirectory: true)
            )
        }
        return Self(
            objects: cachesDirectory
                .appendingPathComponent("nuxie_release_delivery", isDirectory: true)
                .appendingPathComponent("objects", isDirectory: true),
            admission: applicationSupportDirectory.map {
                $0.appendingPathComponent("nuxie", isDirectory: true)
                    .appendingPathComponent("release_admission", isDirectory: true)
            }
        )
    }
}

struct ExperienceReleaseHighWaterKey: Hashable, Sendable {
    let appId: String
    let environment: String
    let experienceId: String
}

struct ExperienceReleaseHighWaterMark: Codable, Equatable, Sendable {
    let releaseSequence: Int
    let experienceVersionId: String
    let buildId: String
    let versionNumber: Int
    let releaseCreatedAt: String
    let descriptorSHA256: String
}

protocol ExperienceReleaseHighWaterStore: Sendable {
    func admitActiveBatch(
        _ candidates: [ExperienceReleaseHighWaterKey: ExperienceReleaseHighWaterMark]
    ) async throws
    func highWater(
        for key: ExperienceReleaseHighWaterKey
    ) async throws -> ExperienceReleaseHighWaterMark?
}

actor InMemoryExperienceReleaseHighWaterStore: ExperienceReleaseHighWaterStore {
    private var values: [ExperienceReleaseHighWaterKey: ExperienceReleaseHighWaterMark] = [:]

    func admitActiveBatch(
        _ candidates: [ExperienceReleaseHighWaterKey: ExperienceReleaseHighWaterMark]
    ) throws {
        for (key, candidate) in candidates {
            guard candidate.releaseSequence >= 0,
                  values[key].map({ current in
                      candidate.releaseSequence > current.releaseSequence
                          || candidate == current
                  }) ?? true else {
                throw ExperienceReleaseDescriptorAuthenticationError.replayRejected
            }
        }
        for (key, candidate) in candidates {
            if values[key].map({ candidate.releaseSequence > $0.releaseSequence }) ?? true {
                values[key] = candidate
            }
        }
    }

    func highWater(for key: ExperienceReleaseHighWaterKey) -> ExperienceReleaseHighWaterMark? {
        values[key]
    }
}

struct UnavailableExperienceReleaseHighWaterStore: ExperienceReleaseHighWaterStore {
    func admitActiveBatch(
        _ candidates: [ExperienceReleaseHighWaterKey: ExperienceReleaseHighWaterMark]
    ) throws {
        _ = candidates
        throw ExperienceReleaseDescriptorAuthenticationError.replayRejected
    }

    func highWater(
        for key: ExperienceReleaseHighWaterKey
    ) throws -> ExperienceReleaseHighWaterMark? {
        throw ExperienceReleaseDescriptorAuthenticationError.replayRejected
    }
}

/// Durable replay authority. A cross-instance and cross-process target lock
/// covers read/compare/atomic-write so admission survives SDK and app restarts.
struct PersistentExperienceReleaseHighWaterStore: ExperienceReleaseHighWaterStore {
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
        _ candidates: [ExperienceReleaseHighWaterKey: ExperienceReleaseHighWaterMark]
    ) async throws {
        let targetURL = ledgerURL
        try await SharedCachePathCoordinator.shared.withExclusiveAccess(
            to: targetURL,
            lockScope: lockScope
        ) {
            var ledger = try Self.readLedger(targetURL)
            for (key, candidate) in candidates {
                let digest = Self.digest(for: key)
                guard candidate.releaseSequence >= 0,
                      ledger[digest].map({ current in
                          candidate.releaseSequence > current.releaseSequence
                              || candidate == current
                      }) ?? true else {
                    throw ExperienceReleaseDescriptorAuthenticationError.replayRejected
                }
            }
            for (key, candidate) in candidates {
                let digest = Self.digest(for: key)
                if ledger[digest].map({ candidate.releaseSequence > $0.releaseSequence }) ?? true {
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
        for key: ExperienceReleaseHighWaterKey
    ) async throws -> ExperienceReleaseHighWaterMark? {
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

    private static func digest(for key: ExperienceReleaseHighWaterKey) -> String {
        let identity = "\(key.appId)\u{0}\(key.environment)\u{0}\(key.experienceId)"
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func readLedger(
        _ url: URL
    ) throws -> [String: ExperienceReleaseHighWaterMark] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ExperienceReleaseDescriptorAuthenticationError.replayRejected
        }
        guard let ledger = try? JSONDecoder().decode(
            [String: ExperienceReleaseHighWaterMark].self,
            from: data
        ), ledger.allSatisfy({ key, value in
                  key.count == 64 && key.allSatisfy { $0.isHexDigit && !$0.isUppercase }
                      && value.releaseSequence >= 0
                      && value.descriptorSHA256.count == 64
                      && value.descriptorSHA256.allSatisfy {
                          $0.isHexDigit && !$0.isUppercase
                      }
                      && !value.experienceVersionId.isEmpty
                      && !value.buildId.isEmpty
                      && value.versionNumber >= 0
                      && !value.releaseCreatedAt.isEmpty
              }) else {
            throw ExperienceReleaseDescriptorAuthenticationError.replayRejected
        }
        return ledger
    }
}

enum ExperienceReleaseAdmissionMode: Equatable, Sendable {
    case active
    case pinned(
        experienceVersionId: String,
        buildId: String,
        descriptorSHA256: String
    )
}

/// Production-facing release admission. Replay state is owned by this actor;
/// callers choose active delivery or an exact signed pin, never a minimum seq.
actor ExperienceReleaseAdmission {
    private let store: any ExperienceReleaseHighWaterStore
    private let verifier = ExperienceReleaseDescriptorVerifier()

    init(store: any ExperienceReleaseHighWaterStore) {
        self.store = store
    }

    struct Candidate: Sendable {
        let envelopeBytes: Data
        let authorizationKeys: [ExperiencePackageAuthorizationKey]
        let expectedIdentity: ExperienceReleaseIdentityExpectation
        let supportedRuntime: ExperienceReleaseSupportedRuntime
        let mode: ExperienceReleaseAdmissionMode
    }

    struct AuthenticatedBatch: Sendable {
        let descriptors: [AuthenticatedExperienceReleaseDescriptor]
        fileprivate let promotions:
            [ExperienceReleaseHighWaterKey: ExperienceReleaseHighWaterMark]
    }

    func authenticate(
        _ candidates: [Candidate]
    ) async throws -> AuthenticatedBatch {
        var authenticated: [AuthenticatedExperienceReleaseDescriptor] = []
        var promotions:
            [ExperienceReleaseHighWaterKey: ExperienceReleaseHighWaterMark] = [:]
        authenticated.reserveCapacity(candidates.count)
        for candidate in candidates {
            let replayPolicy: ExperienceReleaseReplayPolicy
            switch candidate.mode {
            case .active:
                let identity = candidate.expectedIdentity.identity
                let key = ExperienceReleaseHighWaterKey(
                    appId: identity.appId,
                    environment: identity.environment,
                    experienceId: identity.experienceId
                )
                replayPolicy = .active(
                    minimumReleaseSequence:
                        try await store.highWater(for: key)?.releaseSequence ?? 0
                )
            case .pinned(let experienceVersionId, let buildId, let descriptorSHA256):
                replayPolicy = .pinned(
                    experienceVersionId: experienceVersionId,
                    buildId: buildId,
                    descriptorSHA256: descriptorSHA256
                )
            }
            let value = try verifier.authenticate(
                envelopeBytes: candidate.envelopeBytes,
                authorizationKeys: candidate.authorizationKeys,
                expectedIdentity: candidate.expectedIdentity,
                supportedRuntime: candidate.supportedRuntime,
                replayPolicy: replayPolicy
            )
            authenticated.append(value)
            if case .active = candidate.mode {
                let identity = value.descriptor.identity
                let key = ExperienceReleaseHighWaterKey(
                    appId: identity.appId,
                    environment: identity.environment,
                    experienceId: identity.experienceId
                )
                let mark = ExperienceReleaseHighWaterMark(
                    releaseSequence: identity.releaseSequence,
                    experienceVersionId: identity.experienceVersionId,
                    buildId: identity.buildId,
                    versionNumber: identity.versionNumber,
                    releaseCreatedAt: identity.releaseCreatedAt,
                    descriptorSHA256: value.descriptorSHA256
                )
                if let existing = promotions[key] {
                    if mark.releaseSequence > existing.releaseSequence {
                        promotions[key] = mark
                    } else if mark.releaseSequence == existing.releaseSequence,
                              mark != existing {
                        throw ExperienceReleaseDescriptorAuthenticationError.replayRejected
                    }
                } else {
                    promotions[key] = mark
                }
            }
        }
        return AuthenticatedBatch(
            descriptors: authenticated,
            promotions: promotions
        )
    }

    func commit(_ batch: AuthenticatedBatch) async throws {
        try await store.admitActiveBatch(batch.promotions)
    }

    func commit(_ batches: [AuthenticatedBatch]) async throws {
        var promotions: [
            ExperienceReleaseHighWaterKey: ExperienceReleaseHighWaterMark
        ] = [:]
        for batch in batches {
            for (key, mark) in batch.promotions {
                if let existing = promotions[key] {
                    if mark.releaseSequence > existing.releaseSequence {
                        promotions[key] = mark
                    } else if mark.releaseSequence == existing.releaseSequence,
                              mark != existing {
                        throw ExperienceReleaseDescriptorAuthenticationError.replayRejected
                    }
                } else {
                    promotions[key] = mark
                }
            }
        }
        try await store.admitActiveBatch(promotions)
    }

    func authenticateAndAdmit(
        envelopeBytes: Data,
        authorizationKeys: [ExperiencePackageAuthorizationKey],
        expectedIdentity: ExperienceReleaseIdentityExpectation,
        supportedRuntime: ExperienceReleaseSupportedRuntime,
        mode: ExperienceReleaseAdmissionMode
    ) async throws -> AuthenticatedExperienceReleaseDescriptor {
        let batch = try await authenticate([Candidate(
            envelopeBytes: envelopeBytes,
            authorizationKeys: authorizationKeys,
            expectedIdentity: expectedIdentity,
            supportedRuntime: supportedRuntime,
            mode: mode
        )])
        try await commit(batch)
        return batch.descriptors[0]
    }
}
