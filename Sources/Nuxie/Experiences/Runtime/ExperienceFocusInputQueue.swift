#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import NuxieRuntime

struct ExperienceFocusInputQueue {
    private var values: [NuxieNativeFocusInput] = []
    var isEmpty: Bool { values.isEmpty }

    mutating func append(_ input: NuxieNativeFocusInput) {
        if case .text(let text) = input {
            if text.isEmpty { values.append(.text("")); return }
            let limit = NuxieNativeFocusLimits.textBytesPerInput
            let scalars = text.unicodeScalars
            var start = scalars.startIndex
            var end = start
            var chunkBytes = 0
            func flush() {
                guard chunkBytes > 0 else { return }
                values.append(.text(String(scalars[start..<end])))
                chunkBytes = 0
                start = end
            }
            ExperienceGrapheme.forEachCluster(in: text) { range, byteCount in
                if byteCount > limit {
                    flush()
                    let bytes = Array(String(scalars[range]).utf8)
                    var offset = 0
                    while offset < bytes.count {
                        var next = min(offset + limit, bytes.count)
                        while next < bytes.count && bytes[next] & 0xc0 == 0x80 { next -= 1 }
                        values.append(.text(String(decoding: bytes[offset..<next], as: UTF8.self)))
                        offset = next
                    }
                    start = range.upperBound
                    end = start
                } else {
                    if chunkBytes + byteCount > limit { flush() }
                    if chunkBytes == 0 { start = range.lowerBound }
                    end = range.upperBound
                    chunkBytes += byteCount
                }
            }
            flush()
        } else {
            values.append(input)
        }
    }

    mutating func takeBatch() -> [NuxieNativeFocusInput] {
        var batch: [NuxieNativeFocusInput] = []
        var bytes = 0
        while batch.count < values.count && batch.count < NuxieNativeFocusLimits.inputsPerStep {
            let input = values[batch.count]
            let size: Int
            if case .text(let text) = input { size = text.utf8.count } else { size = 0 }
            guard bytes + size <= NuxieNativeFocusLimits.textBytesPerStep else { break }
            batch.append(input)
            bytes += size
        }
        if batch.count == values.count { removeAll() }
        else { values.removeFirst(batch.count) }
        return batch
    }

    mutating func removeAll() {
        values.removeAll(keepingCapacity: true)
    }
}
#endif
