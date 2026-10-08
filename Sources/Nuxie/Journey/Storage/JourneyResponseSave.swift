import Foundation

struct JourneyResponseSave: Codable, Sendable, Equatable {
    static let maximumSequence: Int64 = 9_007_199_254_740_991

    let distinctId: String
    let journeyId: String
    let experienceId: String
    let experienceVersionId: String
    let formName: String
    let sequence: Int64
    let answers: ExactJSONObject<JourneyReleaseJSONValue>

    enum CodingKeys: String, CodingKey {
        case distinctId = "distinct_id"
        case journeyId = "journey_id"
        case experienceId = "experience_id"
        case experienceVersionId = "experience_version_id"
        case formName = "form_name"
        case sequence, answers
    }
}

enum JourneyResponseSaveError: Error {
    case sequenceExhausted
    case invalidReceipt
    case wrongOwner
}

struct JourneyResponseSaveLane: Codable, Sendable {
    var sequence: Int64 = 0
    var pending: JourneyResponseSave?
    var retry: JourneyResponseSaveRetry?
    var display: JourneyResponseSaveDisplay?
}

/// Durable UI metadata only. Answer values remain in the native run instance.
struct JourneyResponseSaveDisplay: Codable, Sendable, Equatable {
    let sequence: Int64
    var saving: Bool
    var saved: Bool
    var saveError: String

    static func saving(sequence: Int64) -> Self {
        .init(sequence: sequence, saving: true, saved: false, saveError: "")
    }

    mutating func finish(_ reply: JourneyResponseSaveReply) {
        saving = false
        saved = reply.confirmed
        saveError = reply.confirmed ? "" : reply.code.rawValue
    }
}

struct JourneyResponseSaveState: Codable, Sendable {
    let namespace: String
    let distinctId: String
    var journeys: ExactJSONObject<ExactJSONObject<JourneyResponseSaveLane>> = [:]
}

struct JourneyResponseSaveRetry: Codable, Sendable {
    var attempts: Int
    var observedAt: Date
    var nextAttemptAt: Date
    var unknownFormSince: Date?
    var lastCode: JourneyResponseSaveReply.Code

    mutating func normalizeClock(at now: Date) {
        guard now < observedAt else { return }
        let shift = now.timeIntervalSince(observedAt)
        nextAttemptAt = nextAttemptAt.addingTimeInterval(shift)
        unknownFormSince = unknownFormSince?.addingTimeInterval(shift)
        observedAt = now
    }
}

struct JourneyResponseSaveAttempt: Sendable {
    let sheet: JourneyResponseSave
    let retry: JourneyResponseSaveRetry?

    func delay(at now: Date) -> TimeInterval {
        max(0, retry?.nextAttemptAt.timeIntervalSince(now) ?? 0)
    }

    func unknownFormExpired(at now: Date) -> Bool {
        retry?.lastCode == .unknownForm && retry?.unknownFormSince.map {
            now.timeIntervalSince($0) >= 600
        } == true
    }
}

struct JourneyResponseSaveReply: Sendable {
    enum Code: String, Codable, Sendable {
        case saved, replayed, stale
        case mergeInProgress = "merge_in_progress"
        case customerUnavailable = "customer_unavailable"
        case customerRedirectLoop = "customer_redirect_loop"
        case saveUnavailable = "save_unavailable"
        case unknownForm = "unknown_form"
        case invalidRequest = "invalid_request"
        case authenticationFailed = "authentication_failed"
        case unknownExperienceVersion = "unknown_experience_version"
        case pinnedVersionMismatch = "pinned_version_mismatch"
        case sequenceConflict = "sequence_conflict"
        case customerDeleted = "customer_deleted"
        case noAnswer = "no_answer"
    }

    let code: Code
    let sequence: Int64?
    static let noAnswer = Self(code: .noAnswer, sequence: nil)

    var confirmed: Bool { code == .saved || code == .replayed || code == .stale }
    var terminal: Bool {
        switch code {
        case .invalidRequest, .authenticationFailed, .unknownExperienceVersion,
             .pinnedVersionMismatch, .sequenceConflict, .customerDeleted: return true
        default: return false
        }
    }

    static func decode(_ data: Data, attemptedSequence: Int64) -> Self {
        struct Status: Decodable { let status: String }
        struct Refusal: Decodable { let code: String }
        struct Receipt: Decodable { let sequence: Int64 }
        guard let status = try? ExactJSONCodec.decode(Status.self, from: data) else { return .noAnswer }
        if status.status == "error" {
            guard let refusal = try? ExactJSONCodec.decode(Refusal.self, from: data),
                  let code = Code(rawValue: refusal.code),
                  code != .saved, code != .replayed, code != .stale, code != .noAnswer else { return .noAnswer }
            return Self(code: code, sequence: nil)
        }
        guard let code = Code(rawValue: status.status), [.saved, .replayed, .stale].contains(code),
              let receipt = try? ExactJSONCodec.decode(Receipt.self, from: data),
              receipt.sequence >= attemptedSequence, receipt.sequence > 0,
              receipt.sequence <= JourneyResponseSave.maximumSequence else { return .noAnswer }
        return Self(code: code, sequence: receipt.sequence)
    }
}

protocol JourneyResponseSaveTransport: Sendable {
    func sendResponseSave(_ sheet: JourneyResponseSave) async throws -> JourneyResponseSaveReply
}

extension JourneyResponseSave {
    func encodedForTransport(apiKey: String) throws -> Data {
        let body: ExactJSONObject<JourneyReleaseJSONValue> = [
            "apiKey": .string(apiKey), "distinct_id": .string(distinctId),
            "journey_id": .string(journeyId), "experience_id": .string(experienceId),
            "experience_version_id": .string(experienceVersionId), "form_name": .string(formName),
            "sequence": .number(Double(sequence)), "answers": .object(answers),
        ]
        return try ExactJSONCodec.encode(body)
    }
}

struct JourneyResponseSaveRecovery: Sendable {
    let owners: [String]
    let needsRetry: Bool
}
