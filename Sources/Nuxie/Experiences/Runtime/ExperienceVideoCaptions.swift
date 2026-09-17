#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import AVFoundation
import Foundation
import NuxieRuntime

/// Reads the authenticated MP4's plain-text track once. Cue projection remains
/// owned by the runtime; this importer never starts a second playback clock.
enum ExperienceVideoCaptions {
    static func read(url: URL, track: NativeExperienceVideoAsset.CaptionTrack) async throws -> [NuxieNativeVideoCaptionCue] {
        guard url.isFileURL, track.codec == "mov_text", track.streamIndex >= 0 else {
            throw invalid("invalid caption source")
        }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        guard tracks.indices.contains(track.streamIndex) else { throw invalid("caption stream is missing") }
        let selected = tracks[track.streamIndex]
        let descriptions = try await selected.load(.formatDescriptions)
        guard !descriptions.isEmpty,
              descriptions.allSatisfy({ CMFormatDescriptionGetMediaSubType($0) == kCMTextFormatType_3GText }) else {
            throw invalid("caption stream is not timed MP4 text")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: selected, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw invalid("caption stream cannot be read") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? invalid("caption reader failed") }
        defer { reader.cancelReading() }
        var cues: [NuxieNativeVideoCaptionCue] = []
        var totalBytes = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            // Compressed AVAssetReader output includes marker-only buffers.
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            guard CMSampleBufferGetNumSamples(sample) == 1,
                  let buffer = CMSampleBufferGetDataBuffer(sample) else {
                throw invalid("invalid caption sample")
            }
            let size = CMBlockBufferGetDataLength(buffer)
            guard size >= 2, size <= 1024 * 1024 else { throw invalid("caption sample exceeds limits") }
            var bytes = Data(count: size)
            let status = bytes.withUnsafeMutableBytes { storage in
                CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: size, destination: storage.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw invalid("caption sample is unreadable") }
            let length = Int(bytes[0]) * 256 + Int(bytes[1])
            guard length <= size - 2 else { throw invalid("truncated caption text") }
            if length == 0 { continue }
            guard let text = String(data: bytes.subdata(in: 2..<(2 + length)), encoding: .utf8) else {
                throw invalid("caption text is not UTF-8")
            }
            totalBytes += length
            guard cues.count < 100_000, totalBytes <= 8 * 1024 * 1024 else {
                throw invalid("caption track exceeds limits")
            }
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let duration = CMSampleBufferGetDuration(sample).seconds
            guard start.isFinite, start >= 0, duration.isFinite, duration > 0,
                  (start + duration).isFinite, start >= (cues.last?.startSeconds ?? 0) else {
                throw invalid("invalid caption timing")
            }
            cues.append(.init(startSeconds: start, endSeconds: start + duration, text: text))
        }
        try Task.checkCancellation()
        guard reader.status == .completed else { throw reader.error ?? invalid("caption reading did not complete") }
        return cues
    }

    private static func invalid(_ message: String) -> ExperienceInteractiveScreenError {
        .assetContract(message)
    }
}
#endif
