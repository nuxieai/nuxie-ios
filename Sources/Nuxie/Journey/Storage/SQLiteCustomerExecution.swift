import Foundation
import SQLite3

extension SQLiteEventStore {
    func customerBlob(_ statement: OpaquePointer?, _ index: Int32) throws -> Data {
        guard let bytes = sqlite3_column_blob(statement, index) else { throw CustomerStoreError.invalidRow }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    func customerJSON<T: Decodable>(_ type: T.Type, _ statement: OpaquePointer?, _ index: Int32) throws -> T {
        try ExactJSONCodec.decode(type, from: customerBlob(statement, index))
    }

    func customerExists(_ sql: String, _ values: [CustomerSQLValue]) throws -> Bool {
        try customerQuery(sql, values) { statement in
            let code = sqlite3_step(statement)
            guard code == SQLITE_ROW || code == SQLITE_DONE else { throw CustomerStoreError.invalidRow }
            return code == SQLITE_ROW
        }
    }

    func customerFrequency(owner: CustomerStoreOwner, experienceId: String) throws -> Int64? {
        try customerQuery("SELECT last_started_at FROM journey_frequency WHERE authority_scope=? AND user_id=? AND experience_id=?;",
            ownerValues(owner) + [.text(experienceId)]) { statement in
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return nil }
            guard code == SQLITE_ROW else { throw CustomerStoreError.invalidRow }
            return sqlite3_column_int64(statement, 0)
        }
    }

