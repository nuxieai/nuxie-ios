import Foundation

struct JourneyReleasePinReferences: Sendable {
    let descriptorSHA256s: Set<String>
    let artifactSHA256s: Set<String>
}

/// Owns the content-addressed release and artifact files retained by live
/// device-owned journeys. Callers provide the journal transaction and the
/// exact references that remain live; this store owns path validation,
/// bounded I/O, rollback, budgets, and orphan cleanup.
struct JourneyReleasePinStore: Sendable {
    struct PreparedAdmission: Sendable {
        let artifactSHA256s: [String]
        fileprivate let createdFiles: [URL]

        func rollback() {
            for file in createdFiles {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    static let defaultBudgetBytes = 256 * 1_024 * 1_024
    static let defaultCountLimit = 1_024

    private static let maximumReleaseBytes =
        JourneyReleaseLimits.profileBytes

    private let root: URL
    private let customerDirectory: URL
    private let budgetBytes: Int
    private let countLimit: Int

    init(
        journalRoot: URL,
        customerDigest: String,
        budgetBytes: Int,
        countLimit: Int
    ) {
        root = journalRoot.appendingPathComponent(
            "release-pins",
            isDirectory: true
        )
        customerDirectory = root.appendingPathComponent(
            customerDigest,
            isDirectory: true
        )
        self.budgetBytes = max(0, budgetBytes)
        self.countLimit = max(0, countLimit)
    }

    func ensureCustomerDirectory() throws {
        try FileManager.default.createDirectory(
            at: customerDirectory,
            withIntermediateDirectories: true
        )
    }

    func prepareAdmission(
        release: JourneyReleaseProfileEntry,
        descriptorSHA256: String,
        artifactSource: JourneyReleaseArtifactSource?,
        inheritedArtifactSHA256s: [String]
    ) throws -> PreparedAdmission {
        let releaseBytes = try ExactJSONCodec.encode(release)
        guard releaseBytes.count <= Self.maximumReleaseBytes else {
            throw JourneyJournalError.storageLimit
        }
        let pinFile = try releasePinFile(descriptorSHA256: descriptorSHA256)
        let pinExisted = FileManager.default.fileExists(atPath: pinFile.path)
        let inventory = try inventory()
        guard inventory.count <= countLimit,
              inventory.totalBytes <= budgetBytes else {
            throw JourneyJournalError.storageLimit
        }

        var createdFiles: [URL] = []
        var projectedBytes = inventory.totalBytes
        do {
            if pinExisted {
                guard try loadReleaseBytes(pinFile) == releaseBytes else {
                    throw JourneyJournalError.invalidState
                }
            } else {
                let (nextBytes, overflowed) = projectedBytes
                    .addingReportingOverflow(releaseBytes.count)
                guard inventory.count < countLimit,
                      !overflowed,
                      nextBytes <= budgetBytes else {
                    throw JourneyJournalError.storageLimit
                }
                try releaseBytes.write(
                    to: pinFile,
                    options: [
                        .atomic,
                        .completeFileProtectionUntilFirstUserAuthentication,
                    ]
                )
                createdFiles.append(pinFile)
                projectedBytes = nextBytes
            }

            let artifactSHA256s: [String]
            if let artifactSource {
                artifactSHA256s = try pinArtifacts(
                    artifactSource,
                    projectedBytes: &projectedBytes,
                    createdFiles: &createdFiles
                )
            } else {
                artifactSHA256s = inheritedArtifactSHA256s
            }
            return PreparedAdmission(
                artifactSHA256s: artifactSHA256s,
                createdFiles: createdFiles
            )
        } catch {
            PreparedAdmission(
                artifactSHA256s: [],
                createdFiles: createdFiles
            ).rollback()
            throw error
        }
    }

    func release(
        descriptorSHA256: String
    ) throws -> JourneyReleaseProfileEntry? {
        let file = try releasePinFile(descriptorSHA256: descriptorSHA256)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }
        return try ExactJSONCodec.decode(
            JourneyReleaseProfileEntry.self,
            from: loadReleaseBytes(file)
        )
    }

    func pinnedArtifacts(
        sha256s: [String]
    ) throws -> JourneyPinnedReleaseArtifacts {
        var objectURLsBySHA256: [String: URL] = [:]
        for sha256 in sha256s {
            let file = try artifactPinFile(sha256: sha256)
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw JourneyJournalError.invalidState
            }
            objectURLsBySHA256[sha256] = file
        }
        return JourneyPinnedReleaseArtifacts(
            objectURLsBySHA256: objectURLsBySHA256
        )
    }

