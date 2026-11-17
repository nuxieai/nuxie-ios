#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation

/// Where the edge performs the machine's `call` rows that a store answers.
package protocol NuxieMachineStore: Sendable {
    /// Perform `call` and give the name of its extern's outcome. A call the
    /// store cannot perform throws, and the edge faults.
    func perform(_ call: NuxieMachineCall) async throws -> String
}

/// A call no store here can perform.
package enum NuxieMachineStoreFault: Error, Equatable, Sendable {
    case unknownExtern(String)
}

/// STAND-IN for a store. It buys nothing and talks to no store: it answers
/// `purchase` with `failed`, and any other extern with a fault. `failed`
/// keeps the slice to one Screen, because `completed` goes to a route this
/// slice draws no artwork for. A real store replaces it in a later slice.
package struct NuxieMachineStandInStore: NuxieMachineStore {
    package init() {}

    package func perform(_ call: NuxieMachineCall) async throws -> String {
        guard call.externName == "purchase" else {
            throw NuxieMachineStoreFault.unknownExtern(call.externName)
        }
        return "failed"
    }
}
#endif
