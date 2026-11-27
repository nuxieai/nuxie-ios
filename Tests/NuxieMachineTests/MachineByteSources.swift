#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import NuxieMachine
import XCTest

/// The byte source of a folder that holds its sources and nothing else:
/// it has bytes for no file. A plan whose views show no file never asks
/// it; one that shows a file has that path failed, and its page waits on
/// the recovery screen.
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

/// A byte source the test answers path by path: each ask waits until the
/// test answers it with the file's bytes ([`answer`]) or fails it
/// ([`fail`]), and every ask is kept, in order. The bytes are read with
/// `read`, the folder's own reader unless the test gives another.
final class AskedBytes: NuxieMachineByteSource, @unchecked Sendable {
    private typealias Answer = CheckedContinuation<Result<Data, any Error>, Never>

    private let read: @Sendable (String) async throws -> Data
    private let lock = NSLock()
    private var askedPaths: [String] = []
    private var waiting: [(path: String, answer: Answer)] = []

    init(read: @escaping @Sendable (String) async throws -> Data) {
        self.read = read
    }

    convenience init(folder: URL) {
        let source = NuxieMachineFolderByteSource(folder: folder)
        self.init(read: { try await source.bytes(for: $0) })
    }

    /// The paths asked for so far, in order, one entry for each ask.
    var asked: [String] {
        lock.withLock { askedPaths }
    }

    func bytes(for path: String) async throws -> Data {
        let answer = await withCheckedContinuation { (continuation: Answer) in
            lock.withLock {
                askedPaths.append(path)
                waiting.append((path, continuation))
            }
        }
        return try answer.get()
    }

    /// Returns once `path` has been asked for `times` times in all, or fails
    /// the test after ten seconds.
    func untilAsked(_ path: String, times: Int = 1, file: StaticString = #filePath,
                    line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(10)
        while asked.filter({ $0 == path }).count < times {
            guard Date() < deadline else {
                return XCTFail("\(path) was not asked for \(times) times: \(asked)", file: file, line: line)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Answer the oldest ask still waiting for `path` with the file's bytes.
    func answer(_ path: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let given = try await read(path)
        resume(path, .success(given), file: file, line: line)
    }

    /// Fail the oldest ask still waiting for `path` with `error`.
    func fail(_ path: String, with error: any Error, file: StaticString = #filePath, line: UInt = #line) {
        resume(path, .failure(error), file: file, line: line)
    }

    /// Fail every ask still waiting, so none outlives the test.
    func dropAll() {
        let left = lock.withLock { () -> [Answer] in
            defer { waiting = [] }
            return waiting.map(\.answer)
        }
        left.forEach { $0.resume(returning: .failure(CancellationError())) }
    }

    private func resume(_ path: String, _ result: Result<Data, any Error>, file: StaticString, line: UInt) {
        let next = lock.withLock { () -> Answer? in
            guard let index = waiting.firstIndex(where: { $0.path == path }) else { return nil }
            return waiting.remove(at: index).answer
        }
        guard let next else { return XCTFail("no ask waits for \(path): \(asked)", file: file, line: line) }
        next.resume(returning: result)
    }
}

/// The error a phone's network stack gives with no connection.
let offlineError = URLError(.notConnectedToInternet)
#endif
