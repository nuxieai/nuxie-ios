#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation

/// Where the edge gets the bytes of a file of the Experience's folder that
/// a view shows, as a store is where it performs a call: a host seam the
/// edge asks, and that answers later. The edge asks by the file's path in
/// the folder, the path the host's row named ([`NuxieMachineAsset`]), once
/// at the start for each file the views draw, and again for a file that
/// failed when the person tries again. It opens no page until every one has
/// answered with bytes. It builds no address and holds no connection: where
/// the bytes come from is the source's.
package protocol NuxieMachineByteSource: Sendable {
    /// The bytes of the file at `path` in the Experience's folder
    /// (`assets/hero.png`). A source that has none for it throws: the path
    /// is failed, and a page that draws it shows the recovery screen. A
    /// `URLError` that says the device is offline reads as offline there;
    /// anything else reads as unavailable.
    func bytes(for path: String) async throws -> Data
}

/// Why a byte source gave no bytes.
package enum NuxieMachineByteSourceFault: Error, Equatable, Sendable {
    /// No file of the folder is at this path.
    case noFile(String)
    /// The path names no file inside the folder: a part of it is empty,
    /// `.` or `..`.
    case outsideFolder(String)
}

/// STAND-IN for a byte source: reads each file from a folder on this
/// device, at its path inside `folder`.
package struct NuxieMachineFolderByteSource: NuxieMachineByteSource {
    package let folder: URL

    package init(folder: URL) {
        self.folder = folder
    }

    package func bytes(for path: String) async throws -> Data {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw NuxieMachineByteSourceFault.outsideFolder(path)
        }
        let file = parts.reduce(folder) { $0.appendingPathComponent($1) }
        do {
            return try Data(contentsOf: file)
        } catch {
            throw NuxieMachineByteSourceFault.noFile(path)
        }
    }
}
#endif
