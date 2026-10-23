import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

extension CustomerJourneyStore {
    func reports() async throws -> [StoredEvent] {
        var rows: [StoredEvent] = []
        var after: CustomerLogPosition?
        while true {
            let page = try await store.customerLogPage(owner: owner, name: JourneyEvents.journeyCompleted,
                startedAt: Int64.min, deadlineAt: nil, after: after, limit: 128)
            guard let last = page.last else { return rows }
            rows += page
            after = .init(milliseconds: Int64(JourneyConversionWatch.millis(last.timestamp)), eventId: last.id)
        }
    }

    func checkmark(experienceId: String) async throws -> JourneyCheckmark? {
        guard let report = try await reports().last(where: { $0.getPropertiesDict()["experience_id"] as? String == experienceId }) else { return nil }
        let properties = report.getPropertiesDict()
        return .init(journeyId: properties["journey_id"] as? String ?? "", generation: properties["leg_generation"] as? Int ?? 0,
            outcome: properties["outcome"] as? String ?? "", completedAt: report.timestamp,
            lastEnrollmentAt: try await store.customerFrequency(owner: owner, experienceId: experienceId).map(JourneyTime.date),
            reentry: .init(type: .everyMatch, window: nil), lastSeenLiveAt: report.timestamp)
    }

    func loggedInput(named name: String, since: Date = .distantPast) async throws -> StoredEvent? {
        try await store.customerLogPage(owner: owner, name: name, startedAt: Int64(JourneyConversionWatch.millis(since)),
            deadlineAt: nil, after: nil, limit: 1).first
    }

    func captureFixtureInput(id: String, name: String, at: Date, properties: [String: Any] = [:], journeyOrigin: JourneyEventOrigin? = nil) async throws {
        guard let sqlite = store as? SQLiteEventStore else { throw CustomerStoreError.invalidRow }
        _ = try await sqlite.insert(StoredEvent(id: id, name: name, properties: properties, timestamp: at, distinctId: distinctId, journeyOrigin: journeyOrigin))
    }
}

extension JourneyService {
    func handleStoredEvent(_ event: NuxieEvent) async {
        _ = await handleStoredEvent(event, admittedProfileGeneration: eventAdmissionGeneration())
    }

    @discardableResult
    func handleStoredEvent(_ event: NuxieEvent, admittedProfileGeneration: UInt64?) async -> Bool {
        do {
            if let customer = storeForTesting() {
                try await customer.captureFixtureInput(id: event.id, name: event.name, at: event.timestamp, properties: event.properties, journeyOrigin: event.journeyOrigin)
            }
        } catch { return false }
        return await handleEvent(event, admittedProfileGeneration: admittedProfileGeneration)
    }
}

struct CustomerTerminalObservation: Decodable {
    let journeyId: String
    let generation: Int
    let outcome: String
    let outputs: ArmedJourney.Context
    let at: Date
    var id: String { "\(journeyId):\(generation)" }

    init(_ event: StoredEvent) throws {
        struct Wire: Decodable {
            let journey_id: String
            let leg_generation: Int
            let outcome: String
            let outputs: ArmedJourney.Context
        }
        let wire = try ExactJSONCodec.decode(Wire.self, from: event.properties)
        journeyId = wire.journey_id
        generation = wire.leg_generation
        outcome = wire.outcome
        outputs = wire.outputs
        at = event.timestamp
    }
}

extension CustomerJourneyStore {
    func terminalRecords() async throws -> [CustomerTerminalObservation] { try await reports().map(CustomerTerminalObservation.init) }
}

struct JourneyCheckmark {
    let journeyId: String
    let generation: Int
    let outcome: String
    let completedAt: Date
    /// Reentry counts new journeys, not completion time or continuation legs.
    let lastEnrollmentAt: Date?
    let reentry: Journey.Frequency
    let lastSeenLiveAt: Date

    init(
        journeyId: String,
        generation: Int,
        outcome: String,
        completedAt: Date,
        lastEnrollmentAt: Date?,
        reentry: Journey.Frequency,
        lastSeenLiveAt: Date
    ) {
        self.journeyId = journeyId
        self.generation = generation
        self.outcome = outcome
        self.completedAt = completedAt
        self.lastEnrollmentAt = lastEnrollmentAt
        self.reentry = reentry
        self.lastSeenLiveAt = lastSeenLiveAt
    }
}


extension JourneyCheckmark: Sendable {}
