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
}

struct JourneyResponseSaveState: Codable, Sendable {
    let namespace: String
    let distinctId: String
    var journeys: ExactJSONObject<ExactJSONObject<JourneyResponseSaveLane>> = [:]
}