    func customerArmReceipts(owner: CustomerStoreOwner) throws -> Set<JourneyStateArmReceipt> {
        try customerQuery("SELECT reference_json,binding_json,entry_kind FROM journey_arm_receipts WHERE authority_scope=? AND user_id=? AND state='consumed';", ownerValues(owner)) { statement in
            var receipts = Set<JourneyStateArmReceipt>()
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return receipts }
                guard code == SQLITE_ROW, let kind = JourneyEntryCondition.Kind(rawValue: try rowText(statement, 2)) else { throw CustomerStoreError.invalidRow }
                receipts.insert(.init(reference: try customerJSON(ArmedJourney.Reference.self, statement, 0),
                    binding: try customerJSON(ArmedJourney.Binding.self, statement, 1), entryKind: kind))
            }
        }
    }

    func activeJourneys(owner: CustomerStoreOwner) throws -> [JourneyRun] {
        let journeys: [JourneyRun] = try customerQuery("""
        SELECT j.journey_id,j.leg_generation,j.experience_id,j.version_id,j.leg_id,j.descriptor_sha256,
          j.frequency_json,j.started_at,j.is_enrollment,j.started_event_id,j.completed_event_id,j.step_id,
          j.cursor_revision,j.context_json,j.outputs_json,j.native_snapshot_json,j.authored_close_outcome,
          s.delivery_json,s.assignments_json,s.customer_json,c.input_event_id,c.evaluation_at,c.initial_lag_ms,
          c.last_consumed_at,c.last_consumed_event_id,w.started_at,w.deadline_at,j.status,o.execution_epoch,
          (SELECT next_attempt_at FROM journey_pending_work p WHERE p.authority_scope=j.authority_scope AND p.user_id=j.user_id AND p.work_key='presentation:'||j.journey_id||':'||j.leg_generation)
        FROM journeys j JOIN journey_execution_snapshots s
          ON s.authority_scope=j.authority_scope AND s.user_id=j.user_id AND s.snapshot_id=j.snapshot_id
        JOIN customer_scopes o ON o.authority_scope=j.authority_scope AND o.user_id=j.user_id
        JOIN journey_cursors c ON c.authority_scope=j.authority_scope AND c.user_id=j.user_id AND c.journey_id=j.journey_id AND c.leg_generation=j.leg_generation
        LEFT JOIN journey_waits w ON w.authority_scope=j.authority_scope AND w.user_id=j.user_id AND w.journey_id=j.journey_id AND w.leg_generation=j.leg_generation
        WHERE j.authority_scope=? AND j.user_id=? ORDER BY j.started_event_id;
        """, ownerValues(owner)) { statement in
            var journeys: [JourneyRun] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return journeys }
                guard code == SQLITE_ROW else { throw CustomerStoreError.invalidRow }
                var journey = JourneyRun(journeyId: try rowText(statement, 0), generation: Int(sqlite3_column_int64(statement, 1)),
                    reference: .init(experienceId: try rowText(statement, 2), versionId: try rowText(statement, 3), legId: try rowText(statement, 4), descriptorSha256: try rowText(statement, 5)),
                    executionSnapshot: .init(delivery: try customerJSON(JourneyReleaseDelivery.self, statement, 17),
                        assignments: try customerJSON(ExactJSONObject<JourneyFactTable.Assignment?>.self, statement, 18),
                        customer: try customerJSON(ExactJSONObject<JourneyReleaseJSONValue>.self, statement, 19)),
                    artifactSHA256s: [], reentry: try customerJSON(Journey.Frequency.self, statement, 6),
                    startedAt: JourneyTime.date(sqlite3_column_int64(statement, 7)), isEnrollment: sqlite3_column_int(statement, 8) != 0,
                    startedEventId: try rowText(statement, 9), completedEventId: try rowText(statement, 10), stepId: try rowText(statement, 11),
                    context: try customerJSON(ArmedJourney.Context.self, statement, 13))
                journey.executionStatus = try rowText(statement, 27)
                journey.cursorRevision = sqlite3_column_int64(statement, 12)
                journey.executionEpoch = sqlite3_column_int64(statement, 28)
                journey.outputs = try customerJSON(ArmedJourney.Context.self, statement, 14)
                if sqlite3_column_type(statement, 15) != SQLITE_NULL { journey.nativeSnapshot = try customerJSON(ExperienceRunSnapshot.self, statement, 15) }
                if sqlite3_column_type(statement, 16) != SQLITE_NULL { journey.authoredCloseOutcome = try rowText(statement, 16) }
                if sqlite3_column_type(statement, 20) != SQLITE_NULL { journey.inputEventId = try rowText(statement, 20) }
                journey.evaluationAt = optionalInteger(statement, 21)
                journey.initialLagMillis = optionalInteger(statement, 22)
                if let time = optionalInteger(statement, 23) { journey.lastConsumed = .init(milliseconds: time, eventId: try rowText(statement, 24)) }
                if let anchor = optionalInteger(statement, 25) {
                    journey.park = .init(wakeAt: optionalInteger(statement, 26).map(JourneyTime.date), anchorAt: JourneyTime.date(anchor))
                } else if try rowText(statement, 27) == "awaiting_presentation" {
                    journey.park = .init(wakeAt: JourneyTime.date(optionalInteger(statement, 29) ?? Int64(JourneyConversionWatch.millis(journey.startedAt))))
                }
                journeys.append(journey)
            }
        }
        return try journeys.map { input in
            var journey = input
            let key = CustomerJourneyKey(owner: owner, journeyId: journey.journeyId, legGeneration: Int64(journey.generation))
            journey.artifactSHA256s = try releasePins(for: key).filter { $0.kind == .artifact }.map(\.objectSHA256).sorted()
            try customerQuery("SELECT step_id,effect_id,state,context_json,placement_id,result_event_id FROM journey_effects WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=? AND state IN ('claimed','awaiting_result');", journeyValues(key)) { statement in
                while true {
                    let code = sqlite3_step(statement)
                    if code == SQLITE_DONE { break }
                    guard code == SQLITE_ROW else { throw CustomerStoreError.invalidRow }
                    let step = try rowText(statement, 0), effect = try rowText(statement, 1)
                    journey.effectReceipts[step] = effect
                    if try rowText(statement, 2) == "awaiting_result" {
                        journey.pendingCommerce = .init(stepId: step, effectId: effect,
                            context: try customerJSON(ArmedJourney.Context.self, statement, 3),
                            placementId: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : try rowText(statement, 4))
                    }
                    if sqlite3_column_type(statement, 5) != SQLITE_NULL,
                       let event = try queryEvent(id: rowText(statement, 5)),
                       let control = JourneyPresentationEventProjector.controlEvent(event.customerEvent) {
                        journey.pendingCommerceOutcome = .init(eventId: event.id, effectId: effect, event: control)
                    }
                }
            }
            journey.experimentExposures = try customerExposures(key)
            return journey
        }
    }

    func customerExposures(_ key: CustomerJourneyKey) throws -> [JourneyRun.ExperimentExposure] {
        try customerQuery("SELECT experiment_id,variant_id,is_holdout,kind,event_id,selected_at,presentation_screen_id,shown_at FROM journey_experiment_selections WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=? ORDER BY experiment_id;", journeyValues(key)) { statement in
            var selections: [JourneyRun.ExperimentExposure] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return selections }
                guard code == SQLITE_ROW, let kind = JourneyRun.ExperimentExposure.Kind(rawValue: try rowText(statement, 3)) else { throw CustomerStoreError.invalidRow }
                selections.append(.init(experimentId: try rowText(statement, 0), variantId: try rowText(statement, 1), isHoldout: sqlite3_column_int(statement, 2) != 0,
                    kind: kind, eventId: try rowText(statement, 4), selectedAt: JourneyTime.date(sqlite3_column_int64(statement, 5)),
                    presentationScreenId: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : try rowText(statement, 6),
                    shownAt: optionalInteger(statement, 7).map(JourneyTime.date)))
            }
        }
    }

    func customerLogPage(owner: CustomerStoreOwner, name: String?, startedAt: Int64, deadlineAt: Int64?, after: CustomerLogPosition?, limit: Int) throws -> [StoredEvent] {
        var sql = "SELECT id FROM events WHERE scope=? AND user_id=? AND input_kind='event' AND timestamp>=?"
        var values = ownerValues(owner) + [.integer(startedAt)]
        if let name { sql += " AND name=?"; values.append(.text(name)) }
        if let deadlineAt { sql += " AND timestamp<=?"; values.append(.integer(deadlineAt)) }
        if let after { sql += " AND (timestamp>? OR (timestamp=? AND id COLLATE BINARY>?))"; values += [.integer(after.milliseconds), .integer(after.milliseconds), .text(after.eventId)] }
        sql += " ORDER BY timestamp,id COLLATE BINARY LIMIT ?;"
        values.append(.integer(Int64(min(256, max(1, limit)))))
        let ids: [String] = try customerQuery(sql, values) { statement in
            var ids: [String] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return ids }
                guard code == SQLITE_ROW else { throw CustomerStoreError.invalidRow }
                ids.append(try rowText(statement, 0))
            }
        }
        return try ids.map { guard let event = try queryEvent(id: $0) else { throw CustomerStoreError.invalidRow }; _ = try event.getPropertiesDictForIR(); return event }
    }

    func customerMeasurementPage(owner: CustomerStoreOwner, throughEventId: String?, limit: Int) throws -> [PendingConversionOccurrence] {
        var sql = "SELECT id,accepted_at FROM events WHERE scope=? AND user_id=? AND input_kind='event' AND measurement_state='pending'"
        var values = ownerValues(owner)
        if let throughEventId {
            sql += " AND capture_sequence<=(SELECT capture_sequence FROM events WHERE id=? AND scope=? AND user_id=?)"
            values += [.text(throughEventId)] + ownerValues(owner)
        }
        sql += """
         AND capture_sequence<COALESCE((SELECT MIN(frontier.capture_sequence) FROM events frontier
           WHERE frontier.scope=? AND frontier.user_id=? AND frontier.input_kind='event'
             AND (frontier.journey_plan_state='pending' OR EXISTS(SELECT 1 FROM journey_pending_work work
               WHERE work.authority_scope=frontier.scope AND work.user_id=frontier.user_id
                 AND work.input_event_id=frontier.id AND work.kind='admission'))),9223372036854775807)
        """
        values += ownerValues(owner)
        sql += " ORDER BY timestamp,id COLLATE BINARY LIMIT ?;"
        values.append(.integer(Int64(min(256, max(1, limit)))))
        let ids: [(String, Int64)] = try customerQuery(sql, values) { statement in
            var ids: [(String, Int64)] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return ids }
                guard code == SQLITE_ROW else { throw CustomerStoreError.invalidRow }
                ids.append((try rowText(statement, 0), sqlite3_column_int64(statement, 1)))
            }
        }
        return try ids.map { id, time in
            guard let event = try queryEvent(id: id) else { throw CustomerStoreError.invalidRow }
            return .init(event: event, acceptedAt: JourneyTime.date(time))
        }
    }

    func customerArmKey(_ receipt: JourneyStateArmReceipt) throws -> String {
        if receipt.binding.type == .continuation, let journeyId = receipt.binding.journeyId {
            return SHA256Provider.hexDigest(Data(("continuation:" + journeyId).utf8))
        }
        return SHA256Provider.hexDigest(try ExactJSONCodec.canonicalize(ExactJSONCodec.encode(receipt)))
    }

    func customerPutArm(owner: CustomerStoreOwner, receipt: JourneyStateArmReceipt, completed: Bool, reportId: String? = nil) throws {
        try customerWrite("""
        INSERT INTO journey_arm_receipts VALUES(?,?,?,?,?,?,NULL,?,?,?)
        ON CONFLICT(authority_scope,user_id,arm_key) DO UPDATE SET state=excluded.state,
        reference_json=excluded.reference_json,binding_json=excluded.binding_json,entry_kind=excluded.entry_kind,
        highest_generation=MAX(COALESCE(highest_generation,0),COALESCE(excluded.highest_generation,0)),report_event_id=excluded.report_event_id;
        """, ownerValues(owner) + [.text(try customerArmKey(receipt)), .blob(try ExactJSONCodec.encode(receipt.reference)),
            .blob(try ExactJSONCodec.encode(receipt.binding)), .text(receipt.entryKind.rawValue),
            receipt.binding.generation.map { .integer(Int64($0)) } ?? .null, .text(completed ? "completed" : "consumed"), reportId.map(CustomerSQLValue.text) ?? .null])
    }

    func customerValidate(_ command: CustomerExecutionCommand) throws {
        guard let scope = try customerScope(owner: command.owner), !scope.executionRevoked, scope.executionEpoch == command.epoch, scope.openedStateVersion == CustomerStoreSchema.stateVersion else { throw CustomerStoreError.revoked }
    }

    func customerCurrent(_ key: CustomerJourneyKey, revision: Int64) throws -> JourneyRun {
        guard let journey = try activeJourneys(owner: key.owner).first(where: { $0.journeyId == key.journeyId && Int64($0.generation) == key.legGeneration }), journey.cursorRevision == revision else { throw CustomerStoreError.staleRevision }
        return journey
    }

    func customerCommitEvents(_ records: [StableEventCaptureRecord], owner: CustomerStoreOwner) throws -> [StableEventCaptureCommit] {
        try records.map { record in
            try customerStatementBoundary()
            if let event = record.event {
                guard event.distinctId.utf8.elementsEqual(owner.userId.utf8) else { throw CustomerStoreError.wrongOwner }
                if let previous = try queryEvent(id: event.id) {
                    guard previous.isByteEquivalent(to: event), previous.journeyOrigin == event.journeyOrigin else { throw CustomerStoreError.eventIdentityConflict }
                }
            }
            let commit = try commitStableCaptureUnfenced(eventId: record.eventId, event: record.event, recordedAt: record.recordedAt, assigningCommitSequence: true)
            if case .captured = commit.outcome {
                guard try customerExists("SELECT 1 FROM events WHERE id=? AND scope=? AND user_id=?;", [.text(record.eventId)] + ownerValues(owner)) else { throw CustomerStoreError.wrongOwner }
            }
            let result = StableEventCaptureCommit(outcome: commit.outcome, commitSequence: commit.commitSequence,
                localRoutePending: try stageStableRoute(eventId: record.eventId, outcome: commit.outcome))
            try stageCommittedStableRoute(result, eventId: record.eventId, admission: record.routeAdmission)
            return result
        }
    }

    func executeCustomerCommand(_ command: CustomerExecutionCommand) throws -> CustomerExecutionResult {
        customerCurrentCommandLabel = command.mutation.faultLabel
        customerCommandActive = true
        customerStatementNumber = 0
        defer { customerCommandActive = false }
        let operation = {
            let result = try self.customerTransaction { try self.customerExecuteCommand(command) }
            if case .admit(let admission) = command.mutation, result.journey != nil {
                admission.onAdmitted?()
            }
            return result
        }
        let fencedOperation = {
            if let fence = command.profileFence, let token = command.profileToken {
                guard let result = try fence.performIfCurrent(token, operation) else { throw CustomerStoreError.revoked }
                return result
            }
            return try operation()
        }
        if let admission = command.admission {
            guard let result = try admission.commitJournalIfCurrent(fencedOperation) else { throw CustomerStoreError.revoked }
            return result
        }
        return try fencedOperation()
    }

    func customerExecuteCommand(_ command: CustomerExecutionCommand) throws -> CustomerExecutionResult {
        let version = try customerMetadata().stateVersion
        guard version == CustomerStoreSchema.stateVersion else { throw CustomerStoreError.unsupportedStateVersion(version) }
        switch command.mutation {
        case .responseReply, .normalizeResponseClock:
            guard try customerScope(owner: command.owner) != nil else { throw CustomerStoreError.wrongOwner }
        default: try customerValidate(command)
        }
        let owner = command.owner
        for record in command.events {
            guard let event = record.event else { continue }
            guard record.eventId.utf8.elementsEqual(event.id.utf8), event.distinctId.utf8.elementsEqual(owner.userId.utf8) else { throw CustomerStoreError.wrongOwner }
            if let stored = try queryEvent(id: event.id) {
                guard stored.isByteEquivalent(to: event),
                      try customerExists("SELECT 1 FROM events WHERE id=? AND scope=? AND user_id=? AND origin='device';", [.text(event.id)] + ownerValues(owner)) else { throw CustomerStoreError.eventIdentityConflict }
            }
        }
        var result = CustomerExecutionResult()
        switch command.mutation {
        case let .freezePlan(eventId, targets):
            try customerRequireEvent(owner, id: eventId)
            if try customerExists("SELECT 1 FROM events WHERE id=? AND journey_plan_state IN ('done','retired');", [.text(eventId)]) { result.replayed = true; return result }
            if try customerExists("SELECT 1 FROM events WHERE id=? AND journey_plan_state='pending';", [.text(eventId)]) {
                for target in targets {
                    let at = try customerEventTime(owner, id: eventId)
                    try customerWrite("INSERT INTO journey_pending_work VALUES(?,?,?,'admission',NULL,NULL,NULL,?,?,'pending',0,?,?,NULL);",
                        ownerValues(owner) + [.text("admit:" + eventId + ":" + target), .text(eventId), .text(target), .integer(at), .integer(at)])
                }
                try customerWrite("UPDATE events SET journey_plan_state='planned' WHERE id=?;", [.text(eventId)])
            }
            result.targets = try customerQuery("SELECT target_key FROM journey_pending_work WHERE authority_scope=? AND user_id=? AND input_event_id=? AND kind='admission' ORDER BY target_key;", ownerValues(owner) + [.text(eventId)]) { statement in
                var targets: [String] = []
                while true {
                    let code = sqlite3_step(statement)
                    if code == SQLITE_DONE { return targets }
                    guard code == SQLITE_ROW else { throw CustomerStoreError.invalidRow }
                    targets.append(try rowText(statement, 0))
                }
            }
        case let .decideTarget(eventId, target):
            if !(try customerHasApplication(owner, eventId: eventId, target: target)) {
                try customerWrite("INSERT INTO journey_event_applications VALUES(?,?,?,?,NULL,NULL,NULL,'declined',?);", ownerValues(owner) + [.text(eventId), .text(target), .integer(try customerEventTime(owner, id: eventId))])
            }
            try customerWrite("DELETE FROM journey_pending_work WHERE authority_scope=? AND user_id=? AND input_event_id=? AND target_key=?;", ownerValues(owner) + [.text(eventId), .text(target)])
        case .admit(let admission):
            let journey = admission.journey
            if let source = admission.sourceEventId,
               try customerHasApplication(owner, eventId: source, target: admission.targetKey) { result.replayed = true; return result }
            guard !((try activeJourneys(owner: owner)).contains { $0.reference.experienceId == journey.reference.experienceId }) else { result.replayed = true; return result }
            let armKey = try customerArmKey(admission.arm)
            if admission.stateLatch, try customerExists("SELECT 1 FROM journey_arm_receipts WHERE authority_scope=? AND user_id=? AND arm_key=?;", ownerValues(owner) + [.text(armKey)]) { result.replayed = true; return result }
            if !journey.isEnrollment, try customerExists("SELECT 1 FROM journey_arm_receipts WHERE authority_scope=? AND user_id=? AND arm_key=? AND highest_generation>=?;", ownerValues(owner) + [.text(armKey), .integer(Int64(journey.generation))]) { result.replayed = true; return result }
            if journey.isEnrollment, let last = try customerFrequency(owner: owner, experienceId: journey.reference.experienceId) {
                switch journey.reentry.type {
                case .oneTime: result.replayed = true; return result
                case .oncePerWindow:
                    guard let seconds = journey.reentry.windowSeconds, seconds > 0 else { throw CustomerStoreError.invalidRow }
                    if Int64(JourneyConversionWatch.millis(journey.startedAt)) - last < Int64(seconds) * 1000 { result.replayed = true; return result }
                case .everyMatch: break
                }
            }
            if let source = admission.sourceEventId { try customerRequireEvent(owner, id: source) }
            let snapshot = journey.executionSnapshot
            let delivery = try ExactJSONCodec.encode(snapshot.delivery), assignments = try ExactJSONCodec.encode(snapshot.assignments), customer = try ExactJSONCodec.encode(snapshot.customer ?? [:])
            let snapshotId = SHA256Provider.hexDigest(delivery + assignments + customer)
            try customerWrite("INSERT OR IGNORE INTO journey_execution_snapshots VALUES(?,?,?,?,?,?);", ownerValues(owner) + [.text(snapshotId), .blob(delivery), .blob(assignments), .blob(customer)])
            let policyHash = admission.policyHash
            try customerWrite("""
            INSERT INTO journeys VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,'executing',?,?,NULL,NULL);
            """, ownerValues(owner) + [.text(journey.journeyId), .integer(Int64(journey.generation)), .text(journey.reference.experienceId), .text(journey.reference.versionId), .text(journey.reference.legId),
                .text(journey.reference.descriptorSha256), .text(policyHash), .text(snapshotId), .blob(try ExactJSONCodec.encode(journey.reentry)),
                .integer(Int64(JourneyConversionWatch.millis(journey.startedAt))), .integer(journey.isEnrollment ? 1 : 0), .text(journey.startedEventId), .text(journey.completedEventId), .text(journey.stepId),
                .blob(try ExactJSONCodec.encode(journey.context)), .blob(try ExactJSONCodec.encode(journey.outputs))])
            let key = CustomerJourneyKey(owner: owner, journeyId: journey.journeyId, legGeneration: Int64(journey.generation))
            let consumedAt = try admission.sourceEventId.map { try customerEventTime(owner, id: $0) }
            try customerWrite("INSERT INTO journey_cursors VALUES(?,?,?,?,?,NULL,NULL,0,?,?,NULL,NULL,0,0);", journeyValues(key) + [admission.sourceEventId.map(CustomerSQLValue.text) ?? .null,
                consumedAt.map(CustomerSQLValue.integer) ?? .null, admission.sourceEventId.map(CustomerSQLValue.text) ?? .null])
            for pin in admission.pins {
                guard pin.relativePath == CustomerPinFileOwner.relativePath(owner: owner, sha256: pin.objectSHA256, kind: pin.kind) else { throw CustomerStoreError.wrongOwner }
                try customerWrite("INSERT INTO journey_release_pins VALUES(?,?,?,?,?,?,?,?);", journeyValues(key) + [.text(pin.objectSHA256), .text(pin.kind.rawValue), .text(pin.relativePath), .integer(pin.sizeBytes)])
            }
            if journey.isEnrollment {
                try customerWrite("INSERT INTO journey_frequency VALUES(?,?,?,?,1) ON CONFLICT(authority_scope,user_id,experience_id) DO UPDATE SET last_started_at=MAX(last_started_at,excluded.last_started_at),ever_started=1;", ownerValues(owner) + [.text(journey.reference.experienceId), .integer(Int64(JourneyConversionWatch.millis(journey.startedAt)))])
            }
            try customerPutArm(owner: owner, receipt: admission.arm, completed: false)
            try customerWrite("INSERT INTO journey_pending_work VALUES(?,?,?,'arm',?,?,NULL,NULL,?,'pending',0,?,?,NULL);",
                ownerValues(owner) + [.text("arm:" + journey.id), .text(journey.journeyId), .integer(Int64(journey.generation)), .text(armKey),
                    .integer(Int64(JourneyConversionWatch.millis(journey.startedAt))), .integer(Int64(JourneyConversionWatch.millis(journey.startedAt)))])
            if let watch = admission.watch {
                if let existing = try customerWatches(owner: owner)[watch.journeyId] {
                    guard existing.experienceId == watch.experienceId, existing.versionId == watch.versionId,
                          existing.policyHash == watch.policyHash, existing.startedAt == watch.startedAt else { throw CustomerStoreError.invalidRow }
                    if let revision = watch.serverRevision, revision > (existing.serverRevision ?? -1) { try customerPutWatch(owner: owner, watch: watch) }
                } else { try customerPutWatch(owner: owner, watch: watch) }
            }
            result.commits = try customerCommitEvents(command.events, owner: owner)
            try customerWrite("UPDATE events SET journey_id=?,leg_generation=?,event_role='started',journey_plan_state='done' WHERE id=?;", [.text(key.journeyId), .integer(key.legGeneration), .text(journey.startedEventId)])
            if let source = admission.sourceEventId {
                try customerApplication(owner, eventId: source, target: admission.targetKey, journey: journey)
                try customerWrite("DELETE FROM journey_pending_work WHERE authority_scope=? AND user_id=? AND input_event_id=? AND target_key=?;", ownerValues(owner) + [.text(source), .text(admission.targetKey)])
            }
            result.journey = try customerCurrent(key, revision: 0)
        case .applyInput(let proposed), .resolveWait(let proposed):
            var transition = proposed
            let invocationEventId = transition.rendererInvocationId.map { "renderer:" + $0 }
            if let event = invocationEventId ?? transition.eventId, try customerHasApplication(owner, eventId: event, target: transition.targetKey) { result.replayed = true; return result }
            if let eventId = invocationEventId {
                _ = try customerCurrent(transition.key, revision: transition.expectedRevision)
                let at = transition.rendererOccurredAt.map(JourneyTime.date) ?? command.events.first?.recordedAt ?? Date()
                let event = try StoredEvent(id: eventId, name: "$journey_response_change", properties: try ExactJSONCodec.encode(transition.context.responses), timestamp: at, distinctId: owner.userId)
                _ = try insert(event, deliveryState: .localOnly, origin: .device, assigningCommitSequence: false, acceptedAt: at)
                try customerWrite("UPDATE events SET journey_id=?,leg_generation=?,journey_plan_state='done',measurement_state='done' WHERE id=?;", [.text(transition.key.journeyId), .integer(transition.key.legGeneration), .text(eventId)])
                if transition.eventId == nil { transition.eventId = eventId }
            }
            result.commits = try customerApply(transition, events: command.events)
            if let eventId = invocationEventId, eventId != transition.eventId {
                let journey = try customerCurrent(transition.key, revision: transition.expectedRevision + 1)
                try customerApplication(owner, eventId: eventId, target: transition.targetKey, journey: journey)
            }
            result.journey = try customerCurrent(transition.key, revision: transition.expectedRevision + 1)
        case let .beginEvaluation(key, revision, now, triggeringAt):
            let journey = try customerCurrent(key, revision: revision)
            let effectiveTrigger: Int64?
            if let triggeringAt { effectiveTrigger = triggeringAt }
            else if let eventId = journey.inputEventId { effectiveTrigger = try customerEventTime(owner, id: eventId) }
            else { effectiveTrigger = nil }
            let lag: Int64?
            if let triggeringAt = effectiveTrigger {
                let difference = now.subtractingReportingOverflow(triggeringAt)
                guard !difference.overflow else { throw CustomerStoreError.invalidRow }
                lag = max(0, difference.partialValue)
            } else { lag = nil }
            try customerWrite("UPDATE journey_cursors SET evaluation_at=COALESCE(evaluation_at,?),initial_lag_ms=COALESCE(initial_lag_ms,?) WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=?;", [.integer(now), lag.map(CustomerSQLValue.integer) ?? .integer(0)] + journeyValues(key))
            result.journey = try customerCurrent(key, revision: revision)
        case let .claimEffect(key, revision, stepId, effectId, kind):
            let journey = try customerCurrent(key, revision: revision)
            guard journey.stepId == stepId else { throw CustomerStoreError.staleRevision }
            if let existing = journey.effectReceipts[stepId] { result.effectId = existing; return result }
            try customerWrite("INSERT INTO journey_effects VALUES(?,?,?,?,?,?,?,'claimed',?,NULL,NULL,NULL);", journeyValues(key) + [.text(effectId), .text(stepId), .text(kind), .blob(try ExactJSONCodec.encode(journey.context))])
            try customerWrite("DELETE FROM journey_waits WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=?;", journeyValues(key))
            try customerWrite("UPDATE journeys SET status='awaiting_native_result' WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=?;", journeyValues(key))
            let at = journey.evaluationAt ?? Int64(JourneyConversionWatch.millis(Date()))
            try customerWrite("INSERT OR IGNORE INTO journey_pending_work VALUES(?,?,?,'effect',?,?,?,?,?,'pending',0,?,?,NULL);", ownerValues(owner) + [.text("effect:" + effectId), .text(key.journeyId), .integer(key.legGeneration), .integer(revision), .null, .text(effectId), .integer(at), .integer(at)])
            result.effectId = effectId
        case let .retainCommerce(key, revision, stepId, effectId, placementId):
            _ = try customerCurrent(key, revision: revision)
            guard try customerExists("SELECT 1 FROM journey_effects WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=? AND step_id=? AND effect_id=? AND state IN ('claimed','awaiting_result');", journeyValues(key) + [.text(stepId), .text(effectId)]) else { throw CustomerStoreError.staleRevision }
            try customerWrite("UPDATE journey_effects SET state='awaiting_result',placement_id=? WHERE authority_scope=? AND user_id=? AND effect_id=?;", [placementId.map(CustomerSQLValue.text) ?? .null] + ownerValues(owner) + [.text(effectId)])
            result.journey = try customerCurrent(key, revision: revision)
        case let .receiveEffectResult(key, revision, stepId, effectId, eventId):
            _ = try customerCurrent(key, revision: revision)
            try customerRequireEvent(owner, id: eventId)
            guard try customerEffectMatches(key, stepId: stepId, effectId: effectId, eventId: eventId) else { result.replayed = true; return result }
            try customerWrite("UPDATE journey_effects SET result_event_id=? WHERE authority_scope=? AND user_id=? AND effect_id=?;", [.text(eventId)] + ownerValues(owner) + [.text(effectId)])
            result.journey = try customerCurrent(key, revision: revision)
        case let .settleEffect(transition, effectId, stepId):
            guard try customerEffectMatches(transition.key, stepId: stepId, effectId: effectId, eventId: transition.eventId) else { result.replayed = true; return result }
            result.commits = try customerApply(transition, events: command.events)
            try customerWrite("UPDATE journeys SET authored_close_outcome=NULL WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=?;", journeyValues(transition.key))
            try customerWrite("UPDATE journey_effects SET state='applied',result_event_id=?,settled_at=? WHERE authority_scope=? AND user_id=? AND effect_id=?;",
                [transition.eventId.map(CustomerSQLValue.text) ?? .null, .integer(Int64(JourneyConversionWatch.millis(Date())))] + ownerValues(owner) + [.text(effectId)])
            try customerWrite("DELETE FROM journey_pending_work WHERE authority_scope=? AND user_id=? AND work_key=?;", ownerValues(owner) + [.text("effect:" + effectId)])
            result.journey = try customerCurrent(transition.key, revision: transition.expectedRevision + 1)
        case let .authoredClose(key, revision, effectId, outcome):
            _ = try customerCurrent(key, revision: revision)
            guard try customerExists("SELECT 1 FROM journey_effects WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=? AND effect_id=? AND state='awaiting_result';", journeyValues(key) + [.text(effectId)]) else { throw CustomerStoreError.staleRevision }
            try customerWrite("UPDATE journeys SET authored_close_outcome=? WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=?;", [.text(outcome)] + journeyValues(key))
        case let .complete(key, revision, at, reportId):
            if !(try customerExists("SELECT 1 FROM journeys WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=?;", journeyValues(key))) {
                guard try customerExists("SELECT 1 FROM events WHERE id=? AND scope=? AND user_id=? UNION ALL SELECT 1 FROM stable_event_drops WHERE event_id=?;", [.text(reportId)] + ownerValues(owner) + [.text(reportId)]) else { throw CustomerStoreError.staleRevision }
                result.replayed = true; return result
            }
            let journey = try customerCurrent(key, revision: revision)
            guard journey.completedEventId == reportId, command.events.contains(where: { $0.eventId == reportId }) else { throw CustomerStoreError.invalidRow }
            result.commits = try customerCommitEvents(command.events, owner: owner)
            try customerWrite("UPDATE events SET journey_id=?,leg_generation=?,event_role='completed',journey_plan_state='done' WHERE id=?;", [.text(key.journeyId), .integer(key.legGeneration), .text(reportId)])
            try customerWrite("UPDATE journey_conversion_watches SET leg_completed_at=? WHERE authority_scope=? AND user_id=? AND journey_id=?;", [.integer(at)] + ownerValues(owner) + [.text(key.journeyId)])
            try customerWrite("UPDATE journey_arm_receipts SET state='completed',report_event_id=? WHERE authority_scope=? AND user_id=? AND arm_key=(SELECT target_key FROM journey_pending_work WHERE authority_scope=? AND user_id=? AND work_key=?);", [.text(reportId)] + ownerValues(owner) + ownerValues(owner) + [.text("arm:" + journey.id)])
            try customerWrite("DELETE FROM journey_effects WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=? AND result_event_id IS NULL AND NOT EXISTS(SELECT 1 FROM events WHERE id=journey_effects.effect_id AND journey_origin IS NOT NULL);", journeyValues(key))
            try customerWrite("DELETE FROM journeys WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=?;", journeyValues(key))
            try customerWrite("DELETE FROM journey_pending_work WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=?;", journeyValues(key))
            try customerWrite("DELETE FROM journey_event_applications WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=? AND event_id IN (SELECT id FROM events WHERE journey_plan_state='done');", journeyValues(key))
            try customerWrite("DELETE FROM events WHERE scope=? AND user_id=? AND journey_id=? AND leg_generation=? AND delivery_state=3 AND NOT EXISTS(SELECT 1 FROM journey_event_applications a WHERE a.authority_scope=events.scope AND a.user_id=events.user_id AND a.event_id=events.id);", journeyValues(key))
            try customerWrite("DELETE FROM journey_execution_snapshots WHERE authority_scope=? AND user_id=? AND NOT EXISTS(SELECT 1 FROM journeys j WHERE j.authority_scope=journey_execution_snapshots.authority_scope AND j.user_id=journey_execution_snapshots.user_id AND j.snapshot_id=journey_execution_snapshots.snapshot_id);", ownerValues(owner))
        case let .bindExposures(key, revision, screenId):
            _ = try customerCurrent(key, revision: revision)
            try customerWrite("UPDATE journey_experiment_selections SET presentation_screen_id=? WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=? AND presentation_screen_id IS NULL AND shown_at IS NULL;", [.text(screenId)] + journeyValues(key))
        case let .publishExposures(key, revision, screenId, shownAt):
            _ = try customerCurrent(key, revision: revision)
            let selections = try customerExposures(key).filter { $0.presentationScreenId == screenId && $0.shownAt == nil }
            guard Set(selections.map(\.eventId)) == Set(command.events.map(\.eventId)) else { throw CustomerStoreError.invalidRow }
            result.commits = try customerCommitEvents(command.events, owner: owner)
            try customerWrite("UPDATE journey_experiment_selections SET shown_at=? WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=? AND presentation_screen_id=? AND shown_at IS NULL;", [.integer(shownAt)] + journeyValues(key) + [.text(screenId)])
        case .expireMeasurement(let cutoff):
            try customerWrite("UPDATE events SET measurement_state='done' WHERE scope=? AND user_id=? AND measurement_state='pending' AND accepted_at<?;", ownerValues(owner) + [.integer(cutoff)])
        case let .measure(eventId, watches, expectedDigest):
            try customerRequireEvent(owner, id: eventId)
            if try customerExists("SELECT 1 FROM events WHERE id=? AND measurement_state='done';", [.text(eventId)]) { result.replayed = true; return result }
            let currentDigest = SHA256Provider.hexDigest(try ExactJSONCodec.canonicalize(ExactJSONCodec.encode(customerWatches(owner: owner))))
            guard currentDigest == expectedDigest else { throw CustomerStoreError.staleRevision }
            for watch in watches.values { try customerPutWatch(owner: owner, watch: watch) }
            try customerWrite("UPDATE events SET measurement_state='done' WHERE id=? AND scope=? AND user_id=?;", [.text(eventId)] + ownerValues(owner))
        case let .reserveResponse(key, formName, answers, queued):
            result.response = try customerReserveResponse(key, formName: formName, answers: answers, queued: queued)
        case .normalizeResponseClock(let at):
            let now = JourneyTime.date(at)
            for (key, lane) in try customerResponseLanes(owner: owner) {
                guard var retry = lane.retry?.domainValue, now < retry.observedAt else { continue }
                retry.normalizeClock(at: now)
                try customerWriteLane(owner: owner, journeyId: key.journeyId, formName: key.formName,
                    lane: .init(experienceId: lane.experienceId, versionId: lane.versionId, sequence: lane.sequence, pending: lane.pending, retry: .init(retry), display: lane.display))
            }
        case let .responseReply(sheet, reply, at, waiting):
            result.stopped = try customerResponseReply(owner: owner, sheet: sheet, reply: reply, at: JourneyTime.date(at), waiting: waiting)
        case .retainArms(let allowed):
            let keep = try Set(allowed.map(customerArmKey))
            let keys: [String] = try customerQuery("SELECT arm_key FROM journey_arm_receipts WHERE authority_scope=? AND user_id=?;", ownerValues(owner)) { statement in
                var keys: [String] = []
                while true {
                    let code = sqlite3_step(statement)
                    if code == SQLITE_DONE { return keys }
                    guard code == SQLITE_ROW else { throw CustomerStoreError.invalidRow }
                    keys.append(try rowText(statement, 0))
                }
            }
            for key in keys where !keep.contains(key) {
                try customerWrite("DELETE FROM journey_arm_receipts WHERE authority_scope=? AND user_id=? AND arm_key=? AND NOT EXISTS(SELECT 1 FROM journey_pending_work w WHERE w.authority_scope=journey_arm_receipts.authority_scope AND w.user_id=journey_arm_receipts.user_id AND w.kind='arm' AND w.target_key=journey_arm_receipts.arm_key);", ownerValues(owner) + [.text(key)])
            }
        case .clearArms(let kind):
            try customerWrite("DELETE FROM journey_arm_receipts WHERE authority_scope=? AND user_id=? AND entry_kind=? AND highest_generation IS NULL;", ownerValues(owner) + [.text(kind.rawValue)])
        case .revoke:
            guard try activeJourneys(owner: owner).isEmpty else { throw CustomerStoreError.invalidRow }
            try customerWrite("UPDATE customer_scopes SET execution_epoch=execution_epoch+1,execution_revoked=1 WHERE authority_scope=? AND user_id=?;", ownerValues(owner))
            try customerWrite("DELETE FROM journey_arm_receipts WHERE authority_scope=? AND user_id=? AND (highest_generation IS NULL OR state='consumed');", ownerValues(owner))
        case let .recover(boundaries, revoke):
            for boundary in boundaries {
                let terminal = CustomerExecutionCommand(owner: owner, epoch: command.epoch,
                    mutation: .complete(key: boundary.key, revision: boundary.revision, at: boundary.at, reportId: boundary.reportId),
                    events: command.events.filter { $0.eventId == boundary.reportId })
                result.commits += try customerExecuteCommand(terminal).commits
            }
            if revoke {
                _ = try customerExecuteCommand(.init(owner: owner, epoch: command.epoch, mutation: .revoke))
            }
        case .reopen:
            try customerWrite("UPDATE customer_scopes SET execution_revoked=0 WHERE authority_scope=? AND user_id=?;", ownerValues(owner))
        case .compact(let eventId):
            guard !(try customerExists("SELECT 1 FROM journey_pending_work WHERE authority_scope=? AND user_id=? AND input_event_id=?;", ownerValues(owner) + [.text(eventId)])) else { throw CustomerStoreError.invalidRow }
            try customerWrite("UPDATE events SET journey_plan_state='done' WHERE id=? AND scope=? AND user_id=?;", [.text(eventId)] + ownerValues(owner))
            try customerWrite("DELETE FROM journey_event_applications WHERE authority_scope=? AND user_id=? AND event_id=? AND NOT EXISTS(SELECT 1 FROM journeys j WHERE j.authority_scope=journey_event_applications.authority_scope AND j.user_id=journey_event_applications.user_id AND j.journey_id=journey_event_applications.journey_id AND j.leg_generation=journey_event_applications.leg_generation);", ownerValues(owner) + [.text(eventId)])
        }
        return result
    }

    func customerRequireEvent(_ owner: CustomerStoreOwner, id: String) throws {
        guard try customerExists("SELECT 1 FROM events WHERE scope=? AND user_id=? AND id=?;", ownerValues(owner) + [.text(id)]) else { throw CustomerStoreError.wrongOwner }
    }

    func customerEventTime(_ owner: CustomerStoreOwner, id: String) throws -> Int64 {
        try customerQuery("SELECT timestamp FROM events WHERE scope=? AND user_id=? AND id=?;", ownerValues(owner) + [.text(id)]) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw CustomerStoreError.wrongOwner }
            return sqlite3_column_int64(statement, 0)
        }
    }

    func customerHasApplication(_ owner: CustomerStoreOwner, eventId: String, target: String) throws -> Bool {
        try customerExists("SELECT 1 FROM journey_event_applications WHERE authority_scope=? AND user_id=? AND event_id=? AND target_key=?;", ownerValues(owner) + [.text(eventId), .text(target)])
    }

    func customerApplication(_ owner: CustomerStoreOwner, eventId: String, target: String, journey: JourneyRun) throws {
        try customerWrite("INSERT INTO journey_event_applications VALUES(?,?,?,?,?,?,?,'applied',?);", ownerValues(owner) + [.text(eventId), .text(target), .text(journey.journeyId), .integer(Int64(journey.generation)), .integer(journey.cursorRevision), .integer(try customerEventTime(owner, id: eventId))])
    }

    func customerEffectMatches(_ key: CustomerJourneyKey, stepId: String, effectId: String, eventId: String?) throws -> Bool {
        guard try customerExists("SELECT 1 FROM journey_effects WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=? AND step_id=? AND effect_id=? AND state IN ('claimed','awaiting_result') AND (result_event_id IS NULL OR result_event_id=?);", journeyValues(key) + [.text(stepId), .text(effectId), eventId.map(CustomerSQLValue.text) ?? .null]) else { return false }
        if let eventId {
            try customerRequireEvent(key.owner, id: eventId)
            guard let event = try queryEvent(id: eventId) else { return false }
            let properties = event.getPropertiesDict()
            guard (properties["effect_id"] as? String ?? event.id) == effectId else { return false }
            let placement: String? = try customerQuery("SELECT placement_id FROM journey_effects WHERE authority_scope=? AND user_id=? AND effect_id=?;", ownerValues(key.owner) + [.text(effectId)]) { statement in
                guard sqlite3_step(statement) == SQLITE_ROW else { throw CustomerStoreError.invalidRow }
                return sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : try rowText(statement, 0)
            }
            if let placement, properties["placement_id"] as? String != placement { return false }
        }
        return true
    }

    func customerApply(_ transition: CustomerInputTransition, events: [StableEventCaptureRecord]) throws -> [StableEventCaptureCommit] {
        let key = transition.key
        let journey = try customerCurrent(key, revision: transition.expectedRevision)
        let commits = try customerCommitEvents(events, owner: key.owner)
        try customerWrite("UPDATE journey_effects SET state='applied' WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=? AND step_id=? AND state='claimed' AND effect_id<>?;", journeyValues(key) + [.text(journey.stepId), .text(transition.commerceToRetain?.effectId ?? "")])
        if let event = transition.eventId { try customerRequireEvent(key.owner, id: event) }
        if transition.consumesWait {
            guard let park = journey.park else { throw CustomerStoreError.staleRevision }
            if let eventId = transition.eventId {
                let time = try customerEventTime(key.owner, id: eventId)
                if let start = park.anchorAt, time < Int64(JourneyConversionWatch.millis(start)) { throw CustomerStoreError.staleRevision }
                if let deadline = park.wakeAt, time > Int64(JourneyConversionWatch.millis(deadline)) { throw CustomerStoreError.staleRevision }
                if let consumed = journey.lastConsumed {
                    guard time > consumed.milliseconds || (time == consumed.milliseconds && consumed.eventId.utf8.lexicographicallyPrecedes(eventId.utf8)) else { throw CustomerStoreError.staleRevision }
                }
            }
            if let query = transition.waitEvaluation, let name = try query.executor.eventNameForWait(query.step) {
                var after = journey.lastConsumed
                var found: StoredEvent?
                while true {
                    let page = try customerLogPage(owner: key.owner, name: name, startedAt: query.checkpoint.anchorAtMillis, deadlineAt: query.checkpoint.wakeAtMillis, after: after, limit: 128)
                    if page.isEmpty { break }
                    found = page.first { row in
                        guard let event = JourneyPresentationEventProjector.controlEvent(row.customerEvent) else { return false }
                        return query.executor.parkedWaitAccepts(event, step: query.step, context: query.context, assignments: query.assignments, customer: query.customer, checkpoint: query.checkpoint)
                    }
                    if found != nil { break }
                    guard let last = page.last else { break }
                    after = .init(milliseconds: Int64(JourneyConversionWatch.millis(last.timestamp)), eventId: last.id)
                }
                guard found?.id == transition.eventId else { throw CustomerStoreError.staleRevision }
            }
        }
        if let commerce = transition.commerceToRetain {
            guard try customerExists("SELECT 1 FROM journey_effects WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=? AND effect_id=? AND step_id=? AND state IN ('claimed','awaiting_result');", journeyValues(key) + [.text(commerce.effectId), .text(commerce.stepId)]) else { throw CustomerStoreError.staleRevision }
            try customerWrite("UPDATE journey_effects SET state='awaiting_result',placement_id=? WHERE authority_scope=? AND user_id=? AND effect_id=?;", [commerce.placementId.map(CustomerSQLValue.text) ?? .null] + ownerValues(key.owner) + [.text(commerce.effectId)])
        }
        try customerWrite("UPDATE journeys SET step_id=?,cursor_revision=cursor_revision+1,context_json=?,native_snapshot_json=?,status=? WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=?;", [.text(transition.stepId), .blob(try ExactJSONCodec.encode(ArmedJourney.Context(event: transition.context.event, responses: [:]))), try transition.nativeSnapshot.map { .blob(try ExactJSONCodec.encode($0)) } ?? .null,
            .text(transition.waitKind == "availability" ? "awaiting_presentation" : (transition.checkpoint == nil ? "executing" : "waiting"))] + journeyValues(key))
        try customerWrite("DELETE FROM journey_waits WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=?;", journeyValues(key))
        let presentationKey = "presentation:" + journey.id
        try customerWrite("DELETE FROM journey_pending_work WHERE authority_scope=? AND user_id=? AND work_key=?;", ownerValues(key.owner) + [.text(presentationKey)])
        if transition.waitKind == "availability" {
            let at = transition.availabilityAt ?? Int64(JourneyConversionWatch.millis(journey.startedAt))
            try customerWrite("INSERT INTO journey_pending_work VALUES(?,?,?,'presentation',?,?,?,NULL,NULL,'not_yet',0,?,?,NULL);", ownerValues(key.owner) + [.text(presentationKey), .text(key.journeyId), .integer(key.legGeneration), .integer(transition.expectedRevision + 1), .integer(at), .integer(at)])
        }
        if let checkpoint = transition.checkpoint {
            try customerWrite("INSERT INTO journey_waits VALUES(?,?,?,?,?,?,?,?,?,?,?);", journeyValues(key) + [.integer(transition.expectedRevision + 1), .text(transition.stepId), .text(transition.waitKind), .integer(checkpoint.anchorAtMillis), .integer(checkpoint.wakeAtMillis), journey.lastConsumed.map { .integer($0.milliseconds) } ?? .null, journey.lastConsumed.map { .text($0.eventId) } ?? .null])
        }
        let newInput = transition.eventId != nil && transition.eventId != journey.inputEventId
        if transition.consumesWait || transition.resetEvaluation || transition.presentationSource != nil || newInput {
            try customerWrite("UPDATE journey_cursors SET input_event_id=?,evaluation_at=NULL,initial_lag_ms=NULL WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=?;", [transition.eventId.map(CustomerSQLValue.text) ?? .null] + journeyValues(key))
        }
        if (transition.consumesWait || transition.resetEvaluation || transition.presentationSource != nil || newInput), let event = transition.eventId {
            let time = try customerEventTime(key.owner, id: event)
            if journey.lastConsumed.map({ time > $0.milliseconds || (time == $0.milliseconds && $0.eventId.utf8.lexicographicallyPrecedes(event.utf8)) }) ?? true {
                try customerWrite("UPDATE journey_cursors SET last_consumed_at=?,last_consumed_event_id=? WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=?;", [.integer(time), .text(event)] + journeyValues(key))
            }
        }
        try customerWrite("UPDATE journey_cursors SET evaluation_at=NULL,responses_changed=? WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=?;", [.integer(transition.responsesChanged ? 1 : 0)] + journeyValues(key))
        if let at = transition.resumeInPresentAt {
            try customerWrite("UPDATE journey_cursors SET evaluation_at=?,initial_lag_ms=0 WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=?;", [.integer(at)] + journeyValues(key))
        }
        if let source = transition.presentationSource {
            try customerWrite("UPDATE journey_cursors SET presentation_source_json=?,presentation_source_event_id=?,next_presentation_batch_sequence=next_presentation_batch_sequence+1,next_presentation_emission_sequence=next_presentation_emission_sequence+? WHERE authority_scope=? AND user_id=? AND journey_id=? AND leg_generation=?;", [.blob(try ExactJSONCodec.encode(source)), transition.eventId.map(CustomerSQLValue.text) ?? .null, .integer(Int64(events.count))] + journeyValues(key))
        }
        if let exposure = transition.exposure {
            try customerWrite("INSERT OR IGNORE INTO journey_experiment_selections VALUES(?,?,?,?,?,?,?,?,?,?,NULL,NULL);", journeyValues(key) + [.text(exposure.experimentId), .text(exposure.variantId), .integer(exposure.isHoldout ? 1 : 0), .text(exposure.kind.rawValue), .text(exposure.eventId), .integer(Int64(JourneyConversionWatch.millis(exposure.selectedAt)))])
        }
        if let event = transition.eventId {
            try customerApplication(key.owner, eventId: event, target: transition.targetKey, journey: journey)
        }
        return commits
    }
}

extension StoredEvent {
    var customerEvent: NuxieEvent {
        NuxieEvent(id: id, name: name, forwardingName: name, distinctId: distinctId,
            properties: getPropertiesDict(), timestamp: timestamp, journeyOrigin: journeyOrigin)
    }
}
