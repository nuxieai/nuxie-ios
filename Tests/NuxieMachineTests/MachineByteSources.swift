#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import NuxieMachine

/// The byte source of a folder that holds its sources and nothing else:
/// it has bytes for no file. A plan whose views show no picture never asks
/// it; one that shows a picture stops at open with `edge.unsupplied-asset`.
struct NoFolderFiles: NuxieMachineByteSource {
    func bytes(for path: String) async throws -> Data {
        throw NuxieMachineByteSourceFault.noFile(path)
    }
}

/// A folder's byte source that answers only once the test lets it: every
/// ask waits until [`release`] and then reads the folder, and the paths
/// asked are kept in order. A release that comes before an ask lets it
/// answer at once.
final class HeldBytes: NuxieMachineByteSource, @unchecked Sendable {
    private let folder: NuxieMachineFolderByteSource
    private let lock = NSLock()
    private var askedPaths: [String] = []
    private var released = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var watching: [CheckedContinuation<Void, Never>] = []

    init(folder: URL) {
        self.folder = NuxieMachineFolderByteSource(folder: folder)
    }

    /// The paths asked for so far, in order.
    var asked: [String] {
        lock.withLock { askedPaths }
    }

    func bytes(for path: String) async throws -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let (goes, watchers) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
                askedPaths.append(path)
                let watchers = watching
                watching = []
                if !released { held.append(continuation) }
                return (released, watchers)
            }
            watchers.forEach { $0.resume() }
            if goes { continuation.resume() }
        }
        return try await folder.bytes(for: path)
    }

    /// Returns once some path has been asked for.
    func untilAsked() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                guard askedPaths.isEmpty else { return true }
                watching.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Let every ask answer, those held and those to come.
    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            defer { held = [] }
            return held
        }
        waiting.forEach { $0.resume() }
    }
}
#endif
