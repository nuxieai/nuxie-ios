#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation

/// Where the edge performs the machine's `call` rows that a store answers.
package protocol NuxieMachineStore: Sendable {
    /// Perform `call` and give its reply: the fields of its declaration's
    /// answer type, or the failure the store met before it could answer,
    /// with its code, reason and message. A call the store cannot perform
    /// throws, and the edge faults. The edge runs this in a task of its own
    /// and never waits for it inside a delivery; the reply is delivered at
    /// the next frame after it arrives.
    func perform(_ call: NuxieMachineCall) async throws -> NuxieMachineReply
}

/// A call no store here can perform.
package enum NuxieMachineStoreFault: Error, Equatable, Sendable {
    case unknownExtern(String)
}

/// The `status` of `nuxie/store`'s `Purchase`, the answer of `purchase` and
/// `restore`.
package enum NuxieMachinePurchaseStatus: String, Sendable {
    case completed, cancelled, failed, pending
}

extension NuxieMachineReply {
    /// A `Purchase` with this status: its one field, the enum value by name.
    package static func purchase(_ status: NuxieMachinePurchaseStatus) -> NuxieMachineReply {
        .answer([.enumeration(status.rawValue)])
    }
}

/// STAND-IN for a store. It buys nothing and talks to no store: it answers
/// `purchase` with a `Purchase` whose status is `failed`, and any other
/// extern with a fault. A real store replaces it in a later slice.
package struct NuxieMachineStandInStore: NuxieMachineStore {
    package init() {}

    package func perform(_ call: NuxieMachineCall) async throws -> NuxieMachineReply {
        guard call.externName == "purchase" else {
            throw NuxieMachineStoreFault.unknownExtern(call.externName)
        }
        return .purchase(.failed)
    }
}
#endif