    func removeUnreferenced(
        _ references: JourneyReleasePinReferences
    ) throws {
        let fileManager = FileManager.default
        for file in try fileManager.contentsOfDirectory(
            at: customerDirectory,
            includingPropertiesForKeys: nil
        ) {
            let sha256 = file.deletingPathExtension().lastPathComponent
            let isReferencedDescriptor = file.pathExtension == "json"
                && (try? releasePinFile(descriptorSHA256: sha256)) != nil
                && references.descriptorSHA256s.contains(sha256)
            let isReferencedArtifact = file.pathExtension == "artifact"
                && (try? artifactPinFile(sha256: sha256)) != nil
                && references.artifactSHA256s.contains(sha256)
            if !isReferencedDescriptor && !isReferencedArtifact {
                try fileManager.removeItem(at: file)
            }
        }
    }

    func removeGlobalOrphans(
        journalRoot: URL,
        referencesForJournal:
            (URL) throws -> JourneyReleasePinReferences
    ) throws {
        let fileManager = FileManager.default
        let excluded = customerDirectory.lastPathComponent
        for directory in try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) {
            let customerDigest = directory.lastPathComponent
            let attributes = try fileManager.attributesOfItem(
                atPath: directory.path
            )
            guard Self.isLowercaseSHA256(customerDigest),
                  attributes[.type] as? FileAttributeType == .typeDirectory else {
                try fileManager.removeItem(at: directory)
                continue
            }
            guard customerDigest != excluded else { continue }
            let journalFile = journalRoot.appendingPathComponent(
                "\(customerDigest).json",
                isDirectory: false
            )
            guard fileManager.fileExists(atPath: journalFile.path) else {
                try fileManager.removeItem(at: directory)
                continue
            }
            guard let references = try? referencesForJournal(journalFile) else {
                // A transiently unreadable journal may still be recoverable.
                // Its pins continue to count against the global budget.
                continue
            }
            try removeUnreferenced(
                references,
                from: directory
            )
        }
    }

