import Foundation
import SQLite3

extension SQLiteEventStore {
    func customerPutWatch(owner: CustomerStoreOwner, watch: JourneyConversionWatch) throws {
        try customerWrite("""
        INSERT INTO journey_conversion_watches VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(authority_scope,user_id,journey_id) DO UPDATE SET basis_event_id=excluded.basis_event_id,
        basis_at=excluded.basis_at,expires_at=excluded.expires_at,conversion_event_id=excluded.conversion_event_id,
        conversion_at=excluded.conversion_at,server_revision=excluded.server_revision,leg_completed_at=excluded.leg_completed_at,retain_until=excluded.retain_until;
        """, ownerValues(owner) + [.text(watch.journeyId), .text(watch.experienceId), .text(watch.versionId), .text(watch.policyHash),
            .blob(try ExactJSONCodec.encode(watch.goal)), .blob(try ExactJSONCodec.encode(watch.entryContext)), .integer(Int64(watch.startedAt)),
            watch.basis.map { .text($0.eventId) } ?? .null, watch.basis.map { .integer(Int64($0.occurredAt)) } ?? .null,
            watch.expiresAt.map { .integer(Int64($0)) } ?? .null, watch.conversion.map { .text($0.eventId) } ?? .null,
            watch.conversion.map { .integer(Int64($0.occurredAt)) } ?? .null, watch.serverRevision.map { .integer(Int64($0)) } ?? .null,
            watch.legCompletedAt.map { .integer(Int64($0)) } ?? .null, .integer(Int64(watch.retainUntil))])
    }

