#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import AVFoundation
import Foundation

/// Reads bounded sample timing from the acquired file without opening a decoder.
enum ExperienceVideoDecodeCost {
    static func read(url: URL) async throws -> UInt64 {
        guard url.isFileURL else { throw invalid() }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else { throw invalid() }
        let formats = try await track.load(.formatDescriptions)
        guard let format = formats.first else { throw invalid() }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard formats.allSatisfy({
            let candidate = CMVideoFormatDescriptionGetDimensions($0)
            return candidate.width == dimensions.width && candidate.height == dimensions.height
        }) else { throw invalid() }
        let duration = try await track.load(.timeRange).duration
        guard duration.isNumeric, duration.seconds > 0 else { throw invalid() }
        let durationUs = CMTimeConvertScale(duration, timescale: 1_000_000, method: .roundTowardZero).value
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw invalid() }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? invalid() }
        defer { reader.cancelReading() }
        var timestamps: [Int64] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let count = CMSampleBufferGetNumSamples(sample)
            if count == 0 { continue }
            guard count == 1, timestamps.count < 100_000,
                  CMSampleBufferGetTotalSampleSize(sample) <= 64 * 1024 * 1024 else { throw invalid() }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            guard time.isNumeric, time.seconds >= 0 else { throw invalid() }
            timestamps.append(CMTimeConvertScale(time, timescale: 1_000_000, method: .roundTowardZero).value)
        }
        guard reader.status == .completed else { throw reader.error ?? invalid() }
        return try pixelsPerSecond(width: Int(dimensions.width), height: Int(dimensions.height),
            durationUs: durationUs, timestamps: timestamps)
    }

    static func pixelsPerSecond(width: Int, height: Int, durationUs: Int64, timestamps: [Int64]) throws -> UInt64 {
        guard (1...16384).contains(width), (1...16384).contains(height), durationUs > 0,
              !timestamps.isEmpty, timestamps.count <= 100_000, timestamps.allSatisfy({ $0 >= 0 }) else { throw invalid() }
        let sorted = timestamps.sorted()
        let span = sorted[sorted.count - 1] - sorted[0]
        guard span < durationUs else { throw invalid() }
        var intervalUs = durationUs - span
        for index in 1..<sorted.count {
            let delta = sorted[index] - sorted[index - 1]
            guard delta > 0 else { throw invalid() }
            intervalUs = min(intervalUs, delta)
        }
        let rate = UInt64(ceil(1_000_000.0 / Double(intervalUs)))
        // Bounded dimensions and a minimum one-microsecond interval fit UInt64.
        return UInt64(width) * UInt64(height) * rate
    }

    private static func invalid() -> ExperienceInteractiveScreenError {
        .assetContract("video decode cost is unavailable or exceeds limits")
    }
}
#endif
