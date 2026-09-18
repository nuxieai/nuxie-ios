#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import NuxieRuntime

/// Shared by playback owners. Selection may revoke a decoder, but its capacity
/// remains reserved until the owner acknowledges disposal with `release`.
@MainActor
final class ExperienceVideoDecoderPool {
    struct Request {
        let pixelsPerSecond: UInt64
        let priority: UInt32
        let visible: Bool
    }

    private struct Key: Hashable {
        let owner: UUID
        let componentID: Int
    }
    private struct Entry {
        let id: UInt64
        var request: Request
    }
    private let budget: () -> NuxieNativeVideoDecoderBudget
    private var nextID: UInt64 = 0
    private var entries: [Key: Entry] = [:]
    private var claims: [Key: UInt64] = [:]

    init(budget: @escaping () -> NuxieNativeVideoDecoderBudget) {
        self.budget = budget
    }

    /// Replaces one owner's demand and reserves admissions against *all* live
    /// claims. An owner must dispose denied or removed decoders before release.
    func update(owner: UUID, requests: [Int: Request]) throws -> Set<Int> {
        let limits = budget()
        entries = entries.filter { $0.key.owner != owner || requests[$0.key.componentID] != nil }
        for componentID in requests.keys.sorted() {
            let key = Key(owner: owner, componentID: componentID)
            guard let request = requests[componentID] else { continue }
            if var entry = entries[key] {
                entry.request = request
                entries[key] = entry
            } else {
                guard nextID < UInt64.max else {
                    throw ExperienceInteractiveScreenError.stateContract("video decoder identity exhausted")
                }
                entries[key] = Entry(id: nextID, request: request)
                nextID += 1
            }
        }
        let ordered = entries.sorted { $0.value.id < $1.value.id }
        let choices = try NuxieNativeRuntime.allocateVideoDecoders(ordered.map { _, entry in
            NuxieNativeVideoDecoderRequest(id: entry.id, pixelsPerSecond: entry.request.pixelsPerSecond,
                priority: entry.request.priority, visible: entry.request.visible)
        }, budget: limits)
        let selected = Set(zip(ordered, choices).compactMap { pair, choice in
            choice == .platformManaged ? pair.key : nil
        })
        var admitted: Set<Int> = []
        for (key, entry) in ordered where key.owner == owner && selected.contains(key) {
            // A changed cost must first retire the old decoder/reservation.
            if let held = claims[key] {
                if held == entry.request.pixelsPerSecond { admitted.insert(key.componentID) }
                continue
            }
            let playerLimit = min(limits.maxPlayers, limits.managedPlayers)
            guard claims.count < Int(playerLimit) else { continue }
            var available = limits.managedPixelsPerSecond
            for cost in claims.values { available = cost > available ? 0 : available - cost }
            guard entry.request.pixelsPerSecond <= available else { continue }
            claims[key] = entry.request.pixelsPerSecond
            admitted.insert(key.componentID)
        }
        return admitted
    }

    /// Call only after the actual decoder has relinquished its media resources.
    func release(owner: UUID, componentID: Int) {
        claims.removeValue(forKey: Key(owner: owner, componentID: componentID))
    }

    /// Call only after every decoder belonging to the owner is disposed.
    func remove(owner: UUID) {
        entries = entries.filter { $0.key.owner != owner }
        claims = claims.filter { $0.key.owner != owner }
    }
}
#endif
