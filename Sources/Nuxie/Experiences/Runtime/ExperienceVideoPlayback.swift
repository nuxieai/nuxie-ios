#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Accelerate
import AVFoundation
import CoreVideo
import Foundation
import QuartzCore
import NuxieRuntime
#if canImport(UIKit)
import UIKit
#endif

/// One decoder per authored occurrence. Only authenticated local files cross
/// this boundary; playback intent and seek generations remain runtime-owned.
@MainActor
final class ExperienceVideoPlayback {
    @MainActor
    private final class Decoder {
        let componentID: Int
        let audioID = UUID()
        let audioPolicy: UInt32
        let player: AVPlayer
        let output: AVPlayerItemVideoOutput
        let duration: Double
        var generation: UInt64
        var requestedRate: Float = 1
        var ready = false
        var ended = false
        var seeking = false
        var wantsPlay = false
        var failed = false
        var disposed = false

        init(componentID: Int, generation: UInt64, audioPolicy: UInt32, asset: AVURLAsset, duration: Double) {
            self.componentID = componentID
            self.audioPolicy = audioPolicy
            self.generation = generation
            self.duration = duration
            output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            let item = AVPlayerItem(asset: asset)
            item.add(output)
            player = AVPlayer(playerItem: item)
            player.volume = 0
            player.actionAtItemEnd = .pause
        }
    }

    private let runtime: NuxieNativeRuntime
    private let lease: JourneyReleaseVideoFileLease?
    private var decoders: [Decoder] = []
    private var observers: [NSObjectProtocol] = []
    private var suspensionReasons: Set<UInt32> = []

    private init(runtime: NuxieNativeRuntime, lease: JourneyReleaseVideoFileLease?) {
        self.runtime = runtime
        self.lease = lease
    }

    static func open(runtime: NuxieNativeRuntime, payload: AuthenticatedRuntimePayload) async throws -> ExperienceVideoPlayback {
        let host = ExperienceVideoPlayback(runtime: runtime, lease: payload.videoFileLease)
        do {
            var captionCache: [String: [NuxieNativeVideoCaptionCue]] = [:]
            for occurrence in try await runtime.videos() {
                // An omitted scene MIME is resolved by the signed retained inventory.
                guard !occurrence.embedded,
                      occurrence.contentType.isEmpty || occurrence.contentType == "video/mp4",
                      let declaration = payload.renderPlan.videos.first(where: { $0.riveAssetId == UInt64(occurrence.assetID) }),
                      declaration.sourceAssetKey == occurrence.sourceKey,
                      let retained = payload.assets.first(where: { $0.kind == .video && $0.riveAssetID == occurrence.assetID }) else {
                    throw ExperienceInteractiveScreenError.assetContract("video occurrence differs from signed inventory")
                }
                guard let url = retained.fileURL, url.isFileURL else {
                    if declaration.required { throw ExperienceInteractiveScreenError.assetContract("required video file unavailable") }
                    _ = try await runtime.videoStep(componentID: occurrence.componentID, observation: 6, generation: occurrence.generation)
                    continue
                }
                let asset = AVURLAsset(url: url)
                let playable = try await asset.load(.isPlayable)
                let duration = try await asset.load(.duration).seconds
                guard playable, duration.isFinite, duration > 0 else {
                    throw ExperienceInteractiveScreenError.assetContract("video is not playable on this device")
                }
                if let track = declaration.captionTracks.first {
                    let key = "\(declaration.sha256):\(track.streamIndex)"
                    let cues: [NuxieNativeVideoCaptionCue]
                    if let cached = captionCache[key] { cues = cached }
                    else {
                        cues = try await ExperienceVideoCaptions.read(url: url, track: track)
                        captionCache[key] = cues
                    }
                    try await runtime.videoSetCaptions(componentID: occurrence.componentID,
                        language: track.language ?? "", cues: cues)
                }
                host.decoders.append(Decoder(componentID: occurrence.componentID, generation: occurrence.generation, audioPolicy: occurrence.audioPolicy,
                    asset: asset, duration: duration))
            }
            host.observeLifecycle()
            return host
        } catch {
            host.close()
            throw error
        }
    }

