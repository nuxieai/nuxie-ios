import Foundation

/// Resolves the authenticated action vocabulary to generic native commands.
struct JourneyVideoAction: Sendable {
    let artboardId: String
    let viewNodeId: String
    let commandKind: UInt32
    let commandValue: Double

    init(action: [String: JourneyReleaseJSONValue]) throws {
        let data = try JSONEncoder().encode(action)
        let raw = try JSONSerialization.jsonObject(with: data)
        try JourneyReleaseSchemaPrimitives.validateCanonicalJourneyAction(
            raw, path: "video", screenIDs: [], placementIDs: [])
        guard case .string("video")? = action["type"],
              case .object(let target)? = action["target"],
              case .string(let artboard)? = target["artboardId"],
              case .string(let view)? = target["viewNodeId"],
              case .object(let command)? = action["command"],
              case .string(let type)? = command["type"] else {
            throw ExperienceInteractiveScreenError.stateContract("invalid video command")
        }
        artboardId = artboard
        viewNodeId = view
        switch type {
        case "play": commandKind = 0; commandValue = 0
        case "pause": commandKind = 1; commandValue = 0
        case "seek", "rate", "volume":
            let field = type == "seek" ? "seconds" : type
            guard case .number(let value)? = command[field] else {
                throw ExperienceInteractiveScreenError.stateContract("invalid video command value")
            }
            commandKind = type == "seek" ? 2 : type == "rate" ? 3 : 4
            commandValue = value
        case "mute", "loop":
            guard case .bool(let value)? = command[type == "mute" ? "muted" : "enabled"] else {
                throw ExperienceInteractiveScreenError.stateContract("invalid video command flag")
            }
            commandKind = type == "mute" ? 5 : 9
            commandValue = value ? 1 : 0
        default:
            throw ExperienceInteractiveScreenError.stateContract("unsupported video command")
        }
    }
}
