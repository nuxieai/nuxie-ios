import Foundation

struct CustomerStoreOwner: Sendable, Equatable {
    let scope: JourneyStorageScope
    let userId: String
    var authorityScope: String { scope.conversionNamespace }
}

struct CustomerJourneyKey: Sendable, Equatable {
    let owner: CustomerStoreOwner
    let journeyId: String
    let legGeneration: Int64
}

struct CustomerScope: Sendable, Equatable {
    let owner: CustomerStoreOwner
    let executionEpoch: Int64
    let executionRevoked: Bool
    let openedStateVersion: String
}

struct CustomerStoreMetadata: Sendable, Equatable {
    let stateVersion: String
    let nextCaptureSequence: Int64
    let cutoverSequence: Int64
    let legacyCleanupPending: Bool
}

/// Integer milliseconds avoid a lossy round trip through Foundation Date.
struct CustomerResponseSaveRetry: Sendable, Equatable {
    let attempts: Int64
    let observedAt: Int64
    let nextAttemptAt: Int64
    let unknownFormSince: Int64?
    let lastCode: JourneyResponseSaveReply.Code
}

struct CustomerResponseSaveLane: Sendable {
    let experienceId: String
    let versionId: String
    let sequence: Int64
    let pending: JourneyResponseSave?
    let retry: CustomerResponseSaveRetry?
    let display: JourneyResponseSaveDisplay?
}

struct CustomerReleasePin: Sendable, Equatable {
    enum Kind: String, Sendable { case descriptor, artifact }
    let objectSHA256: String
    let kind: Kind
    let relativePath: String
    let sizeBytes: Int64
}

enum CustomerStoreError: Error {
    case invalidRow
    case wrongOwner
    case staleRevision
    case revoked
    case eventIdentityConflict
    case unsupportedStateVersion(String)
}

/// All commands execute on the event store's connection and writer actor.
/// Every typed execution command commits its complete boundary before returning.
protocol CustomerStore: Sendable {
    func executeCustomerCommand(_ command: CustomerExecutionCommand) async throws -> CustomerExecutionResult
    func activeJourneys(owner: CustomerStoreOwner) async throws -> [JourneyRun]
    func customerFrequency(owner: CustomerStoreOwner, experienceId: String) async throws -> Int64?
    func customerArmReceipts(owner: CustomerStoreOwner) async throws -> Set<JourneyStateArmReceipt>
    func customerWatches(owner: CustomerStoreOwner) async throws -> [String: JourneyConversionWatch]
    func customerLogPage(owner: CustomerStoreOwner, name: String?, startedAt: Int64, deadlineAt: Int64?, after: CustomerLogPosition?, limit: Int) async throws -> [StoredEvent]
    func customerMeasurementPage(owner: CustomerStoreOwner, throughEventId: String?, limit: Int) async throws -> [PendingConversionOccurrence]
    func customerResponseLanes(owner: CustomerStoreOwner) async throws -> [CustomerResponseLaneKey: CustomerResponseSaveLane]
    func customerResponseOwners(scope: JourneyStorageScope) async throws -> [String]
    func customerMetadata() async throws -> CustomerStoreMetadata
    func customerScope(owner: CustomerStoreOwner) async throws -> CustomerScope?
    func putCustomerScope(_ scope: CustomerScope) async throws
    func responseSaveLane(owner: CustomerStoreOwner, journeyId: String, formName: String) async throws -> CustomerResponseSaveLane?
    func putResponseSaveLane(owner: CustomerStoreOwner, journeyId: String, formName: String, lane: CustomerResponseSaveLane) async throws
    func releasePins(for key: CustomerJourneyKey) async throws -> [CustomerReleasePin]
    func replaceReleasePins(for key: CustomerJourneyKey, pins: [CustomerReleasePin]) async throws
    func committedReleasePinPaths() async throws -> Set<String>
    func openCustomerState(cutoverAt: Int64) async throws -> CustomerStoreMetadata
    func finishLegacyCleanup(cutoverSequence: Int64) async throws
    func historyCoverage(owner: CustomerStoreOwner) async throws -> Int64?
    func advanceHistoryCoverage(owner: CustomerStoreOwner, to milliseconds: Int64) async throws
}


/// Adapters can supply the customer writer while retaining their event transport controls.
protocol CustomerStoreProviding: Sendable {
    func openCustomerStore(at directory: URL) async throws -> any CustomerStore
    func customerStore() async -> (any CustomerStore)?
    func customerDidCommit(_ records: [StableEventCaptureRecord], commits: [StableEventCaptureCommit]) async
}