    func captions() async throws -> [ExperienceInteractiveVideoCaption] {
        var values: [ExperienceInteractiveVideoCaption] = []
        for decoder in decoders where !decoder.disposed && !decoder.failed {
            let caption = try await runtime.videoCaption(componentID: decoder.componentID)
            if !caption.text.isEmpty {
                values.append(.init(componentID: decoder.componentID, language: caption.language, text: caption.text))
            }
        }
        return values
    }

    /// Called after Luau/state-machine stepping and before drawing the scene.
    func tick() async throws -> Bool {
        var active = false
        for decoder in decoders where !decoder.disposed {
            let item = decoder.player.currentItem
            let seconds = decoder.player.currentTime().seconds
            let observation: UInt32
            if decoder.failed || item?.status == .failed { observation = 6 }
            else if !decoder.ready && item?.status == .readyToPlay {
                decoder.ready = true
                observation = 1
            } else if decoder.ready && !decoder.seeking && !decoder.ended && seconds >= decoder.duration - 0.001 {
                decoder.ended = true
                observation = 3
            } else if decoder.player.timeControlStatus == .playing { observation = 2 }
            else if decoder.player.timeControlStatus == .waitingToPlayAtSpecifiedRate { observation = 4 }
            else { observation = 0 }
            let actions = try await runtime.videoStep(componentID: decoder.componentID, observation: observation,
                generation: decoder.generation, value: observation == 1 ? decoder.duration : 0)
            for action in actions {
                switch action.kind {
                case 0:
                    decoder.wantsPlay = true
                    guard suspensionReasons.isEmpty else { decoder.player.pause(); continue }
                    do {
                        try ExperienceVideoAudioSession.update(id: decoder.audioID, policy: decoder.audioPolicy, audible: decoder.player.volume > 0)
                        if !decoder.seeking { decoder.player.playImmediately(atRate: decoder.requestedRate) }
                    } catch {
                        decoder.player.pause()
                        try? ExperienceVideoAudioSession.update(id: decoder.audioID, policy: decoder.audioPolicy, audible: false)
                        _ = try await runtime.videoStep(componentID: decoder.componentID, observation: 5, generation: decoder.generation)
                    }
                case 1:
                    decoder.wantsPlay = false
                    decoder.player.pause()
                    try ExperienceVideoAudioSession.update(id: decoder.audioID, policy: decoder.audioPolicy, audible: false)
                case 2:
                    decoder.generation = action.generation
                    decoder.ended = false
                    decoder.seeking = true
                    decoder.player.pause()
                    let generation = action.generation
                    decoder.player.seek(to: CMTime(seconds: action.value, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak decoder] finished in
                        Task { @MainActor in
                            guard let self, let decoder, decoder.generation == generation, !decoder.disposed else { return }
                            decoder.seeking = false
                            decoder.failed = !finished
                            if finished && decoder.wantsPlay && self.suspensionReasons.isEmpty {
                                decoder.player.playImmediately(atRate: decoder.requestedRate)
                            }
                        }
                    }
                case 3:
                    decoder.requestedRate = Float(action.value)
                    if decoder.player.rate != 0 { decoder.player.rate = decoder.requestedRate }
                case 4:
                    decoder.player.volume = Float(action.value)
                    try ExperienceVideoAudioSession.update(id: decoder.audioID, policy: decoder.audioPolicy,
                        audible: decoder.player.volume > 0 && decoder.player.rate != 0)
                case 5:
                    decoder.player.pause(); decoder.player.replaceCurrentItem(with: nil); decoder.disposed = true
                    try ExperienceVideoAudioSession.update(id: decoder.audioID, policy: decoder.audioPolicy, audible: false)
                default: throw ExperienceInteractiveScreenError.assetContract("unknown native video action")
                }
            }
            guard !decoder.disposed else { continue }
            let clock = decoder.player.currentTime().seconds
            try await runtime.videoClock(componentID: decoder.componentID, generation: decoder.generation,
                seconds: clock.isFinite ? clock : 0, rate: Double(decoder.player.rate),
                playing: decoder.player.timeControlStatus == .playing, available: decoder.ready && !decoder.seeking)
            if !decoder.seeking && suspensionReasons.isEmpty {
                let time = decoder.output.itemTime(forHostTime: CACurrentMediaTime())
                if decoder.output.hasNewPixelBuffer(forItemTime: time) {
                    var displayTime = CMTime.invalid
                    if let buffer = decoder.output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayTime) {
                        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
                        guard width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_777_216 else {
                            throw ExperienceInteractiveScreenError.assetContract("decoded video frame exceeds limits")
                        }
                        CVPixelBufferLockBaseAddress(buffer, .readOnly)
                        let rgba: Data
                        do {
                            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                            guard let base = CVPixelBufferGetBaseAddress(buffer) else { continue }
                            let stride = CVPixelBufferGetBytesPerRow(buffer)
                            var source = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: stride)
                            var pixels = Data(count: width * height * 4)
                            let status = pixels.withUnsafeMutableBytes { raw -> vImage_Error in
                                var target = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                                return vImagePermuteChannels_ARGB8888(&source, &target, [2, 1, 0, 3], vImage_Flags(kvImageNoFlags))
                            }
                            guard status == kvImageNoError else {
                                throw ExperienceInteractiveScreenError.assetContract("video pixel conversion failed")
                            }
                            rgba = pixels
                        }
                        try await runtime.videoPresent(componentID: decoder.componentID, generation: decoder.generation,
                            seconds: displayTime.seconds.isFinite ? displayTime.seconds : clock,
                            width: UInt32(width), height: UInt32(height), rgba: rgba)
                    }
                }
            }
            active = active || (suspensionReasons.isEmpty && (!decoder.ready || decoder.seeking || decoder.player.timeControlStatus != .paused))
        }
        return active
    }

    private func observeLifecycle() {
        #if canImport(UIKit)
        for (name, enabled) in [(UIApplication.didEnterBackgroundNotification, true), (UIApplication.willEnterForegroundNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in try? await self?.setSuspended(reason: 2, enabled: enabled) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    try? await self?.setSuspended(reason: 4, enabled: true)
                } else if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                    try? await self?.setSuspended(reason: 4, enabled: false)
                }
            }
        })
        #endif
    }

    func setSuspended(reason: UInt32, enabled: Bool) async throws {
        let changed = enabled ? suspensionReasons.insert(reason).inserted : suspensionReasons.remove(reason) != nil
        guard changed else { return }
        for decoder in decoders where !decoder.disposed {
            // Stop output immediately even if the app has stopped requesting frames.
            if enabled { decoder.player.pause() }
            try await runtime.videoCommand(componentID: decoder.componentID, kind: 6, value: enabled ? 1 : 0, reason: reason)
        }
        _ = try await tick()
    }

    var playbackDiagnostics: String {
        decoders.map { "id=\($0.componentID) generation=\($0.generation) time=\($0.player.currentTime().seconds) rate=\($0.player.rate) seeking=\($0.seeking) wants=\($0.wantsPlay) failed=\($0.failed) suspension=\(suspensionReasons)" }.joined(separator: "; ")
    }

    func close() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for decoder in decoders {
            decoder.player.pause(); decoder.player.replaceCurrentItem(with: nil)
            try? ExperienceVideoAudioSession.update(id: decoder.audioID, policy: decoder.audioPolicy, audible: false)
        }
        decoders.removeAll()
    }
}

@MainActor
private enum ExperienceVideoAudioSession {
    #if canImport(UIKit)
    private static var players: [UUID: UInt32] = [:]
    private static var saved: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
    private static var installed: AVAudioSession.CategoryOptions?
    #endif

    static func update(id: UUID, policy: UInt32, audible: Bool) throws {
        #if canImport(UIKit)
        if audible { players[id] = policy } else { players.removeValue(forKey: id) }
        let session = AVAudioSession.sharedInstance()
        if players.isEmpty {
            guard let previous = saved, let options = installed else { return }
            saved = nil; installed = nil
            guard session.category == .playback, session.mode == .default, session.categoryOptions == options else { return }
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            try session.setCategory(previous.0, mode: previous.1, options: previous.2)
            return
        }
        var options: AVAudioSession.CategoryOptions = .mixWithOthers
        for policy in players.values {
            if policy == 0 || policy == 3 { options = []; break }
            if policy == 2 { options.insert(.duckOthers) }
        }
        if installed == options { return }
        if saved == nil { saved = (session.category, session.mode, session.categoryOptions) }
        try session.setCategory(.playback, mode: .default, options: options)
        installed = options
        try session.setActive(true)
        #endif
    }
}

#endif
