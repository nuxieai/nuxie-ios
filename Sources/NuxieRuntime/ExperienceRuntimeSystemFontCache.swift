import Foundation

/// Process-local cache of fonts accepted by configured native import. Pending
/// extractions are never entries; identical variable-font bytes share storage.
package final class ExperienceRuntimeSystemFontCache: @unchecked Sendable {
    package static let shared = ExperienceRuntimeSystemFontCache()

    package struct Lease: Sendable {
        package let requestIdentity: String
        package let candidate: ExperienceRuntimeSystemFontProvider.Candidate
    }

    private let lock = NSLock()
    private let maximumBytes: Int
    private var entries: [String: ExperienceRuntimeSystemFontProvider.Candidate] = [:]
    private var order: [String] = []

    package init(maximumBytes: Int = 32 * 1_024 * 1_024) {
        self.maximumBytes = max(0, maximumBytes)
    }

    package func prepare(weight: String, style: String) throws -> Lease {
        let identity = try ExperienceRuntimeSystemFontProvider.requestIdentity(weight: weight, style: style)
        return try candidate(for: identity) {
            try ExperienceRuntimeSystemFontProvider.prepare(weight: weight, style: style)
        }
    }

    package func candidate(
        for identity: String,
        extract: () throws -> ExperienceRuntimeSystemFontProvider.Candidate
    ) rethrows -> Lease {
        lock.lock()
        let cached = entries[identity]
        if cached != nil {
            order.removeAll { $0 == identity }
            order.append(identity)
        }
        lock.unlock()
        return Lease(requestIdentity: identity, candidate: try cached ?? extract())
    }

    package func didImport(_ leases: [Lease]) {
        lock.lock()
        defer { lock.unlock() }
        for lease in leases {
            let candidate = lease.candidate
            guard candidate.bytes.count <= maximumBytes else { continue }
            let sharedBytes = entries.values.first { $0.contentSHA256 == candidate.contentSHA256 }?.bytes
            entries[lease.requestIdentity] = .init(
                bytes: sharedBytes ?? candidate.bytes, sourceIdentity: candidate.sourceIdentity,
                contentSHA256: candidate.contentSHA256, extraction: candidate.extraction
            )
            order.removeAll { $0 == lease.requestIdentity }
            order.append(lease.requestIdentity)
        }
        while (retainedByteCount > maximumBytes || entries.count > 32), let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    package func didFailImport(_ leases: [Lease]) {
        let rejectedDigests = Set(leases.map { $0.candidate.contentSHA256 })
        lock.lock()
        defer { lock.unlock() }
        // Also discard aliases to the same bytes. A delayed failure for an old
        // revision must not remove a newer entry with different content.
        entries = entries.filter { !rejectedDigests.contains($0.value.contentSHA256) }
        order.removeAll { entries[$0] == nil }
    }

    private var retainedByteCount: Int {
        var digests = Set<String>()
        return entries.values.reduce(0) { count, candidate in
            count + (digests.insert(candidate.contentSHA256).inserted ? candidate.bytes.count : 0)
        }
    }
}
