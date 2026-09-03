import Foundation

/// The one compatibility declaration for the embedded native runtime and the
/// publisher backend that produces its Rive/Luau inputs. Descriptor admission
/// consumes this authority instead of maintaining a second set of literals.
package enum NuxieEmbeddedRuntimeCompatibility {
    package static let sourceRevision = "753fcb19fc1d6219cabbd95a7694ca1d13ae2bd8"
    package static let luauRevision = "rive_0_36"
    package static let luauBytecodeVersions: Set<Int> = [3, 6]
    package static let sceneFormatMajor = 7
    package static let sceneFormatMinor = 3
    package static let capabilities: Set<String> = ["rive", "text-input"]
}
