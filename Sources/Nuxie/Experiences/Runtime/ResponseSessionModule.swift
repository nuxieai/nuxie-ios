#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import CryptoKit
import Foundation

enum ResponseSessionFieldType: String, Sendable {
    case text
    case number
    case boolean
    case enumeration = "enum"
    case multiEnumeration = "multi_enum"
    case date
}

struct ResponseSessionField: Sendable, Equatable {
    let key: String
    let type: ResponseSessionFieldType
    let required: Bool
    let options: [String]?
    let minimum: Double?
    let maximum: Double?
}

struct PinnedResponseSessionSchema: Sendable, Equatable {
    let key: String
    let versionId: String
    let version: UInt64
    let fields: [ResponseSessionField]
    let capturesByScreen: [String: Set<String>]
}

struct ResponseSessionRunAuthority: Sendable {
    let journeyId: String
    let executionOwnershipEpoch: UInt64
    let lifecycleGeneration: UInt64
    let schema: PinnedResponseSessionSchema?
}

enum ResponseSessionState: String, Codable, Equatable, Sendable {
    case draft
    case submitted
    case abandoned
}

extension ScreenEmissionValue {
    var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.foundationValue)
        case .object(let values): values.mapValues(\.foundationValue)
        }
    }
}

struct ResponseSessionSnapshot: Codable, Equatable, Sendable {
    let responseId: String
    let journeyId: String
    let responseSchemaKey: String
    let responseSchemaVersionId: String
    let schemaVersion: UInt64
    let state: ResponseSessionState
    let values: [String: ScreenEmissionValue]
    let version: UInt64
    let createdAt: String
    let updatedAt: String
    let submittedAt: String?
    let abandonedAt: String?
}

struct ResponseSessionProjection: Equatable, Sendable {
    let journeyId: String
    let responseSchemaVersionId: String
    let sessionVersion: UInt64?
    let state: ResponseSessionState?
    let values: [String: ScreenEmissionValue]
}

enum ResponseSessionDiagnostic: String, Codable, Equatable, Sendable {
    case schemaMissing
    case fieldMissing
    case fieldNotCaptured
    case valueInvalid
    case terminal
    case requiredMissing
    case snapshotConflict
}

enum ResponseSessionOperationStatus: String, Codable, Equatable, Sendable {
    case changed
    case unchanged
    case submitted
    case alreadySubmitted
    case abandoned
}

enum ResponseSessionOperationResult: Codable, Equatable, Sendable {
    case accepted(status: ResponseSessionOperationStatus, snapshot: ResponseSessionSnapshot?)
    case rejected(diagnostic: ResponseSessionDiagnostic, snapshot: ResponseSessionSnapshot?)

    var snapshot: ResponseSessionSnapshot? {
        switch self {
        case .accepted(_, let snapshot), .rejected(_, let snapshot): snapshot
        }
    }

    private enum CodingKeys: String, CodingKey { case accepted, status, rejected, diagnostic, snapshot }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.accepted) {
            self = .accepted(
                status: try container.decode(ResponseSessionOperationStatus.self, forKey: .status),
                snapshot: try container.decodeIfPresent(ResponseSessionSnapshot.self, forKey: .snapshot)
            )
        } else {
            self = .rejected(
                diagnostic: try container.decode(ResponseSessionDiagnostic.self, forKey: .diagnostic),
                snapshot: try container.decodeIfPresent(ResponseSessionSnapshot.self, forKey: .snapshot)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .accepted(let status, let snapshot):
            try container.encode(true, forKey: .accepted)
            try container.encode(status, forKey: .status)
            try container.encodeIfPresent(snapshot, forKey: .snapshot)
        case .rejected(let diagnostic, let snapshot):
            try container.encode(diagnostic, forKey: .rejected)
            try container.encode(diagnostic, forKey: .diagnostic)
            try container.encodeIfPresent(snapshot, forKey: .snapshot)
        }
    }
}

