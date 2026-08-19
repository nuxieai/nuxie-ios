import CryptoKit
import Foundation

/// The only timezone authority used by Journey v2 time windows.
///
/// This is deliberately a small, signed-at-build-time projection of the pinned
/// IANA database. Foundation/ICU timezone rules are never consulted for route
/// evaluation.
struct SignedJourneyTimezone: Equatable, Sendable {
    let identifier: String
    let bundle: SignedTimezoneBundle

    static func == (lhs: SignedJourneyTimezone, rhs: SignedJourneyTimezone) -> Bool {
        lhs.identifier == rhs.identifier
    }
}

struct SignedTimezoneBundle: Sendable {
    static let revision = "2026c"
    static let sha256 = "d4ad5c12a6be491076f333c9b4f96f60cb8ab552495bbfae0d8cdc9730ecb198"

    private struct Transition: Decodable, Sendable {
        let atMilliseconds: Int64
        let offsetSeconds: Int

        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            guard !values.isAtEnd else { throw DecodingError.dataCorruptedError(in: values, debugDescription: "empty timezone transition") }
            atMilliseconds = try values.decode(Int64.self)
            offsetSeconds = try values.decode(Int.self)
            guard values.isAtEnd else { throw DecodingError.dataCorruptedError(in: values, debugDescription: "extra timezone transition values") }
        }
    }

    private struct Zone: Decodable, Sendable {
        let initialOffsetSeconds: Int
        let transitions: [Transition]
    }

    private struct Resource: Decodable, Sendable {
        let format: String
        let revision: String
        let sourceSha256: String
        let startYear: Int
        let endYear: Int
        let aliases: [String: String]
        let zones: [String: Zone]
    }

    private let resource: Resource

    static let installed: SignedTimezoneBundle? = try? load()

    static func load(bundle: Bundle = resourceBundle) throws -> SignedTimezoneBundle {
        guard let url = bundle.url(forResource: "timezone-bundle", withExtension: "json") else {
            throw Error.resourceMissing
        }
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw Error.digestMismatch }
        let resource = try JSONDecoder().decode(Resource.self, from: data)
        guard resource.format == "iana-tzdb", resource.revision == revision,
              resource.startYear < resource.endYear,
              !resource.zones.isEmpty else { throw Error.invalidResource }
        return SignedTimezoneBundle(resource: resource)
    }

    private init(resource: Resource) {
        self.resource = resource
    }

    enum Error: Swift.Error, Equatable {
        case resourceMissing
        case digestMismatch
        case invalidResource
        case unknownTimezone
        case outOfRange
    }

    func resolve(_ identifier: String) throws -> SignedJourneyTimezone {
        guard !identifier.isEmpty, resource.zones[identifier] != nil,
              resource.aliases[identifier] == nil else { throw Error.unknownTimezone }
        return SignedJourneyTimezone(identifier: identifier, bundle: self)
    }

    /// Device identifiers are chosen by the OS, so resolve the bundle's pinned
    /// link table before applying canonical Journey semantics.
    func resolveDeviceIdentifier(_ identifier: String) throws -> SignedJourneyTimezone {
        try resolve(resource.aliases[identifier] ?? identifier)
    }

    func offsetSeconds(for timezone: SignedJourneyTimezone, at date: Date) throws -> Int {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = utc.component(.year, from: date)
        guard (resource.startYear...resource.endYear).contains(year),
              let zone = resource.zones[timezone.identifier] else { throw Error.outOfRange }
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded(.towardZero))
        var low = 0
        var high = zone.transitions.count
        while low < high {
            let mid = (low + high) / 2
            if zone.transitions[mid].atMilliseconds <= milliseconds { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? zone.initialOffsetSeconds : zone.transitions[low - 1].offsetSeconds
    }

    func nearbyOffsets(for timezone: SignedJourneyTimezone, around date: Date) -> [Int] {
        guard let zone = resource.zones[timezone.identifier] else { return [] }
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded(.towardZero))
        var offsets = Set([zone.initialOffsetSeconds])
        if let current = try? offsetSeconds(for: timezone, at: date) {
            offsets.insert(current)
        }
        for transition in zone.transitions {
            if abs(transition.atMilliseconds - milliseconds) <= 172_800_000 { offsets.insert(transition.offsetSeconds) }
        }
        return Array(offsets)
    }
}

#if SWIFT_PACKAGE
private let resourceBundle = Bundle.module
#else
private let resourceBundle = Bundle(for: ResourceToken.self)
#endif

private final class ResourceToken {}