    func customerWatches(owner: CustomerStoreOwner) throws -> [String: JourneyConversionWatch] {
        try customerQuery("SELECT journey_id,experience_id,version_id,policy_hash,goal_json,entry_context_json,started_at,basis_event_id,basis_at,expires_at,conversion_event_id,conversion_at,server_revision,leg_completed_at FROM journey_conversion_watches WHERE authority_scope=? AND user_id=?;", ownerValues(owner)) { statement in
            var watches: [String: JourneyConversionWatch] = [:]
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return watches }
                guard code == SQLITE_ROW else { throw CustomerStoreError.invalidRow }
                let id = try rowText(statement, 0)
                let basis: JourneyConversionWatch.Occurrence?
                if let time = optionalInteger(statement, 8) { basis = .init(eventId: try rowText(statement, 7), occurredAt: Int(time)) } else { basis = nil }
                let conversion: JourneyConversionWatch.Occurrence?
                if let time = optionalInteger(statement, 11) { conversion = .init(eventId: try rowText(statement, 10), occurredAt: Int(time)) } else { conversion = nil }
                watches[id] = JourneyConversionWatch(journeyId: id, experienceId: try rowText(statement, 1), versionId: try rowText(statement, 2), policyHash: try rowText(statement, 3),
                    goal: try customerJSON(JourneyConversionWatch.Goal.self, statement, 4), entryContext: try customerJSON(JourneyConversionWatch.EntryContext.self, statement, 5),
                    startedAt: Int(sqlite3_column_int64(statement, 6)), basis: basis, conversion: conversion,
                    serverRevision: optionalInteger(statement, 12).map(Int.init), legCompletedAt: optionalInteger(statement, 13).map(Int.init), expiresAt: optionalInteger(statement, 9).map(Int.init))
            }
        }
    }

    func customerResponseLanes(owner: CustomerStoreOwner) throws -> [CustomerResponseLaneKey: CustomerResponseSaveLane] {
        let keys: [CustomerResponseLaneKey] = try customerQuery("SELECT journey_id,form_name FROM journey_response_saves WHERE authority_scope=? AND user_id=?;", ownerValues(owner)) { statement in
            var keys: [CustomerResponseLaneKey] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return keys }
                guard code == SQLITE_ROW else { throw CustomerStoreError.invalidRow }
                keys.append(.init(journeyId: try rowText(statement, 0), formName: try rowText(statement, 1)))
            }
        }
        var lanes: [CustomerResponseLaneKey: CustomerResponseSaveLane] = [:]
        for key in keys { lanes[key] = try responseSaveLane(owner: owner, journeyId: key.journeyId, formName: key.formName) }
        return lanes
    }

    func customerResponseOwners(scope: JourneyStorageScope) throws -> [String] {
        try customerQuery("SELECT DISTINCT user_id FROM journey_response_saves WHERE authority_scope=? AND pending_sequence IS NOT NULL ORDER BY user_id;", [.text(scope.conversionNamespace)]) { statement in
            var owners: [String] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return owners }
                guard code == SQLITE_ROW else { throw CustomerStoreError.invalidRow }
                owners.append(try rowText(statement, 0))
            }
        }
    }

    func customerReserveResponse(_ key: CustomerJourneyKey, formName: String, answers: ExactJSONObject<JourneyReleaseJSONValue>, queued: Bool) throws -> JourneyResponseSave {
        let journey = try activeJourneys(owner: key.owner).first(where: { $0.journeyId == key.journeyId && Int64($0.generation) == key.legGeneration })
        let previous = try responseSaveLane(owner: key.owner, journeyId: key.journeyId, formName: formName)
        guard let experienceId = journey?.reference.experienceId ?? previous?.experienceId,
              let versionId = journey?.reference.versionId ?? previous?.versionId else { throw JourneyResponseSaveError.wrongOwner }
        let sequence = previous?.sequence ?? 0
        guard sequence < JourneyResponseSave.maximumSequence else { throw JourneyResponseSaveError.sequenceExhausted }
        let sheet = JourneyResponseSave(distinctId: key.owner.userId, journeyId: key.journeyId, experienceId: experienceId,
            experienceVersionId: versionId, formName: formName, sequence: sequence + 1, answers: answers)
        try customerWriteLane(owner: key.owner, journeyId: key.journeyId, formName: formName,
            lane: .init(experienceId: sheet.experienceId, versionId: sheet.experienceVersionId, sequence: sheet.sequence,
                pending: queued ? sheet : previous?.pending, retry: queued ? nil : previous?.retry, display: .saving(sequence: sheet.sequence)))
        return sheet
    }

    func customerResponseReply(owner: CustomerStoreOwner, sheet: JourneyResponseSave, reply: JourneyResponseSaveReply, at now: Date, waiting: Bool) throws -> Bool {
        guard sheet.distinctId.utf8.elementsEqual(owner.userId.utf8), let existing = try responseSaveLane(owner: owner, journeyId: sheet.journeyId, formName: sheet.formName),
              existing.experienceId == sheet.experienceId, sheet.sequence <= existing.sequence else { throw JourneyResponseSaveError.wrongOwner }
        var sequence = existing.sequence, pending = existing.pending, display = existing.display, retry = existing.retry
        var stopped = false
        if reply.confirmed {
            guard let saved = reply.sequence, saved >= sheet.sequence, saved <= JourneyResponseSave.maximumSequence else { throw JourneyResponseSaveError.invalidReceipt }
            sequence = max(sequence, saved)
            if display?.sequence == sheet.sequence { display?.finish(reply) }
            if let current = pending, current.sequence <= sheet.sequence { pending = nil; retry = nil }
        } else if waiting {
            if display?.sequence == sheet.sequence { display?.finish(reply) }
        } else if pending?.sequence == sheet.sequence {
            var value = retry?.domainValue ?? .init(attempts: 0, observedAt: now, nextAttemptAt: now, unknownFormSince: nil, lastCode: reply.code)
            value.normalizeClock(at: now)
            value.attempts = min(64, value.attempts + 1)
            value.observedAt = now
            value.lastCode = reply.code
            if reply.code == .unknownForm, value.unknownFormSince == nil { value.unknownFormSince = now }
            stopped = reply.terminal || (reply.code == .unknownForm && value.unknownFormSince.map { now.timeIntervalSince($0) >= 600 } == true)
            if stopped {
                pending = nil; retry = nil
                if display?.sequence == sheet.sequence { display?.finish(reply) }
            } else {
                value.nextAttemptAt = now.addingTimeInterval(min(300, 5 * pow(2, Double(min(6, value.attempts - 1)))))
                retry = .init(value)
            }
        }
        try customerWriteLane(owner: owner, journeyId: sheet.journeyId, formName: sheet.formName,
            lane: .init(experienceId: existing.experienceId, versionId: existing.versionId, sequence: sequence, pending: pending, retry: retry, display: display))
        return stopped
    }

    func customerWriteLane(owner: CustomerStoreOwner, journeyId: String, formName: String, lane: CustomerResponseSaveLane) throws {
        let retry = lane.retry, display = lane.display
        try customerWrite("""
        INSERT INTO journey_response_saves VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(authority_scope,user_id,journey_id,form_name) DO UPDATE SET
        experience_id=excluded.experience_id,version_id=excluded.version_id,sequence=excluded.sequence,pending_sequence=excluded.pending_sequence,pending_answers_json=excluded.pending_answers_json,
        display_sequence=excluded.display_sequence,saving=excluded.saving,saved=excluded.saved,save_error=excluded.save_error,
        attempts=excluded.attempts,observed_at=excluded.observed_at,next_attempt_at=excluded.next_attempt_at,unknown_form_since=excluded.unknown_form_since,last_code=excluded.last_code;
        """, ownerValues(owner) + [.text(journeyId), .text(formName), .text(lane.experienceId), .text(lane.versionId), .integer(lane.sequence),
            lane.pending.map { .integer($0.sequence) } ?? .null, try lane.pending.map { .blob(try ExactJSONCodec.encode($0.answers)) } ?? .null,
            display.map { .integer($0.sequence) } ?? .null, .integer(display?.saving == true ? 1 : 0), .integer(display?.saved == true ? 1 : 0), .text(display?.saveError ?? ""),
            .integer(retry?.attempts ?? 0), retry.map { .integer($0.observedAt) } ?? .null, retry.map { .integer($0.nextAttemptAt) } ?? .null,
            retry?.unknownFormSince.map(CustomerSQLValue.integer) ?? .null, retry.map { .text($0.lastCode.rawValue) } ?? .null])
    }
}

extension CustomerResponseSaveRetry {
    init(_ value: JourneyResponseSaveRetry) {
        self.init(attempts: Int64(value.attempts), observedAt: Int64(JourneyConversionWatch.millis(value.observedAt)),
            nextAttemptAt: Int64(JourneyConversionWatch.millis(value.nextAttemptAt)), unknownFormSince: value.unknownFormSince.map { Int64(JourneyConversionWatch.millis($0)) }, lastCode: value.lastCode)
    }
    var domainValue: JourneyResponseSaveRetry {
        .init(attempts: Int(attempts), observedAt: JourneyTime.date(observedAt), nextAttemptAt: JourneyTime.date(nextAttemptAt),
            unknownFormSince: unknownFormSince.map(JourneyTime.date), lastCode: lastCode)
    }
}