enum ResponseSessionSynchronizationItem: Equatable, Sendable {
    case snapshot(
        id: String,
        response: ResponseSessionSnapshot,
        executionOwnershipEpoch: UInt64,
        lifecycleGeneration: UInt64,
        terminalTransitionId: String?
    )
    case terminalNoSession(
        id: String,
        journeyId: String,
        responseId: String,
        executionOwnershipEpoch: UInt64,
        lifecycleGeneration: UInt64,
        terminalTransitionId: String
    )
}

struct ResponseSessionTransactionDecision: Sendable {
    let result: ResponseSessionOperationResult
    let next: ResponseSessionSnapshot?
    let synchronization: ResponseSessionSynchronizationItem?
}

protocol ResponseSessionStore: Sendable {
    func load(journeyId: String) async -> ResponseSessionSnapshot?
    /// The operation receipt, session snapshot, and optional synchronization
    /// item commit or roll back together. Replays return the stored result.
    func transact(
        journeyId: String,
        operationId: String,
        decide: @Sendable (ResponseSessionSnapshot?) throws -> ResponseSessionTransactionDecision
    ) async throws -> ResponseSessionOperationResult
}

actor InMemoryResponseSessionStore: ResponseSessionStore {
    private var sessions: [String: ResponseSessionSnapshot] = [:]
    private var receipts: [String: ResponseSessionOperationResult] = [:]
    private var synchronization: [ResponseSessionSynchronizationItem] = []

    func load(journeyId: String) -> ResponseSessionSnapshot? { sessions[journeyId] }

    func transact(
        journeyId: String,
        operationId: String,
        decide: @Sendable (ResponseSessionSnapshot?) throws -> ResponseSessionTransactionDecision
    ) throws -> ResponseSessionOperationResult {
        let receiptKey = "\(journeyId):\(operationId)"
        if let receipt = receipts[receiptKey] { return receipt }
        let decision = try decide(sessions[journeyId])
        if let next = decision.next { sessions[journeyId] = next }
        if let item = decision.synchronization { synchronization.append(item) }
        receipts[receiptKey] = decision.result
        return decision.result
    }

    func synchronizationItems() -> [ResponseSessionSynchronizationItem] {
        synchronization
    }
}

/// Durable response-session storage owned by the journey persistence boundary.
/// The journey snapshot and operation receipt are committed together, so a
/// relaunch cannot replay an operation against an older projection.
actor JourneyResponseSessionStore: ResponseSessionStore {
    private let journey: Journey
    private let journeyStore: any JourneyStoreProtocol

    init(journey: Journey, journeyStore: any JourneyStoreProtocol) {
        self.journey = journey
        self.journeyStore = journeyStore
    }

    func load(journeyId: String) async -> ResponseSessionSnapshot? {
        guard journeyId == journey.id else { return nil }
        return await journey.snapshot().responseSession
    }

    func transact(
        journeyId: String,
        operationId: String,
        decide: @Sendable (ResponseSessionSnapshot?) throws -> ResponseSessionTransactionDecision
    ) async throws -> ResponseSessionOperationResult {
        guard journeyId == journey.id else {
            throw ResponseSessionModuleError.snapshotAuthorityMismatch
        }
        let state = await journey.snapshot()
        if let receipt = state.responseSessionReceipts[operationId] {
            return receipt
        }
        let decision = try decide(state.responseSession)
        let committed = await journey.update { current -> JourneySnapshot? in
            guard current.responseSession == state.responseSession,
                  current.responseSessionReceipts[operationId] == nil else {
                return nil
            }
            current.responseSession = decision.next
            current.responseSessionReceipts[operationId] = decision.result
            current.updatedAt = Date()
            return current
        }
        guard let committed else {
            throw ResponseSessionModuleError.snapshotAuthorityMismatch
        }
        do {
            try journeyStore.saveJourney(committed)
        } catch {
            let persisted = journeyStore.loadJourney(id: journey.id)
            if persisted?.responseSessionReceipts[operationId] != decision.result {
                _ = await journey.update { current in
                    guard current.responseSession == committed.responseSession,
                          current.responseSessionReceipts[operationId] == decision.result else { return }
                    current.responseSession = state.responseSession
                    current.responseSessionReceipts.removeValue(forKey: operationId)
                }
            }
            throw error
        }
        return decision.result
    }
}

