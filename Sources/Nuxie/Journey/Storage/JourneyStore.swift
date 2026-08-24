import Foundation

/// Protocol for journey storage operations
protocol JourneyStoreProtocol: Sendable {
    /// Save an active journey
    func saveJourney(_ journey: JourneySnapshot) throws
    
    /// Load all active journeys
    func loadActiveJourneys() -> [JourneySnapshot]
    
    /// Load a specific journey by ID
    func loadJourney(id: String) -> JourneySnapshot?
    
    /// Delete a journey
    func deleteJourney(id: String)
    
    /// Record journey completion
    func recordCompletion(_ record: JourneyCompletionRecord) throws
    
    /// Check if experience was ever completed by user
    func hasCompletedExperience(distinctId: String, experienceId: String) -> Bool
    
    /// Get last completion time for experience
    func lastCompletionTime(distinctId: String, experienceId: String) -> Date?
    
    /// Clean up old journeys and records
    func cleanup(olderThan date: Date)

    /// Durable local-routing receipt for a captured event. Journey routing is
    /// a separate side effect from EventLog network delivery, so its own
    /// owner must make stable event retries idempotent.
    func hasHandledEvent(id: String) -> Bool
    func recordHandledEvent(id: String, handledAt: Date) throws
    
    
    
}

/// Flat file storage for journey state
// @unchecked Sendable: stateless beyond immutable directories/coders; all
// journey mutations experience through the JourneyService actor.
final class JourneyStore: JourneyStoreProtocol, @unchecked Sendable {

    private enum StorageError: Error {
        case identifierMismatch
    }

    private static let activeFilePrefix = "journey_v1_"
    private static let completionUserPrefix = "user_v1_"
    private static let completionFilePrefix = "experience_v1_"
    
    // MARK: - Properties
    
    private let baseDir: URL
    private let activeDir: URL
    private let completedDir: URL
    private let handledEventsFile: URL
    
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    // MARK: - Dependencies
    
    private let dateProvider: DateProviderProtocol

    // MARK: - Initialization

    init(
        customStoragePath: URL? = nil,
        dateProvider: DateProviderProtocol
    ) {
        self.dateProvider = dateProvider
        // Set up directories
        let baseStoragePath: URL
        if let customPath = customStoragePath {
            // Use custom path with nuxie subdirectory
            baseStoragePath = customPath.appendingPathComponent("nuxie", isDirectory: true)
        } else {
            // Use default Application Support/nuxie directory
            baseStoragePath = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent("nuxie", isDirectory: true)
        }
        
        self.baseDir = baseStoragePath.appendingPathComponent("journeys")
        self.activeDir = baseDir.appendingPathComponent("active")
        self.completedDir = baseDir.appendingPathComponent("completed")
        self.handledEventsFile = baseDir.appendingPathComponent("handled-events.json")
        
        // Configure encoder/decoder
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        
        // Create directories if needed
        createDirectoriesIfNeeded()
        
        LogInfo("JourneyStore initialized at: \(baseDir.path)")
    }
    
    // MARK: - Public Methods
    
    /// Save an active journey
    public func saveJourney(_ journey: JourneySnapshot) throws {
        let file = activeFile(for: journey.id)
        let data = try encoder.encode(journey)
        
        try data.write(to: file, options: .atomic)
        LogDebug("Saved journey \(journey.id) to: \(file.lastPathComponent)")
    }
    
