#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import XCTest
@testable import Nuxie

final class JourneyScreenEmissionSequenceLaneTests: XCTestCase {
    func testLaterBatchWaitsForItsCommittedPredecessor() async {
        let lane = JourneyScreenEmissionSequenceLane()
        let trace = ScreenEmissionLaneTrace()

        async let later = lane.submit(
            batch(sequence: 1, previous: 0),
            durableLastProcessedSequence: nil,
            durableResult: nil,
            process: {
                await trace.append(1)
                return Self.drained(sequence: 1)
            },
            reject: { Self.rejected(sequence: 1) }
        )
        await Task.yield()
        let traceBeforePredecessor = await trace.values()
        XCTAssertEqual(traceBeforePredecessor, [])
        async let earlier = lane.submit(
            batch(sequence: 0, previous: nil),
            durableLastProcessedSequence: nil,
            durableResult: nil,
            process: {
                await trace.append(0)
                return Self.drained(sequence: 0)
            },
            reject: { Self.rejected(sequence: 0) }
        )

        let earlierResult = await earlier
        let laterResult = await later
        let finalTrace = await trace.values()
        XCTAssertEqual(earlierResult, Self.drained(sequence: 0))
        XCTAssertEqual(laterResult, Self.drained(sequence: 1))
        XCTAssertEqual(finalTrace, [0, 1])
    }

    func testDurableReplayReturnsReceiptWithoutExecutingEffects() async {
        let lane = JourneyScreenEmissionSequenceLane()
        let trace = ScreenEmissionLaneTrace()
        let recovered = Self.drained(sequence: 0)

        let result = await lane.submit(
            batch(sequence: 0, previous: nil),
            durableLastProcessedSequence: 0,
            durableResult: recovered,
            process: {
                await trace.append(0)
                return recovered
            },
            reject: { Self.rejected(sequence: 0) }
        )

        XCTAssertEqual(result, recovered)
        let replayTrace = await trace.values()
        XCTAssertEqual(replayTrace, [])
    }

    func testDuplicateInvocationJoinsInFlightBatch() async {
        let lane = JourneyScreenEmissionSequenceLane()
        let gate = ScreenEmissionLaneGate()
        let input = batch(sequence: 0, previous: nil)

        async let original = lane.submit(
            input,
            durableLastProcessedSequence: nil,
            durableResult: nil,
            process: {
                await gate.suspend()
                return Self.drained(sequence: 0)
            },
            reject: { Self.rejected(sequence: 0) }
        )
        await gate.waitUntilEntered()
        async let replay = lane.submit(
            input,
            durableLastProcessedSequence: nil,
            durableResult: nil,
            process: { Self.rejected(sequence: 0) },
            reject: { Self.rejected(sequence: 0) }
        )
        await gate.release()

        let originalResult = await original
        let replayResult = await replay
        XCTAssertEqual(originalResult, Self.drained(sequence: 0))
        XCTAssertEqual(replayResult, Self.drained(sequence: 0))
    }

    private func batch(sequence: UInt64, previous: UInt64?) -> ScreenEmissionBatch {
        ScreenEmissionBatch(
            journeyId: "journey-1",
            executionOwnershipEpoch: 1,
            lifecycleGeneration: 2,
            presentationEpoch: 3,
            batchSequence: sequence,
            previousCommittedBatchSequence: previous,
            invocationId: "invocation-\(sequence)",
            source: ScreenEmissionSource(
                screenId: "screen-1",
                actionId: "submit",
                componentId: nil,
                instanceId: nil
            ),
            emissions: [ScreenEmission(
                id: "emission-\(sequence)",
                sequence: sequence,
                occurredAt: "2026-08-27T12:00:00Z",
                name: "submitted",
                payload: [:]
            )]
        )
    }

    private static func drained(sequence: UInt64) -> JourneyScreenEmissionDrainResult {
        JourneyScreenEmissionDrainResult(
            status: .drained,
            acceptedEmissionIds: ["emission-\(sequence)"],
            skippedEmissionIds: [],
            reason: nil
        )
    }

    private static func rejected(sequence: UInt64) -> JourneyScreenEmissionDrainResult {
        JourneyScreenEmissionDrainResult(
            status: .rejected,
            acceptedEmissionIds: [],
            skippedEmissionIds: ["emission-\(sequence)"],
            reason: .batchSequenceOutOfOrder
        )
    }
}

private actor ScreenEmissionLaneTrace {
    private var entries: [UInt64] = []

    func append(_ value: UInt64) {
        entries.append(value)
    }

    func values() -> [UInt64] {
        entries
    }
}

private actor ScreenEmissionLaneGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
#endif
