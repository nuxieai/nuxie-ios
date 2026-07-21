import Foundation

/// Protocol for journey storage operations
protocol JourneyStoreProtocol {
    /// Save an active journey
    func saveJourney(_ journey: Journey) throws
    
    /// Load all active journeys
    func loadActiveJourneys() -> [Journey]
    
    /// Load a specific journey by ID
    func loadJourney(id: String) -> Journey?
    
    /// Delete a journey
    func deleteJourney(id: String)
    
    /// Record journey completion
    func recordCompletion(_ record: JourneyCompletionRecord) throws
    
    /// Check if campaign was ever completed by user
    func hasCompletedCampaign(distinctId: String, campaignId: String) -> Bool
    
    /// Get last completion time for campaign
    func lastCompletionTime(distinctId: String, campaignId: String) -> Date?
    
    /// Clean up old journeys and records
    func cleanup(olderThan date: Date)
    
    
    
}

/// Flat file storage for journey state
public final class JourneyStore: JourneyStoreProtocol {
    
    // MARK: - Properties
    
    private let baseDir: URL
    private let activeDir: URL
    private let completedDir: URL
    
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
    public func saveJourney(_ journey: Journey) throws {
        let file = activeDir.appendingPathComponent("journey_\(journey.id).json")
        let data = try encoder.encode(journey)
        
        try data.write(to: file, options: .atomic)
        LogDebug("Saved journey \(journey.id) to: \(file.lastPathComponent)")
    }
    
    /// Load all active journeys
    public func loadActiveJourneys() -> [Journey] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: activeDir,
            includingPropertiesForKeys: nil
        ) else {
            LogWarning("Failed to list active journey files")
            return []
        }
        
        let journeys = files.compactMap { file -> Journey? in
            guard file.pathExtension == "json",
                  file.lastPathComponent.hasPrefix("journey_") else {
                return nil
            }
            
            do {
                let data = try Data(contentsOf: file)
                return try decoder.decode(Journey.self, from: data)
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
    public func loadJourney(id: String) -> Journey? {
        let file = activeDir.appendingPathComponent("journey_\(id).json")
        
        guard FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }
        
        do {
            let data = try Data(contentsOf: file)
            return try decoder.decode(Journey.self, from: data)
        } catch {
            LogError("Failed to load journey \(id): \(error)")
            return nil
        }
    }
    
    /// Delete a journey
    public func deleteJourney(id: String) {
        let file = activeDir.appendingPathComponent("journey_\(id).json")
        
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
        // Create user directory if needed
        let userDir = completedDir.appendingPathComponent(record.distinctId)
        try? FileManager.default.createDirectory(
            at: userDir,
            withIntermediateDirectories: true
        )
        
        // Save completion record
        let file = userDir.appendingPathComponent("campaign_\(record.campaignId).json")
        
        // Load existing records or create new array
        var records: [JourneyCompletionRecord] = []
        if let existingData = try? Data(contentsOf: file),
           let existingRecords = try? decoder.decode([JourneyCompletionRecord].self, from: existingData) {
            records = existingRecords
        }
        
        // Append new record
        records.append(record)
        
        // Keep only last 10 completions per campaign
        if records.count > 10 {
            records = Array(records.suffix(10))
        }
        
        // Save updated records
        let data = try encoder.encode(records)
        try data.write(to: file, options: .atomic)
        
        LogDebug("Recorded completion for campaign \(record.campaignId), user \(record.distinctId)")
    }
    
    /// Check if campaign was ever completed by user
    public func hasCompletedCampaign(distinctId: String, campaignId: String) -> Bool {
        let file = completedDir
            .appendingPathComponent(distinctId)
            .appendingPathComponent("campaign_\(campaignId).json")
        
        return FileManager.default.fileExists(atPath: file.path)
    }
    
    /// Get last completion time for campaign
    public func lastCompletionTime(distinctId: String, campaignId: String) -> Date? {
        let file = completedDir
            .appendingPathComponent(distinctId)
            .appendingPathComponent("campaign_\(campaignId).json")
        
        guard let data = try? Data(contentsOf: file),
              let records = try? decoder.decode([JourneyCompletionRecord].self, from: data),
              let lastRecord = records.last else {
            return nil
        }
        
        return lastRecord.completedAt
    }
    
    /// Clean up old journeys and records
    public func cleanup(olderThan date: Date) {
        // Clean up active journeys
        cleanupDirectory(activeDir, olderThan: date, prefix: "journey_")
        
        // Clean up completion records older than 90 days
        let ninetyDaysAgo = dateProvider.date(byAddingTimeInterval: -90 * 24 * 3600, to: dateProvider.now())
        cleanupDirectory(completedDir, olderThan: ninetyDaysAgo, recursive: true)
        
        LogInfo("Cleaned up journeys older than \(date)")
    }
    
    // MARK: - Private Methods
    
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
    
    private func cleanupDirectory(_ directory: URL, olderThan date: Date, prefix: String? = nil, recursive: Bool = false) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: recursive ? [] : [.skipsSubdirectoryDescendants]
        ) else {
            return
        }
        
        for case let file as URL in enumerator {
            guard file.pathExtension == "json" else { continue }
            
            if let prefix = prefix,
               !file.lastPathComponent.hasPrefix(prefix) {
                continue
            }
            
            if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
               let creationDate = attributes[.creationDate] as? Date,
               creationDate < date {
                try? FileManager.default.removeItem(at: file)
                LogDebug("Deleted old file: \(file.lastPathComponent)")
            }
        }
    }
}
