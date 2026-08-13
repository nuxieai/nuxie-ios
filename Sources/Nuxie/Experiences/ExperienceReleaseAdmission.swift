import CryptoKit
import Foundation

struct ExperienceReleaseHighWaterKey: Hashable, Sendable {
    let appId: String
    let environment: String
    let experienceId: String
}

protocol ExperienceReleaseHighWaterStore: Sendable {
    func admitActive(
        key: ExperienceReleaseHighWaterKey,
        publishedAtSeq: Int
    ) async throws
    func highWater(for key: ExperienceReleaseHighWaterKey) async throws -> Int?
}

actor InMemoryExperienceReleaseHighWaterStore: ExperienceReleaseHighWaterStore {
    private var values: [ExperienceReleaseHighWaterKey: Int] = [:]

    func admitActive(
        key: ExperienceReleaseHighWaterKey,
        publishedAtSeq: Int
    ) throws {
        let current = values[key]
        guard current.map({ publishedAtSeq >= $0 }) ?? true else {
            throw ExperienceReleaseDescriptorAuthenticationError.replayRejected
        }
        values[key] = max(current ?? publishedAtSeq, publishedAtSeq)
    }

    func highWater(for key: ExperienceReleaseHighWaterKey) -> Int? {
        values[key]
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

    func admitActive(
        key: ExperienceReleaseHighWaterKey,
        publishedAtSeq: Int
    ) async throws {
        guard publishedAtSeq >= 0 else {
            throw ExperienceReleaseDescriptorAuthenticationError.replayRejected
        }
        let targetURL = fileURL(for: key)
        try await SharedCachePathCoordinator.shared.withExclusiveAccess(
            to: targetURL,
            lockScope: lockScope
        ) {
            let current = try Self.read(targetURL)
            guard current.map({ publishedAtSeq >= $0 }) ?? true else {
                throw ExperienceReleaseDescriptorAuthenticationError.replayRejected
            }
            let bytes = Data(String(max(current ?? publishedAtSeq, publishedAtSeq)).utf8)
            try bytes.write(to: targetURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    func highWater(for key: ExperienceReleaseHighWaterKey) async throws -> Int? {
        let targetURL = fileURL(for: key)
        return try await SharedCachePathCoordinator.shared.withExclusiveAccess(
            to: targetURL,
            lockScope: lockScope
        ) {
            try Self.read(targetURL)
        }
    }

    private func fileURL(for key: ExperienceReleaseHighWaterKey) -> URL {
        let identity = "\(key.appId)\u{0}\(key.environment)\u{0}\(key.experienceId)"
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent("\(digest).seq")
    }

    private static func read(_ url: URL) throws -> Int? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ExperienceReleaseDescriptorAuthenticationError.replayRejected
        }
        guard let text = String(data: data, encoding: .utf8),
              let value = Int(text), value >= 0,
              String(value) == text else {
            throw ExperienceReleaseDescriptorAuthenticationError.replayRejected
        }
        return value
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

    func authenticateAndAdmit(
        envelopeBytes: Data,
        authorizationKeys: [ExperiencePackageAuthorizationKey],
        expectedIdentity: ExperienceReleaseIdentityExpectation,
        supportedCompatibility: ExperienceReleaseSupportedCompatibility,
        mode: ExperienceReleaseAdmissionMode
    ) async throws -> AuthenticatedExperienceReleaseDescriptor {
        let replayPolicy: ExperienceReleaseReplayPolicy
        switch mode {
        case .active:
            replayPolicy = .active(minimumPublishedAtSeq: 0)
        case .pinned(let experienceVersionId, let buildId, let descriptorSHA256):
            replayPolicy = .pinned(
                experienceVersionId: experienceVersionId,
                buildId: buildId,
                descriptorSHA256: descriptorSHA256
            )
        }
        let authenticated = try verifier.authenticate(
            envelopeBytes: envelopeBytes,
            authorizationKeys: authorizationKeys,
            expectedIdentity: expectedIdentity,
            supportedCompatibility: supportedCompatibility,
            replayPolicy: replayPolicy
        )
        if case .active = mode {
            let identity = authenticated.descriptor.identity
            try await store.admitActive(
                key: ExperienceReleaseHighWaterKey(
                    appId: identity.appId,
                    environment: identity.environment,
                    experienceId: identity.experienceId
                ),
                publishedAtSeq: identity.publishedAtSeq
            )
        }
        return authenticated
    }
}