    /// Load all active journeys
    public func loadActiveJourneys() -> [JourneySnapshot] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: activeDir,
            includingPropertiesForKeys: nil
        ) else {
            LogWarning("Failed to list active journey files")
            return []
        }
        
        let journeys = files.compactMap { file -> JourneySnapshot? in
            guard Self.isCurrentActiveFileName(file.lastPathComponent) else {
                return nil
            }
            
            do {
                let data = try Data(contentsOf: file)
                guard hasSupportedStateVersion(data, fileName: file.lastPathComponent) else {
                    return nil
                }
                let journey = try decoder.decode(JourneySnapshot.self, from: data)
                guard file.lastPathComponent == Self.activeFileName(for: journey.id) else {
                    LogError("Rejected journey file whose name does not match its identifier")
                    return nil
                }
                return journey
            } catch {
                LogError("Failed to load journey from \(file.lastPathComponent): \(error)")
                // Consider deleting corrupt file
                try? FileManager.default.removeItem(at: file)
                return nil
            }
        }
        
        LogInfo("Loaded \(journeys.count) active journeys")
        return journeys
    }
    
    /// Load a specific journey by ID
    public func loadJourney(id: String) -> JourneySnapshot? {
        let file = activeFile(for: id)
        
        guard FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }
        
        do {
            let data = try Data(contentsOf: file)
            guard hasSupportedStateVersion(data, fileName: file.lastPathComponent) else {
                return nil
            }
            let journey = try decoder.decode(JourneySnapshot.self, from: data)
            guard Self.identifiersMatchExactly(journey.id, id) else {
                LogError("Rejected journey file whose payload identifier does not match its key")
                return nil
            }
            return journey
        } catch {
            LogError("Failed to load journey \(id): \(error)")
            return nil
        }
    }
    
    /// Delete a journey
    public func deleteJourney(id: String) {
        let file = activeFile(for: id)
        
        do {
            try FileManager.default.removeItem(at: file)
            LogDebug("Deleted journey file: \(file.lastPathComponent)")
        } catch {
            // File might not exist, which is fine
            LogDebug("Journey file not found for deletion: \(id)")
        }
    }
    
    /// Record journey completion (for frequency tracking)
    public func recordCompletion(_ record: JourneyCompletionRecord) throws {
        let userDir = completionUserDirectory(for: record.distinctId)
        try FileManager.default.createDirectory(
            at: userDir,
            withIntermediateDirectories: true
        )

        let file = completionFile(
            distinctId: record.distinctId,
            experienceId: record.experienceId
        )

        var records: [JourneyCompletionRecord] = []
        if FileManager.default.fileExists(atPath: file.path) {
            let existingData = try Data(contentsOf: file)
            let existingRecords = try decoder.decode([JourneyCompletionRecord].self, from: existingData)
            guard recordsMatch(
                existingRecords,
                distinctId: record.distinctId,
                experienceId: record.experienceId
            ) else {
                throw StorageError.identifierMismatch
            }
            records = existingRecords
        }
        
        // Append new record
        records.append(record)
        
        // Keep only last 10 completions per experience
        if records.count > 10 {
            records = Array(records.suffix(10))
        }
        
        // Save updated records
        let data = try encoder.encode(records)
        try data.write(to: file, options: .atomic)
        
        LogDebug("Recorded completion for experience \(record.experienceId), user \(record.distinctId)")
    }
    
    /// Checks whether a user has completed an experience.
    ///
    /// - Parameters:
    ///   - distinctId: User identifier.
    ///   - experienceId: Stable experience definition identifier.
    /// - Returns: `true` when at least one completion is stored.
    public func hasCompletedExperience(distinctId: String, experienceId: String) -> Bool {
        guard let records = loadCompletionRecords(
            distinctId: distinctId,
            experienceId: experienceId
        ) else { return false }
        return !records.isEmpty
    }
    
    /// Returns the user's most recent completion time for an experience.
    ///
    /// - Parameters:
    ///   - distinctId: User identifier.
    ///   - experienceId: Stable experience definition identifier.
    /// - Returns: Most recent completion timestamp, or `nil` when none exists.
    public func lastCompletionTime(distinctId: String, experienceId: String) -> Date? {
        loadCompletionRecords(
            distinctId: distinctId,
            experienceId: experienceId
        )?.last?.completedAt
    }
    
    /// Clean up old journeys and records
    public func cleanup(olderThan date: Date) {
        cleanupCurrentFiles(
            in: activeDir,
            olderThan: date,
            matching: Self.isCurrentActiveFileName
        )
        
        // Clean up completion records older than 90 days
        let ninetyDaysAgo = dateProvider.date(byAddingTimeInterval: -90 * 24 * 3600, to: dateProvider.now())
        cleanupCompletionRecords(olderThan: ninetyDaysAgo)

        var receipts = loadHandledEvents()
        receipts = receipts.filter { $0.value >= ninetyDaysAgo }
        try? saveHandledEvents(receipts)
        
        LogInfo("Cleaned up journeys older than \(date)")
    }

    public func hasHandledEvent(id: String) -> Bool {
        loadHandledEvents()[id] != nil
    }

    public func recordHandledEvent(id: String, handledAt: Date) throws {
        var receipts = loadHandledEvents()
        guard receipts[id] == nil else { return }
        receipts[id] = handledAt
        try saveHandledEvents(receipts)
    }
    
    // MARK: - Private Methods

    private func loadHandledEvents() -> [String: Date] {
        guard let data = try? Data(contentsOf: handledEventsFile) else { return [:] }
        return (try? decoder.decode([String: Date].self, from: data)) ?? [:]
    }

    private func saveHandledEvents(_ receipts: [String: Date]) throws {
        let data = try encoder.encode(receipts)
        try data.write(to: handledEventsFile, options: .atomic)
    }

    private func activeFile(for id: String) -> URL {
        activeDir.appendingPathComponent(Self.activeFileName(for: id))
    }

    private static func activeFileName(for id: String) -> String {
        "\(activeFilePrefix)\(opaqueKey(domain: "active-journey", identifier: id)).json"
    }

    private func completionUserDirectory(for distinctId: String) -> URL {
        completedDir.appendingPathComponent(
            "\(Self.completionUserPrefix)\(Self.opaqueKey(domain: "completion-user", identifier: distinctId))",
            isDirectory: true
        )
    }

    private func completionFile(distinctId: String, experienceId: String) -> URL {
        completionUserDirectory(for: distinctId).appendingPathComponent(
            "\(Self.completionFilePrefix)\(Self.opaqueKey(domain: "completion-experience", identifier: experienceId)).json"
        )
    }

    private static func opaqueKey(domain: String, identifier: String) -> String {
        var material = Data("nuxie-journey-store-v1:\(domain)".utf8)
        material.append(0)
        material.append(contentsOf: identifier.utf8)
        return SHA256Provider.hexDigest(material)
    }

    private static func identifiersMatchExactly(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private static func isCurrentActiveFileName(_ name: String) -> Bool {
        isOpaqueName(name, prefix: activeFilePrefix, suffix: ".json")
    }

    private static func isCurrentCompletionUserDirectoryName(_ name: String) -> Bool {
        isOpaqueName(name, prefix: completionUserPrefix, suffix: "")
    }

    private static func isCurrentCompletionFileName(_ name: String) -> Bool {
        isOpaqueName(name, prefix: completionFilePrefix, suffix: ".json")
    }

    private static func isOpaqueName(_ name: String, prefix: String, suffix: String) -> Bool {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let digestStart = name.index(name.startIndex, offsetBy: prefix.count)
        let digestEnd = name.index(name.endIndex, offsetBy: -suffix.count)
        let digest = name[digestStart..<digestEnd]
        return digest.count == 64 && digest.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private func loadCompletionRecords(
        distinctId: String,
        experienceId: String
    ) -> [JourneyCompletionRecord]? {
        let file = completionFile(distinctId: distinctId, experienceId: experienceId)
        guard let data = try? Data(contentsOf: file),
              let records = try? decoder.decode([JourneyCompletionRecord].self, from: data),
              recordsMatch(records, distinctId: distinctId, experienceId: experienceId) else {
            return nil
        }
        return records
    }

    private func recordsMatch(
        _ records: [JourneyCompletionRecord],
        distinctId: String,
        experienceId: String
    ) -> Bool {
        records.allSatisfy {
            Self.identifiersMatchExactly($0.distinctId, distinctId)
                && Self.identifiersMatchExactly($0.experienceId, experienceId)
        }
    }

    private func hasSupportedStateVersion(_ data: Data, fileName: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["stateVersion"] as? Int else {
            LogError("Retaining journey \(fileName) without stateVersion")
            return false
        }
        guard version == JourneyStateEnvelope.currentVersion else {
            LogError(
                "Retaining journey \(fileName) with unsupported stateVersion \(version)"
            )
            return false
        }
        return true
    }

    private func createDirectoriesIfNeeded() {
        do {
            try FileManager.default.createDirectory(
                at: activeDir,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: completedDir,
                withIntermediateDirectories: true
            )
        } catch {
            LogError("Failed to create journey directories: \(error)")
        }
    }
    
    private func cleanupCompletionRecords(olderThan date: Date) {
        guard let userDirectories = try? FileManager.default.contentsOfDirectory(
            at: completedDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        for userDirectory in userDirectories
        where Self.isCurrentCompletionUserDirectoryName(userDirectory.lastPathComponent) {
            cleanupCurrentFiles(
                in: userDirectory,
                olderThan: date,
                matching: Self.isCurrentCompletionFileName
            )
        }
    }

    private func cleanupCurrentFiles(
        in directory: URL,
        olderThan date: Date,
        matching isCurrentFileName: (String) -> Bool
    ) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey]
        ) else { return }

        for file in files where isCurrentFileName(file.lastPathComponent) {
            guard let values = try? file.resourceValues(
                forKeys: [.creationDateKey, .isRegularFileKey]
            ), values.isRegularFile == true,
              let creationDate = values.creationDate,
              creationDate < date else { continue }
            try? FileManager.default.removeItem(at: file)
            LogDebug("Deleted old file: \(file.lastPathComponent)")
        }
    }
}