func deriveResponseSessionId(journeyId: String) throws -> String {
    let journey = Data(journeyId.utf8)
    guard let length = UInt32(exactly: journey.count) else {
        throw ResponseSessionModuleError.journeyIdTooLong
    }
    var bigEndianLength = length.bigEndian
    var input = Data("nuxie.response.v2".utf8)
    input.append(0)
    withUnsafeBytes(of: &bigEndianLength) { input.append(contentsOf: $0) }
    input.append(journey)
    return "rsp_" + SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
}

enum ResponseSessionModuleError: Error, Equatable {
    case journeyIdTooLong
    case invalidTimestamp
    case runNotPinned
    case runAuthorityMismatch
    case schemaMissing
    case snapshotAuthorityMismatch
}

actor ResponseSessionModule {
    typealias Observer = @Sendable (ResponseSessionProjection) -> Void

    private enum MutationValidation {
        case accepted(ResponseSessionField)
        case rejected(ResponseSessionTransactionDecision)
    }

    private let store: any ResponseSessionStore
    private var runs: [String: ResponseSessionRunAuthority] = [:]
    private var snapshots: [String: ResponseSessionSnapshot?] = [:]
    private var projections: [String: ResponseSessionProjection] = [:]
    private var observers: [String: [UUID: Observer]] = [:]

    init(store: any ResponseSessionStore) {
        self.store = store
    }

    func pinRun(_ run: ResponseSessionRunAuthority) async throws -> ResponseSessionProjection {
        guard run.schema != nil else { throw ResponseSessionModuleError.schemaMissing }
        if let existing = runs[run.journeyId],
           existing.executionOwnershipEpoch != run.executionOwnershipEpoch ||
           existing.lifecycleGeneration != run.lifecycleGeneration ||
           existing.schema != run.schema {
            throw ResponseSessionModuleError.runAuthorityMismatch
        }
        let snapshot = await store.load(journeyId: run.journeyId)
        try Self.validate(snapshot: snapshot, for: run)
        runs[run.journeyId] = run
        snapshots[run.journeyId] = snapshot
        return publish(run: run, session: snapshot)
    }

    func snapshot(journeyId: String) throws -> ResponseSessionSnapshot? {
        guard runs[journeyId] != nil else { throw ResponseSessionModuleError.runNotPinned }
        return snapshots[journeyId] ?? nil
    }

    /// Reconciles an authoritative server record into the same durable store
    /// used by local mutations. This is the recovery path when the network
    /// accepted a write but a local CAS or schema check raced with it.
    func reconcile(
        run: ResponseSessionRunAuthority,
        operationId: String,
        snapshot: ResponseSessionSnapshot
    ) async throws -> ResponseSessionOperationResult {
        try assertPinned(run)
        try Self.validate(snapshot: snapshot, for: run)
        return try await transact(run: run, operationId: operationId) { current in
            let next = current.map { max($0.version + 1, snapshot.version) } ?? snapshot.version
            let authoritative = ResponseSessionSnapshot(
                responseId: snapshot.responseId,
                journeyId: snapshot.journeyId,
                responseSchemaKey: snapshot.responseSchemaKey,
                responseSchemaVersionId: snapshot.responseSchemaVersionId,
                schemaVersion: snapshot.schemaVersion,
                state: snapshot.state,
                values: snapshot.values,
                version: next,
                createdAt: snapshot.createdAt,
                updatedAt: snapshot.updatedAt,
                submittedAt: snapshot.submittedAt,
                abandonedAt: snapshot.abandonedAt
            )
            return ResponseSessionTransactionDecision(
                result: .accepted(status: .changed, snapshot: authoritative),
                next: authoritative,
                synchronization: Self.synchronization(run: run, snapshot: authoritative)
            )
        }
    }

    /// Records a server-accepted submission when the submit endpoint does not
    /// return a response payload. The local projection remains authoritative
    /// for the captured values, but its lifecycle state is advanced to the
    /// terminal submitted state so a later dismissal cannot abandon it.
    func reconcileSubmission(
        run: ResponseSessionRunAuthority,
        operationId: String,
        occurredAt: String
    ) async throws -> ResponseSessionOperationResult {
        try assertPinned(run)
        try validateTimestamp(occurredAt)
        guard let schema = run.schema else {
            throw ResponseSessionModuleError.schemaMissing
        }
        let responseId = try deriveResponseSessionId(journeyId: run.journeyId)
        return try await transact(run: run, operationId: operationId) { current in
            let base = current ?? ResponseSessionSnapshot(
                responseId: responseId,
                journeyId: run.journeyId,
                responseSchemaKey: schema.key,
                responseSchemaVersionId: schema.versionId,
                schemaVersion: schema.version,
                state: .draft,
                values: [:],
                version: 0,
                createdAt: occurredAt,
                updatedAt: occurredAt,
                submittedAt: nil,
                abandonedAt: nil
            )
            let submitted = ResponseSessionSnapshot(
                responseId: base.responseId,
                journeyId: base.journeyId,
                responseSchemaKey: base.responseSchemaKey,
                responseSchemaVersionId: base.responseSchemaVersionId,
                schemaVersion: base.schemaVersion,
                state: .submitted,
                values: base.values,
                version: base.version + 1,
                createdAt: base.createdAt,
                updatedAt: occurredAt,
                submittedAt: occurredAt,
                abandonedAt: nil
            )
            return ResponseSessionTransactionDecision(
                result: .accepted(status: .submitted, snapshot: submitted),
                next: submitted,
                synchronization: Self.synchronization(run: run, snapshot: submitted)
            )
        }
    }

    /// Records that the server accepted a field write when it omitted the
    /// resulting response record. The mutation was already durably applied by
    /// this module, so this receipt only makes the acknowledgement replay-safe
    /// without inventing a new version or changing the draft lifecycle.
    func acknowledgeWrite(
        run: ResponseSessionRunAuthority,
        operationId: String
    ) async throws -> ResponseSessionOperationResult {
        try assertPinned(run)
        return try await transact(run: run, operationId: operationId) { current in
            guard let current else {
                throw ResponseSessionModuleError.schemaMissing
            }
            return ResponseSessionTransactionDecision(
                result: .accepted(status: .unchanged, snapshot: current),
                next: current,
                synchronization: nil
            )
        }
    }

    func current(journeyId: String) throws -> ResponseSessionProjection {
        guard let projection = projections[journeyId] else {
            throw ResponseSessionModuleError.runNotPinned
        }
        return projection
    }

    func subscribe(journeyId: String, observer: @escaping Observer) throws -> UUID {
        let projection = try current(journeyId: journeyId)
        let id = UUID()
        observers[journeyId, default: [:]][id] = observer
        observer(projection)
        return id
    }

    func unsubscribe(journeyId: String, id: UUID) {
        observers[journeyId]?.removeValue(forKey: id)
    }

    func set(
        run: ResponseSessionRunAuthority,
        emissionId: String,
        screenId: String,
        field fieldKey: String,
        value: ScreenEmissionValue,
        occurredAt: String
    ) async throws -> ResponseSessionOperationResult {
        try validateTimestamp(occurredAt)
        return try await transact(run: run, operationId: emissionId) { current in
            switch Self.validateMutation(
                run: run,
                current: current,
                screenId: screenId,
                fieldKey: fieldKey
            ) {
            case .rejected(let decision): return decision
            case .accepted(let field):
                guard let normalized = Self.normalize(value, for: field) else {
                    return Self.reject(.valueInvalid, current)
                }
                if current?.values[fieldKey] == normalized {
                    return ResponseSessionTransactionDecision(
                        result: .accepted(status: .unchanged, snapshot: current),
                        next: current,
                        synchronization: nil
                    )
                }
                let next: ResponseSessionSnapshot
                if let current {
                    var values = current.values
                    values[fieldKey] = normalized
                    next = Self.update(
                        current,
                        values: values,
                        state: .draft,
                        occurredAt: occurredAt
                    )
                } else {
                    next = try Self.create(
                        run: run,
                        values: [fieldKey: normalized],
                        state: .draft,
                        occurredAt: occurredAt
                    )
                }
                return Self.changed(run: run, next: next)
            }
        }
    }

    func unset(
        run: ResponseSessionRunAuthority,
        emissionId: String,
        screenId: String,
        field fieldKey: String,
        occurredAt: String
    ) async throws -> ResponseSessionOperationResult {
        try validateTimestamp(occurredAt)
        return try await transact(run: run, operationId: emissionId) { current in
            switch Self.validateMutation(
                run: run,
                current: current,
                screenId: screenId,
                fieldKey: fieldKey
            ) {
            case .rejected(let decision): return decision
            case .accepted:
                guard let current, current.values[fieldKey] != nil else {
                    return ResponseSessionTransactionDecision(
                        result: .accepted(status: .unchanged, snapshot: current),
                        next: current,
                        synchronization: nil
                    )
                }
                var values = current.values
                values.removeValue(forKey: fieldKey)
                return Self.changed(
                    run: run,
                    next: Self.update(
                        current,
                        values: values,
                        state: .draft,
                        occurredAt: occurredAt
                    )
                )
            }
        }
    }

    func submit(
        run: ResponseSessionRunAuthority,
        operationId: String,
        expectedVersion: UInt64?,
        occurredAt: String
    ) async throws -> ResponseSessionOperationResult {
        try validateTimestamp(occurredAt)
        return try await transact(run: run, operationId: operationId) { current in
            guard let schema = run.schema else { return Self.reject(.schemaMissing, current) }
            if current?.state == .submitted {
                return ResponseSessionTransactionDecision(
                    result: .accepted(status: .alreadySubmitted, snapshot: current),
                    next: current,
                    synchronization: nil
                )
            }
            if current?.state == .abandoned { return Self.reject(.terminal, current) }
            guard current?.version == expectedVersion else {
                return Self.reject(.snapshotConflict, current)
            }
            let values = current?.values ?? [:]
            guard !schema.fields.contains(where: { $0.required && values[$0.key] == nil }) else {
                return Self.reject(.requiredMissing, current)
            }
            let next: ResponseSessionSnapshot
            if let current {
                next = Self.update(
                    current,
                    values: current.values,
                    state: .submitted,
                    occurredAt: occurredAt
                )
            } else {
                next = try Self.create(
                    run: run,
                    values: [:],
                    state: .submitted,
                    occurredAt: occurredAt
                )
            }
            return ResponseSessionTransactionDecision(
                result: .accepted(status: .submitted, snapshot: next),
                next: next,
                synchronization: Self.synchronization(run: run, snapshot: next)
            )
        }
    }

    func abandon(
        run: ResponseSessionRunAuthority,
        terminalTransitionId: String,
        occurredAt: String
    ) async throws -> ResponseSessionOperationResult {
        try validateTimestamp(occurredAt)
        return try await transact(run: run, operationId: terminalTransitionId) { current in
            guard let current else {
                let responseId = try deriveResponseSessionId(journeyId: run.journeyId)
                return ResponseSessionTransactionDecision(
                    result: .accepted(status: .unchanged, snapshot: nil),
                    next: nil,
                    synchronization: .terminalNoSession(
                        id: "\(responseId):terminal:\(terminalTransitionId)",
                        journeyId: run.journeyId,
                        responseId: responseId,
                        executionOwnershipEpoch: run.executionOwnershipEpoch,
                        lifecycleGeneration: run.lifecycleGeneration,
                        terminalTransitionId: terminalTransitionId
                    )
                )
            }
            if current.state == .submitted {
                return ResponseSessionTransactionDecision(
                    result: .accepted(status: .unchanged, snapshot: current),
                    next: current,
                    synchronization: nil
                )
            }
            if current.state == .abandoned {
                return ResponseSessionTransactionDecision(
                    result: .accepted(status: .abandoned, snapshot: current),
                    next: current,
                    synchronization: nil
                )
            }
            let next = Self.update(
                current,
                values: current.values,
                state: .abandoned,
                occurredAt: occurredAt
            )
            return ResponseSessionTransactionDecision(
                result: .accepted(status: .abandoned, snapshot: next),
                next: next,
                synchronization: Self.synchronization(
                    run: run,
                    snapshot: next,
                    terminalTransitionId: terminalTransitionId
                )
            )
        }
    }

    private func transact(
        run: ResponseSessionRunAuthority,
        operationId: String,
        decide: @escaping @Sendable (
            ResponseSessionSnapshot?
        ) throws -> ResponseSessionTransactionDecision
    ) async throws -> ResponseSessionOperationResult {
        try assertPinned(run)
        let result = try await store.transact(
            journeyId: run.journeyId,
            operationId: operationId,
            decide: decide
        )
        if let snapshot = result.snapshot,
           projections[run.journeyId]?.sessionVersion != snapshot.version {
            snapshots[run.journeyId] = snapshot
            _ = publish(run: run, session: snapshot)
        } else if result.snapshot == nil {
            snapshots[run.journeyId] = nil
        }
        return result
    }

    private func assertPinned(_ run: ResponseSessionRunAuthority) throws {
        guard let pinned = runs[run.journeyId] else {
            throw ResponseSessionModuleError.runNotPinned
        }
        guard pinned.executionOwnershipEpoch == run.executionOwnershipEpoch,
              pinned.lifecycleGeneration == run.lifecycleGeneration,
              pinned.schema == run.schema else {
            throw ResponseSessionModuleError.runAuthorityMismatch
        }
    }

    @discardableResult
    private func publish(
        run: ResponseSessionRunAuthority,
        session: ResponseSessionSnapshot?
    ) -> ResponseSessionProjection {
        let projection = Self.projection(run: run, session: session)
        projections[run.journeyId] = projection
        observers[run.journeyId]?.values.forEach { $0(projection) }
        return projection
    }

    private func validateTimestamp(_ value: String) throws {
        let explicitOffset = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"#
        guard value.range(of: explicitOffset, options: .regularExpression) != nil,
              Self.parseISO8601(value) != nil else {
            throw ResponseSessionModuleError.invalidTimestamp
        }
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func validate(
        snapshot: ResponseSessionSnapshot?,
        for run: ResponseSessionRunAuthority
    ) throws {
        guard let snapshot else { return }
        guard let schema = run.schema,
              snapshot.responseId == (try deriveResponseSessionId(journeyId: run.journeyId)),
              snapshot.journeyId == run.journeyId,
              snapshot.responseSchemaKey == schema.key,
              snapshot.responseSchemaVersionId == schema.versionId,
              snapshot.schemaVersion == schema.version,
              snapshot.values.allSatisfy({ key, value in
                  guard let field = schema.fields.first(where: { $0.key == key }) else {
                      return false
                  }
                  return normalize(value, for: field) == value
              }),
              Self.terminalTimestampsMatch(snapshot) else {
            throw ResponseSessionModuleError.snapshotAuthorityMismatch
        }
    }

    private static func terminalTimestampsMatch(_ snapshot: ResponseSessionSnapshot) -> Bool {
        switch snapshot.state {
        case .draft:
            return snapshot.submittedAt == nil && snapshot.abandonedAt == nil
        case .submitted:
            return snapshot.submittedAt != nil && snapshot.abandonedAt == nil
        case .abandoned:
            return snapshot.submittedAt == nil && snapshot.abandonedAt != nil
        }
    }

    private static func validateMutation(
        run: ResponseSessionRunAuthority,
        current: ResponseSessionSnapshot?,
        screenId: String,
        fieldKey: String
    ) -> MutationValidation {
        guard let schema = run.schema else { return .rejected(reject(.schemaMissing, current)) }
        guard let field = schema.fields.first(where: { $0.key == fieldKey }) else {
            return .rejected(reject(.fieldMissing, current))
        }
        guard schema.capturesByScreen[screenId]?.contains(fieldKey) == true else {
            return .rejected(reject(.fieldNotCaptured, current))
        }
        guard current == nil || current?.state == .draft else {
            return .rejected(reject(.terminal, current))
        }
        return .accepted(field)
    }

    private static func normalize(
        _ value: ScreenEmissionValue,
        for field: ResponseSessionField
    ) -> ScreenEmissionValue? {
        switch (field.type, value) {
        case (.text, .string), (.date, .string), (.boolean, .bool): return value
        case (.number, .number(let number)):
            guard number.isFinite,
                  field.minimum.map({ number >= $0 }) ?? true,
                  field.maximum.map({ number <= $0 }) ?? true else { return nil }
            return value
        case (.enumeration, .string(let selected)):
            return field.options?.contains(selected) == true ? value : nil
        case (.multiEnumeration, .array(let raw)):
            let selected = Set(raw.compactMap { item -> String? in
                guard case .string(let value) = item else { return nil }
                return value
            })
            guard selected.count == raw.count || raw.allSatisfy({
                if case .string = $0 { return true }
                return false
            }), let options = field.options, selected.isSubset(of: Set(options)) else {
                return nil
            }
            return .array(options.filter(selected.contains).map(ScreenEmissionValue.string))
        default: return nil
        }
    }

    private static func projection(
        run: ResponseSessionRunAuthority,
        session: ResponseSessionSnapshot?
    ) -> ResponseSessionProjection {
        let schema = run.schema!
        return ResponseSessionProjection(
            journeyId: run.journeyId,
            responseSchemaVersionId: schema.versionId,
            sessionVersion: session?.version,
            state: session?.state,
            values: Dictionary(uniqueKeysWithValues: schema.fields.map {
                ($0.key, session?.values[$0.key] ?? .null)
            })
        )
    }

    private static func create(
        run: ResponseSessionRunAuthority,
        values: [String: ScreenEmissionValue],
        state: ResponseSessionState,
        occurredAt: String
    ) throws -> ResponseSessionSnapshot {
        guard let schema = run.schema else { throw ResponseSessionModuleError.schemaMissing }
        return ResponseSessionSnapshot(
            responseId: try deriveResponseSessionId(journeyId: run.journeyId),
            journeyId: run.journeyId,
            responseSchemaKey: schema.key,
            responseSchemaVersionId: schema.versionId,
            schemaVersion: schema.version,
            state: state,
            values: values,
            version: 1,
            createdAt: occurredAt,
            updatedAt: occurredAt,
            submittedAt: state == .submitted ? occurredAt : nil,
            abandonedAt: state == .abandoned ? occurredAt : nil
        )
    }

    private static func update(
        _ current: ResponseSessionSnapshot,
        values: [String: ScreenEmissionValue],
        state: ResponseSessionState,
        occurredAt: String
    ) -> ResponseSessionSnapshot {
        ResponseSessionSnapshot(
            responseId: current.responseId,
            journeyId: current.journeyId,
            responseSchemaKey: current.responseSchemaKey,
            responseSchemaVersionId: current.responseSchemaVersionId,
            schemaVersion: current.schemaVersion,
            state: state,
            values: values,
            version: current.version + 1,
            createdAt: current.createdAt,
            updatedAt: occurredAt,
            submittedAt: state == .submitted ? occurredAt : current.submittedAt,
            abandonedAt: state == .abandoned ? occurredAt : current.abandonedAt
        )
    }

    private static func synchronization(
        run: ResponseSessionRunAuthority,
        snapshot: ResponseSessionSnapshot,
        terminalTransitionId: String? = nil
    ) -> ResponseSessionSynchronizationItem {
        .snapshot(
            id: "\(snapshot.responseId):v\(snapshot.version)",
            response: snapshot,
            executionOwnershipEpoch: run.executionOwnershipEpoch,
            lifecycleGeneration: run.lifecycleGeneration,
            terminalTransitionId: terminalTransitionId
        )
    }

    private static func changed(
        run: ResponseSessionRunAuthority,
        next: ResponseSessionSnapshot
    ) -> ResponseSessionTransactionDecision {
        ResponseSessionTransactionDecision(
            result: .accepted(status: .changed, snapshot: next),
            next: next,
            synchronization: synchronization(run: run, snapshot: next)
        )
    }

    private static func reject(
        _ diagnostic: ResponseSessionDiagnostic,
        _ current: ResponseSessionSnapshot?
    ) -> ResponseSessionTransactionDecision {
        ResponseSessionTransactionDecision(
            result: .rejected(diagnostic: diagnostic, snapshot: current),
            next: current,
            synchronization: nil
        )
    }
}
#endif
