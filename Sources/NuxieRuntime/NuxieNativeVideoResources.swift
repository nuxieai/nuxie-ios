#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
/// Host-selected workload limits; platform-managed decoding does not assert hardware use.
package struct NuxieNativeVideoDecoderBudget: Sendable {
    package let maxPlayers: UInt32
    package let managedPlayers: UInt32
    package let hardwarePlayers: UInt32
    package let managedPixelsPerSecond: UInt64
    package let softwarePixelsPerSecond: UInt64

    package init(maxPlayers: UInt32, managedPlayers: UInt32, hardwarePlayers: UInt32,
        managedPixelsPerSecond: UInt64, softwarePixelsPerSecond: UInt64) {
        self.maxPlayers = maxPlayers
        self.managedPlayers = managedPlayers
        self.hardwarePlayers = hardwarePlayers
        self.managedPixelsPerSecond = managedPixelsPerSecond
        self.softwarePixelsPerSecond = softwarePixelsPerSecond
    }
}

package struct NuxieNativeVideoDecoderRequest: Sendable {
    package let id: UInt64
    package let pixelsPerSecond: UInt64
    package let priority: UInt32
    let flags: UInt32

    package init(id: UInt64, pixelsPerSecond: UInt64, priority: UInt32, visible: Bool,
        hardwareSupported: Bool = false, softwareSupported: Bool = false, managedSupported: Bool = true) {
        self.id = id
        self.pixelsPerSecond = pixelsPerSecond
        self.priority = priority
        flags = (visible ? 1 : 0) | (hardwareSupported ? 2 : 0) |
            (softwareSupported ? 4 : 0) | (managedSupported ? 8 : 0)
    }
}

package enum NuxieNativeVideoAllocation: UInt32, Sendable {
    case hardware = 0, software = 1, poster = 2, platformManaged = 3
}
#endif