    static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
    }

    private func releasePinFile(descriptorSHA256: String) throws -> URL {
        guard Self.isLowercaseSHA256(descriptorSHA256) else {
            throw JourneyJournalError.invalidState
        }
        return customerDirectory.appendingPathComponent(
            "\(descriptorSHA256).json",
            isDirectory: false
        )
    }

    private func artifactPinFile(sha256: String) throws -> URL {
        try Self.artifactPinFile(
            sha256: sha256,
            directory: customerDirectory
        )
    }

    private static func artifactPinFile(
        sha256: String,
        directory: URL
    ) throws -> URL {
        guard isLowercaseSHA256(sha256) else {
            throw JourneyJournalError.invalidState
        }
        return directory.appendingPathComponent(
            "\(sha256).artifact",
            isDirectory: false
        )
    }

    private func pinArtifacts(
        _ source: JourneyReleaseArtifactSource,
        projectedBytes: inout Int,
        createdFiles: inout [URL]
    ) throws -> [String] {
        guard source.objects.count
                <= JourneyReleaseLimits.assetCount
                    + JourneyReleaseLimits.screenCount
                    + 1,
              Set(source.objects.map(\.sha256)).count == source.objects.count else {
            throw JourneyJournalError.invalidState
        }
        var declaredBytes = 0
        for object in source.objects {
            guard Self.isLowercaseSHA256(object.sha256),
                  object.sizeBytes > 0,
                  object.sizeBytes
                    <= JourneyReleaseLimits.rivArtifactBytes else {
                throw JourneyJournalError.invalidState
            }
            let (nextBytes, overflowed) = declaredBytes.addingReportingOverflow(
                object.sizeBytes
            )
            guard !overflowed,
                  nextBytes
                    <= JourneyReleaseLimits.artifactAggregateBytes else {
                throw JourneyJournalError.storageLimit
            }
            declaredBytes = nextBytes
        }

        var pinned: [String] = []
        pinned.reserveCapacity(source.objects.count)
        for object in source.objects.sorted(by: { $0.sha256 < $1.sha256 }) {
            let destination = try artifactPinFile(sha256: object.sha256)
            if FileManager.default.fileExists(atPath: destination.path) {
                let retained = try BoundedFileIO.read(
                    at: destination,
                    maximumBytes: object.sizeBytes
                )
                guard retained.digest.byteCount == object.sizeBytes,
                      retained.digest.sha256 == object.sha256 else {
                    throw JourneyJournalError.invalidState
                }
                pinned.append(object.sha256)
                continue
            }

            let sourceFile = source.cacheRoot.appendingPathComponent(
                object.sha256,
                isDirectory: false
            )
            guard FileManager.default.fileExists(atPath: sourceFile.path) else {
                if object.required {
                    throw JourneyJournalError.invalidState
                }
                continue
            }
            let acquired = try BoundedFileIO.read(
                at: sourceFile,
                maximumBytes: object.sizeBytes
            )
            guard acquired.digest.byteCount == object.sizeBytes,
                  acquired.digest.sha256 == object.sha256 else {
                throw JourneyJournalError.invalidState
            }
            let (nextBytes, overflowed) = projectedBytes
                .addingReportingOverflow(acquired.data.count)
            guard !overflowed, nextBytes <= budgetBytes else {
                throw JourneyJournalError.storageLimit
            }
            try acquired.data.write(
                to: destination,
                options: [
                    .atomic,
                    .completeFileProtectionUntilFirstUserAuthentication,
                ]
            )
            createdFiles.append(destination)
            projectedBytes = nextBytes
            pinned.append(object.sha256)
        }
        return pinned
    }

    private func loadReleaseBytes(_ file: URL) throws -> Data {
        try BoundedFileIO.read(
            at: file,
            maximumBytes: Self.maximumReleaseBytes
        ).data
    }

    private func inventory() throws -> (count: Int, totalBytes: Int) {
        let fileManager = FileManager.default
        var count = 0
        var totalBytes = 0
        for directory in try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) {
            let customerDigest = directory.lastPathComponent
            let directoryAttributes = try fileManager.attributesOfItem(
                atPath: directory.path
            )
            guard Self.isLowercaseSHA256(customerDigest),
                  directoryAttributes[.type] as? FileAttributeType
                    == .typeDirectory else {
                throw JourneyJournalError.invalidState
            }
            for file in try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) {
                let sha256 = file.deletingPathExtension().lastPathComponent
                let isDescriptor = file.pathExtension == "json"
                    && Self.isLowercaseSHA256(sha256)
                let isArtifact = file.pathExtension == "artifact"
                    && (try? Self.artifactPinFile(
                        sha256: sha256,
                        directory: directory
                    )) != nil
                guard isDescriptor || isArtifact else {
                    throw JourneyJournalError.invalidState
                }
                let bytes = try regularFileSize(
                    file,
                    maximumBytes: isDescriptor
                        ? Self.maximumReleaseBytes
                        : JourneyReleaseLimits.rivArtifactBytes
                )
                let (nextTotal, overflowed) = totalBytes
                    .addingReportingOverflow(bytes)
                guard !overflowed else {
                    throw JourneyJournalError.storageLimit
                }
                totalBytes = nextTotal
                if isDescriptor { count += 1 }
            }
        }
        return (count, totalBytes)
    }

    private func removeUnreferenced(
        _ references: JourneyReleasePinReferences,
        from directory: URL
    ) throws {
        let fileManager = FileManager.default
        for file in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            let sha256 = file.deletingPathExtension().lastPathComponent
            let isReferencedDescriptor = file.pathExtension == "json"
                && Self.isLowercaseSHA256(sha256)
                && references.descriptorSHA256s.contains(sha256)
            let isReferencedArtifact = file.pathExtension == "artifact"
                && (try? Self.artifactPinFile(
                    sha256: sha256,
                    directory: directory
                )) != nil
                && references.artifactSHA256s.contains(sha256)
            if !isReferencedDescriptor && !isReferencedArtifact {
                try fileManager.removeItem(at: file)
            }
        }
    }

    private func regularFileSize(
        _ file: URL,
        maximumBytes: Int
    ) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: file.path
        )
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            throw JourneyJournalError.invalidState
        }
        let value = size.int64Value
        guard value >= 0, value <= Int64(maximumBytes) else {
            throw JourneyJournalError.storageLimit
        }
        return Int(value)
    }
}
