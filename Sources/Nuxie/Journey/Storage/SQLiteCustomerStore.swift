import Foundation
import SQLite3

private let customerTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private enum CustomerSQLValue {
    case text(String), integer(Int64), blob(Data), null
}

extension SQLiteEventStore: CustomerStore {
    private func customerQuery<T>(_ sql: String, _ values: [CustomerSQLValue] = [], body: (OpaquePointer?) throws -> T) throws -> T {
        try customerStatement(sql) { statement in
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch value {
                case let .text(text):
                    guard text.utf8.count <= Int(Int32.max) else { throw CustomerStoreError.invalidRow }
                    result = sqlite3_bind_text(statement, index, text, Int32(text.utf8.count), customerTransient)
                case let .integer(number): result = sqlite3_bind_int64(statement, index, number)
                case let .blob(data):
                    result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), customerTransient) }
                case .null: result = sqlite3_bind_null(statement, index)
                }
                guard result == SQLITE_OK else { throw CustomerStoreError.invalidRow }
            }
            return try body(statement)
        }
    }

    private func customerWrite(_ sql: String, _ values: [CustomerSQLValue] = []) throws {
        try customerQuery(sql, values) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else { throw CustomerStoreError.invalidRow }
        }
    }

    private func customerTransaction<T>(_ operation: () throws -> T) throws -> T {
        try customerExecute("BEGIN IMMEDIATE;")
        let startedAt = Date()
        do {
            let result = try operation()
            try customerExecute("COMMIT;")
            LogDebug("Customer store transaction committed in \(Date().timeIntervalSince(startedAt) * 1000) ms")
            return result
        } catch {
            try? customerExecute("ROLLBACK;")
            throw error
        }
    }

    private func ownerValues(_ owner: CustomerStoreOwner) -> [CustomerSQLValue] {
        [.text(owner.authorityScope), .text(owner.userId)]
    }

    private func journeyValues(_ key: CustomerJourneyKey) -> [CustomerSQLValue] {
        ownerValues(key.owner) + [.text(key.journeyId), .integer(key.legGeneration)]
    }

    private func rowText(_ statement: OpaquePointer?, _ index: Int32) throws -> String {
        guard let bytes = sqlite3_column_text(statement, index) else { throw CustomerStoreError.invalidRow }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
    }

    private func optionalInteger(_ statement: OpaquePointer?, _ index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
    }

    func customerMetadata() throws -> CustomerStoreMetadata {
        try customerQuery("SELECT state_version,next_capture_sequence,cutover_sequence,legacy_cleanup_pending FROM customer_store_metadata WHERE id=1;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw CustomerStoreError.invalidRow }
            return CustomerStoreMetadata(stateVersion: try rowText(statement, 0), nextCaptureSequence: sqlite3_column_int64(statement, 1),
                cutoverSequence: sqlite3_column_int64(statement, 2), legacyCleanupPending: sqlite3_column_int(statement, 3) != 0)
        }
    }

    func customerScope(owner: CustomerStoreOwner) throws -> CustomerScope? {
        try customerQuery("SELECT execution_epoch,execution_revoked,opened_state_version FROM customer_scopes WHERE authority_scope=? AND user_id=?;", ownerValues(owner)) { statement in
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw CustomerStoreError.invalidRow }
            return CustomerScope(owner: owner, executionEpoch: sqlite3_column_int64(statement, 0), executionRevoked: sqlite3_column_int(statement, 1) != 0,
                openedStateVersion: try rowText(statement, 2))
        }
    }

    func putCustomerScope(_ scope: CustomerScope) throws {
        guard scope.openedStateVersion == CustomerStoreSchema.stateVersion else {
            throw CustomerStoreError.unsupportedStateVersion(scope.openedStateVersion)
        }
        try customerWrite("""
        INSERT INTO customer_scopes VALUES(?,?,?,?,?) ON CONFLICT(authority_scope,user_id) DO UPDATE SET
        execution_epoch=excluded.execution_epoch, execution_revoked=excluded.execution_revoked, opened_state_version=excluded.opened_state_version
        WHERE excluded.execution_epoch >= customer_scopes.execution_epoch;
        """, ownerValues(scope.owner) + [.integer(scope.executionEpoch), .integer(scope.executionRevoked ? 1 : 0), .text(scope.openedStateVersion)])
    }

    func historyCoverage(owner: CustomerStoreOwner) throws -> Int64? {
        try customerQuery("SELECT coverage_start_ms FROM event_history_metadata WHERE scope=? AND user_id=?;", ownerValues(owner)) { statement in
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw CustomerStoreError.invalidRow }
            return sqlite3_column_int64(statement, 0)
        }
    }

    func advanceHistoryCoverage(owner: CustomerStoreOwner, to milliseconds: Int64) throws {
        try customerWrite("""
        INSERT INTO event_history_metadata VALUES(?,?,?) ON CONFLICT(scope,user_id) DO UPDATE SET
        coverage_start_ms=MAX(coverage_start_ms,excluded.coverage_start_ms);
        """, ownerValues(owner) + [.integer(milliseconds)])
    }

    private func ownsResponseSaveJourney(owner: CustomerStoreOwner, journeyId: String, experienceId: String, versionId: String) throws -> Bool {
        try customerQuery("""
        SELECT 1 FROM journeys WHERE authority_scope=? AND user_id=? AND journey_id=? AND experience_id=? AND version_id=? LIMIT 1;
        """, ownerValues(owner) + [.text(journeyId), .text(experienceId), .text(versionId)]) { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW || result == SQLITE_DONE else { throw CustomerStoreError.invalidRow }
            return result == SQLITE_ROW
        }
    }

    func putResponseSaveLane(owner: CustomerStoreOwner, journeyId: String, formName: String, lane: CustomerResponseSaveLane) throws {
        try customerTransaction {
            guard (0...JourneyResponseSave.maximumSequence).contains(lane.sequence) else { throw JourneyResponseSaveError.sequenceExhausted }
            if let pending = lane.pending {
                guard pending.distinctId.utf8.elementsEqual(owner.userId.utf8), pending.journeyId.utf8.elementsEqual(journeyId.utf8),
                      pending.formName.utf8.elementsEqual(formName.utf8), pending.experienceId.utf8.elementsEqual(lane.experienceId.utf8),
                      pending.experienceVersionId.utf8.elementsEqual(lane.versionId.utf8) else { throw JourneyResponseSaveError.wrongOwner }
            }
            // A retained lane can finish uploading after its Journey has ended.
            let existing = try responseSaveLane(owner: owner, journeyId: journeyId, formName: formName)
            if let existing {
                guard existing.experienceId.utf8.elementsEqual(lane.experienceId.utf8), lane.sequence >= existing.sequence else {
                    throw JourneyResponseSaveError.wrongOwner
                }
                if !existing.versionId.utf8.elementsEqual(lane.versionId.utf8) {
                    guard try ownsResponseSaveJourney(owner: owner, journeyId: journeyId, experienceId: lane.experienceId, versionId: lane.versionId) else {
                        throw JourneyResponseSaveError.wrongOwner
                    }
                }
            } else {
                guard try ownsResponseSaveJourney(owner: owner, journeyId: journeyId, experienceId: lane.experienceId, versionId: lane.versionId) else {
                    throw JourneyResponseSaveError.wrongOwner
                }
            }
            let answers: CustomerSQLValue
            if let pending = lane.pending { answers = .blob(try ExactJSONCodec.encode(pending.answers)) } else { answers = .null }
            let retry = lane.retry
            let display = lane.display
            try customerWrite("""
            INSERT INTO journey_response_saves VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(authority_scope,user_id,journey_id,form_name) DO UPDATE SET
            experience_id=excluded.experience_id,version_id=excluded.version_id,sequence=excluded.sequence,pending_sequence=excluded.pending_sequence,pending_answers_json=excluded.pending_answers_json,
            display_sequence=excluded.display_sequence,saving=excluded.saving,saved=excluded.saved,save_error=excluded.save_error,
            attempts=excluded.attempts,observed_at=excluded.observed_at,next_attempt_at=excluded.next_attempt_at,
            unknown_form_since=excluded.unknown_form_since,last_code=excluded.last_code;
            """, ownerValues(owner) + [.text(journeyId), .text(formName), .text(lane.experienceId), .text(lane.versionId), .integer(lane.sequence),
                lane.pending.map { .integer($0.sequence) } ?? .null, answers, display.map { .integer($0.sequence) } ?? .null,
                .integer(display?.saving == true ? 1 : 0), .integer(display?.saved == true ? 1 : 0), .text(display?.saveError ?? ""),
                .integer(retry?.attempts ?? 0), retry.map { .integer($0.observedAt) } ?? .null, retry.map { .integer($0.nextAttemptAt) } ?? .null,
                retry?.unknownFormSince.map { .integer($0) } ?? .null, retry.map { .text($0.lastCode.rawValue) } ?? .null])
        }
    }

    func responseSaveLane(owner: CustomerStoreOwner, journeyId: String, formName: String) throws -> CustomerResponseSaveLane? {
        try customerQuery("""
        SELECT experience_id,version_id,sequence,pending_sequence,pending_answers_json,display_sequence,saving,saved,save_error,
        attempts,observed_at,next_attempt_at,unknown_form_since,last_code FROM journey_response_saves
        WHERE authority_scope=? AND user_id=? AND journey_id=? AND form_name=?;
        """, ownerValues(owner) + [.text(journeyId), .text(formName)]) { statement in
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw CustomerStoreError.invalidRow }
            let experienceId = try rowText(statement, 0)
            let versionId = try rowText(statement, 1)
            let pending: JourneyResponseSave?
            if let sequence = optionalInteger(statement, 3) {
                guard let bytes = sqlite3_column_blob(statement, 4) else { throw CustomerStoreError.invalidRow }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 4)))
                pending = JourneyResponseSave(distinctId: owner.userId, journeyId: journeyId, experienceId: experienceId,
                    experienceVersionId: versionId, formName: formName, sequence: sequence,
                    answers: try ExactJSONCodec.decode(ExactJSONObject<JourneyReleaseJSONValue>.self, from: data))
            } else { pending = nil }
            let retry: CustomerResponseSaveRetry?
            if let observedAt = optionalInteger(statement, 10) {
                guard let nextAttemptAt = optionalInteger(statement, 11), let code = JourneyResponseSaveReply.Code(rawValue: try rowText(statement, 13)) else {
                    throw CustomerStoreError.invalidRow
                }
                retry = CustomerResponseSaveRetry(attempts: sqlite3_column_int64(statement, 9), observedAt: observedAt,
                    nextAttemptAt: nextAttemptAt, unknownFormSince: optionalInteger(statement, 12), lastCode: code)
            } else { retry = nil }
            let display: JourneyResponseSaveDisplay?
            if let sequence = optionalInteger(statement, 5) {
                display = JourneyResponseSaveDisplay(sequence: sequence, saving: sqlite3_column_int(statement, 6) != 0,
                    saved: sqlite3_column_int(statement, 7) != 0, saveError: try rowText(statement, 8))
            } else { display = nil }
            return CustomerResponseSaveLane(experienceId: experienceId, versionId: versionId, sequence: sqlite3_column_int64(statement, 2),
                pending: pending, retry: retry, display: display)
        }
    }

    func releasePins(for key: CustomerJourneyKey) throws -> [CustomerReleasePin] {
        try customerQuery("SELECT object_sha256,kind,relative_path,size_bytes FROM journey_release_pins WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=? ORDER BY object_sha256,kind;", journeyValues(key)) { statement in
            var result: [CustomerReleasePin] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return result }
                guard code == SQLITE_ROW, let kind = CustomerReleasePin.Kind(rawValue: try rowText(statement, 1)) else { throw CustomerStoreError.invalidRow }
                result.append(CustomerReleasePin(objectSHA256: try rowText(statement, 0), kind: kind, relativePath: try rowText(statement, 2), sizeBytes: sqlite3_column_int64(statement, 3)))
            }
        }
    }

    func replaceReleasePins(for key: CustomerJourneyKey, pins: [CustomerReleasePin]) throws {
        try customerTransaction {
            try customerWrite("DELETE FROM journey_release_pins WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=?;", journeyValues(key))
            for pin in pins {
                guard pin.relativePath == CustomerPinFileOwner.relativePath(owner: key.owner, sha256: pin.objectSHA256, kind: pin.kind),
                      JourneyReleasePinStore.isLowercaseSHA256(pin.objectSHA256) else { throw CustomerStoreError.wrongOwner }
                try customerWrite("INSERT INTO journey_release_pins VALUES(?,?,?,?,?,?,?,?);", journeyValues(key) + [.text(pin.objectSHA256), .text(pin.kind.rawValue), .text(pin.relativePath), .integer(pin.sizeBytes)])
            }
        }
    }

    func committedReleasePinPaths() throws -> Set<String> {
        try customerQuery("SELECT DISTINCT relative_path FROM journey_release_pins;") { statement in
            var paths: Set<String> = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return paths }
                guard result == SQLITE_ROW else { throw CustomerStoreError.invalidRow }
                paths.insert(try rowText(statement, 0))
            }
        }
    }

    /// Dormant until the atomic execution switch calls this before journal recovery.
    func openCustomerState(cutoverAt: Int64) throws -> CustomerStoreMetadata {
        try customerTransaction {
            let previous = try customerMetadata()
            if previous.stateVersion == CustomerStoreSchema.stateVersion { return previous }
            guard previous.stateVersion == "legacy" else { throw CustomerStoreError.unsupportedStateVersion(previous.stateVersion) }
            for table in ["journey_pending_work", "journey_event_applications", "journey_effects", "journey_response_saves",
                          "journey_arm_receipts", "journey_conversion_watches", "journey_frequency", "journeys", "journey_execution_snapshots", "customer_scopes"] {
                try customerExecute("DELETE FROM \(table);")
            }
            // The inbox proves authority only when its scope has an immutable binding.
            try customerExecute("""
            UPDATE events SET authority_scope=(SELECT i.scope FROM conversion_event_inbox i
              WHERE i.event_id=events.id AND i.user_id=events.user_id
              AND EXISTS(SELECT 1 FROM conversion_scope_bindings b WHERE b.authority_scope=i.scope))
              WHERE authority_scope IS NULL;
            UPDATE events SET scope=COALESCE(authority_scope,'legacy-unknown'), journey_plan_state='retired', measurement_state='done';
            """)
            try customerWrite("""
            INSERT INTO event_history_metadata(scope,user_id,coverage_start_ms)
            SELECT scope,user_id,
              CASE WHEN scope <> 'legacy-unknown'
                AND EXISTS(SELECT 1 FROM conversion_scope_bindings b WHERE b.authority_scope=events.authority_scope)
                THEN COALESCE((SELECT coverage_start_ms FROM event_history_metadata WHERE scope='legacy-global' AND user_id=''),?)
                ELSE ? END
            FROM events WHERE 1 GROUP BY scope,user_id
            ON CONFLICT(scope,user_id) DO UPDATE SET coverage_start_ms=MAX(coverage_start_ms,excluded.coverage_start_ms);
            """, [.integer(cutoverAt), .integer(cutoverAt)])
            try customerExecute("DROP TABLE conversion_event_inbox;")
            try customerWrite("UPDATE customer_store_metadata SET state_version=?,cutover_sequence=next_capture_sequence-1,legacy_cleanup_pending=1 WHERE id=1;", [.text(CustomerStoreSchema.stateVersion)])
            return try customerMetadata()
        }
    }

    func finishLegacyCleanup(cutoverSequence: Int64) throws {
        try customerWrite("UPDATE customer_store_metadata SET legacy_cleanup_pending=0 WHERE id=1 AND state_version=? AND cutover_sequence=?;",
            [.text(CustomerStoreSchema.stateVersion), .integer(cutoverSequence)])
    }
}
