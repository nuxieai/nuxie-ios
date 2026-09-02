import Foundation

/// Runs cancellation-aware retries with bounded exponential delay. Callers
/// report progress so ordered queues can reset latency after draining work.
struct CancellationAwareExponentialRetryLoop: Sendable {
    enum IterationResult: Sendable {
        case finished
        case madeProgress
        case pending
    }

    private let initialDelayNanoseconds: UInt64
    private let maximumDelayNanoseconds: UInt64

    init(
        initialDelayNanoseconds: UInt64,
        maximumDelayNanoseconds: UInt64
    ) {
        let initial = max(initialDelayNanoseconds, 1)
        self.initialDelayNanoseconds = initial
        self.maximumDelayNanoseconds = max(maximumDelayNanoseconds, initial)
    }

    func run(
        _ iteration: () async -> IterationResult
    ) async {
        var delay = initialDelayNanoseconds
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            switch await iteration() {
            case .finished:
                return
            case .madeProgress:
                delay = initialDelayNanoseconds
            case .pending:
                let (doubled, overflowed) = delay.multipliedReportingOverflow(
                    by: 2
                )
                delay = overflowed
                    ? maximumDelayNanoseconds
                    : min(doubled, maximumDelayNanoseconds)
            }
        }
    }
}
