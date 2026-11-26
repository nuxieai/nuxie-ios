#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation

/// Where the edge gets the bytes of a file of the Experience's folder that
/// a view shows, as a store is where it performs a call: a host seam the
/// edge asks, and that answers later. The edge asks by the file's path in
/// the folder, the path the host's row named ([`NuxieMachineAsset`]), each
/// time it opens a presentation that shows the file, and imports nothing
/// until every one has answered. It builds no address and holds no
/// connection: where the bytes come from is the source's.
package protocol NuxieMachineByteSource: Sendable {
    /// The bytes of the file at `path` in the Experience's folder
    /// (`assets/hero.png`). A source that has none for it throws, and the
    /// edge stops with `edge.unsupplied-asset`, naming the path.
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
