/// Renderer controls that update a Journey's buffered response outputs.
/// These names never enter EventLog and are therefore not system events.
enum JourneyResponseControlNames {
    static let responseSet = "$response_set"
    static let responseUnset = "$response_unset"
}
