import Foundation
import NuxieMachine

/// An Experience's folder as the host app bundles it: the rows of the
/// files in it that are not `.nux` sources, and a byte source over it.
/// The rows are facts the host reads from the files themselves, never
/// their bytes: each file's path inside the folder, its kind by its name,
/// its size in bytes, and a PNG's size in pixels from its header.
struct NuxieMachineFolder {
    struct Missing: Error, CustomStringConvertible {
        let name: String
        var description: String { "\(name)/ is not in the app bundle" }
    }

    let url: URL

    init(named name: String, in bundle: Bundle) throws {
        guard let url = bundle.url(forResource: name, withExtension: nil) else { throw Missing(name: name) }
        self.url = url
    }

    /// Where the edge gets the bytes of the folder's files a view shows.
    var bytes: NuxieMachineFolderByteSource {
        NuxieMachineFolderByteSource(folder: url)
    }

    /// Every file under the folder, in the folders under it too, that is
    /// not a `.nux` file, by its path inside the folder with `/` between
    /// its parts, in the order of those paths. A symbolic link is passed
    /// over, so nothing outside the folder is listed.
    func assets() throws -> [NuxieMachineAsset] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let base = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard let found = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            throw Missing(name: url.lastPathComponent)
        }
        var rows: [NuxieMachineAsset] = []
        for case let file as URL in found {
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true, file.pathExtension != "nux"
            else { continue }
            let parts = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard parts.starts(with: base) else { continue }
            let path = parts.dropFirst(base.count).joined(separator: "/")
            rows.append(NuxieMachineAsset(path: path, kind: try Self.kind(of: file),
                                          byteCount: UInt64(values.fileSize ?? 0)))
        }
        return rows.sorted { $0.path < $1.path }
    }

    /// A file's kind by its name: a picture when it is named as one and
    /// its header gives its size (read here for a PNG only, so a JPEG or a
    /// WebP file is listed as another file), a font for a TTF or OTF file,
    /// and another file for any other.
    private static func kind(of file: URL) throws -> NuxieMachineAsset.Kind {
        switch file.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "webp":
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let header = handle.readData(ofLength: 24)
            guard let size = pngSize(header) else { return .other }
            return .picture(width: size.width, height: size.height)
        case "ttf", "otf":
            return .font
        default:
            return .other
        }
    }

    /// A PNG's width and height in pixels: its signature, then its first
    /// chunk, `IHDR`, whose data is the width and then the height, each
    /// four bytes, most significant first. None for any other bytes, or a
    /// size of 0.
    static func pngSize(_ header: Data) -> (width: UInt32, height: UInt32)? {
        let bytes = [UInt8](header)
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count >= 24, bytes.starts(with: signature), bytes[12..<16].elementsEqual(Array("IHDR".utf8))
        else { return nil }
        func be32(_ at: Int) -> UInt32 {
            bytes[at..<at + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        let width = be32(16)
        let height = be32(20)
        guard width > 0, height > 0 else { return nil }
        return (width: width, height: height)
    }
}
