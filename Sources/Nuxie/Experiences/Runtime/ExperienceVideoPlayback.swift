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

    private struct PreparedMedia {
        let asset: AVURLAsset
        let duration: Double
        let decodeCost: UInt64
        let captionLanguage: String
        let captions: [NuxieNativeVideoCaptionCue]
    }

    private struct Source {
        let key: String
        let media: PreparedMedia?
    }

    private let decoderOwner = UUID()
    private let decoderPool: ExperienceVideoDecoderPool?
    private let decoderBudget: (() -> NuxieNativeVideoDecoderBudget)?
    private var resourceBlocked: Set<Int> = []
    private var requestedRates: [Int: Double] = [:]
    private var reconciling = false
    private let runtime: NuxieNativeRuntime
    private let lease: JourneyReleaseVideoFileLease?
    private let targets: [NativeExperienceVideoElement]
    private var sources: [UInt32: Source] = [:]
    private var decoders: [Decoder] = []
    private var observers: [NSObjectProtocol] = []
    private var suspensionReasons: Set<UInt32> = []
    private struct Admission {
        var elapsed: Double = 0
        var decision: UInt32 = 0
    }
    private var admissions: [Int: Admission] = [:]
    private var admissionClock = CACurrentMediaTime()
    private var presentationAdmitted = false
    private var closed = false

    private init(runtime: NuxieNativeRuntime, lease: JourneyReleaseVideoFileLease?, targets: [NativeExperienceVideoElement],
        decoderBudget: (() -> NuxieNativeVideoDecoderBudget)?, decoderPool: ExperienceVideoDecoderPool?) {
        self.decoderPool = decoderPool
        self.decoderBudget = decoderBudget
        self.runtime = runtime
        self.lease = lease
        self.targets = targets
    }

    static func open(runtime: NuxieNativeRuntime, payload: AuthenticatedRuntimePayload,
        decoderBudget: (() -> NuxieNativeVideoDecoderBudget)? = nil,
        decoderPool: ExperienceVideoDecoderPool? = nil) async throws -> ExperienceVideoPlayback {
        guard decoderBudget == nil || decoderPool == nil else {
            throw ExperienceInteractiveScreenError.stateContract("video playback requires a single budget owner")
        }
        let host = ExperienceVideoPlayback(runtime: runtime, lease: payload.videoFileLease,
            targets: payload.renderPlan.videoElements, decoderBudget: decoderBudget, decoderPool: decoderPool)
        do {
            var prepared: [String: PreparedMedia] = [:]
            for declaration in payload.renderPlan.videos {
                guard let assetID = UInt32(exactly: declaration.riveAssetId),
                      let retained = payload.assets.first(where: { $0.kind == .video && $0.riveAssetID == assetID }) else {
                    throw ExperienceInteractiveScreenError.assetContract("video occurrence differs from signed inventory")
                }
                guard let url = retained.fileURL, url.isFileURL else {
                    if declaration.required { throw ExperienceInteractiveScreenError.assetContract("required video file unavailable") }
                    host.sources[assetID] = Source(key: declaration.sourceAssetKey, media: nil)
                    continue
                }
                let key = "\(declaration.sha256):\(declaration.captionTracks.first?.streamIndex ?? -1)"
                let media: PreparedMedia
                if let cached = prepared[key] {
                    media = cached
                } else {
                    do {
                        let asset = AVURLAsset(url: url)
                        let playable = try await asset.load(.isPlayable)
                        let duration = try await asset.load(.duration).seconds
                        guard playable, duration.isFinite, duration > 0 else {
                            throw ExperienceInteractiveScreenError.assetContract("video is not playable on this device")
                        }
                        let cues: [NuxieNativeVideoCaptionCue]
                        if let track = declaration.captionTracks.first {
                            cues = try await ExperienceVideoCaptions.read(url: url, track: track)
                        } else { cues = [] }
                        let decodeCost = decoderBudget == nil && decoderPool == nil ? 0 : try await ExperienceVideoDecodeCost.read(url: url)
                        media = PreparedMedia(asset: asset, duration: duration, decodeCost: decodeCost,
                            captionLanguage: declaration.captionTracks.first?.language ?? "", captions: cues)
                        prepared[key] = media
                    } catch {
                        // Optional media failure keeps the scene and its poster usable.
                        // Cancellation still tears down the pending screen admission.
                        try Task.checkCancellation()
                        guard !declaration.required else { throw error }
                        host.sources[assetID] = Source(key: declaration.sourceAssetKey, media: nil)
                        continue
                    }
                }
                host.sources[assetID] = Source(key: declaration.sourceAssetKey, media: media)
            }
            try await host.reconcile()
            host.observeLifecycle()
            return host
        } catch {
            host.close()
            throw error
        }
    }

    private func dispose(_ decoder: Decoder) {
        decoder.disposed = true
        decoder.player.pause()
        decoder.player.replaceCurrentItem(with: nil)
        decoderPool?.release(owner: decoderOwner, componentID: decoder.componentID)
        try? ExperienceVideoAudioSession.update(id: decoder.audioID, policy: decoder.audioPolicy, audible: false)
    }

    private func reconcile() async throws {
        guard !closed, !reconciling else { return }
        reconciling = true
        defer { reconciling = false }
        var occurrences = try await runtime.videos()
        guard !closed else { return }
        let live = Set(occurrences.map(\.componentID))
        guard live.count == occurrences.count else {
            throw ExperienceInteractiveScreenError.assetContract("duplicate video occurrence identity")
        }
        for occurrence in occurrences {
            guard !occurrence.embedded,
                  occurrence.contentType.isEmpty || occurrence.contentType == "video/mp4",
                  sources[occurrence.assetID]?.key == occurrence.sourceKey,
                  targets.contains(where: {
                      Int($0.sourceArtboardIndex) == occurrence.sourceArtboardIndex &&
                      Int($0.componentId) == occurrence.sourceComponentID
                  }) else {
                throw ExperienceInteractiveScreenError.assetContract("video occurrence differs from signed inventory")
            }
        }
        resourceBlocked.formIntersection(live)
        requestedRates = requestedRates.filter { live.contains($0.key) }
        if decoderBudget != nil || decoderPool != nil {
            occurrences = try await admit(occurrences, budget: decoderBudget?())
            guard !closed else { return }
        }
        for decoder in decoders where !live.contains(decoder.componentID) { dispose(decoder) }
        decoders.removeAll { !live.contains($0.componentID) }
        for occurrence in occurrences {
            guard !closed else { return }
            guard !resourceBlocked.contains(occurrence.componentID), occurrence.state != 7, occurrence.state != 8,
                  !decoders.contains(where: { $0.componentID == occurrence.componentID }) else { continue }
            guard let media = sources[occurrence.assetID]?.media else {
                if occurrence.state != 7 && occurrence.state != 8 {
                    _ = try await runtime.videoStep(componentID: occurrence.componentID, observation: 6, generation: occurrence.generation)
                }
                continue
            }
            let decoder = Decoder(componentID: occurrence.componentID, generation: occurrence.generation,
                audioPolicy: occurrence.audioPolicy, asset: media.asset, duration: media.duration)
            // Publish ownership before awaiting actor calls so lifecycle callbacks
            // cannot create a second player or leave a player alive after close.
            decoders.append(decoder)
            if !media.captions.isEmpty {
                try await runtime.videoSetCaptions(componentID: occurrence.componentID,
                    language: media.captionLanguage, cues: media.captions)
            }
            guard !closed else { return }
            for reason in suspensionReasons {
                try await runtime.videoCommand(componentID: occurrence.componentID, kind: 6, value: suspensionReasons.contains(reason) ? 1 : 0, reason: reason)
            }
        }
    }

    private func advanceAdmissionClock() {
        let now = CACurrentMediaTime()
        let elapsed = max(0, now - admissionClock)
        admissionClock = now
        guard suspensionReasons.isEmpty else { return }
        for id in admissions.keys where admissions[id]?.decision == 0 {
            admissions[id]?.elapsed += elapsed
        }
    }

    /// Scene advancement and decoder ticking precede this initial-presentation gate.
    func isReadyForPresentation() async throws -> Bool {
        guard !closed else { return false }
        advanceAdmissionClock()
        let videos = try await runtime.videos()
        guard !closed else { return false }
        let live = Set(videos.map(\.componentID))
        admissions = admissions.filter { live.contains($0.key) }
        var waiting = false
        for video in videos where video.readiness == 1 {
            guard let target = targets.first(where: {
                Int($0.sourceArtboardIndex) == video.sourceArtboardIndex &&
                Int($0.componentId) == video.sourceComponentID
            }) else { throw ExperienceInteractiveScreenError.assetContract("video readiness target unavailable") }
            var admission = admissions[video.componentID] ?? Admission()
            if admission.decision == 0 {
                admission.decision = try await runtime.videoReadiness(componentID: video.componentID,
                    elapsedSeconds: admission.elapsed, timeoutSeconds: target.readinessTimeoutSeconds,
                    optional: target.optional)
                guard !closed else { return false }
                admissions[video.componentID] = admission
                if admission.decision == 2 {
                    // Retire the actual decoder before clearing its scene frame;
                    // asynchronous seek callbacks cannot resurrect this owner.
                    if let decoder = decoders.first(where: { $0.componentID == video.componentID }) { dispose(decoder) }
                    try await runtime.videoCommand(componentID: video.componentID, kind: 8, value: 0)
                    _ = try await runtime.videoStep(componentID: video.componentID, observation: 0, generation: video.generation)
                }
            }
            if admission.decision == 3 {
                throw ExperienceInteractiveScreenError.assetContract("required video first frame unavailable")
            }
            waiting = waiting || admission.decision == 0
        }
        // Later list rows keep their own deadline without hiding an already
        // presented screen while those new decoders acquire a first frame.
        if !waiting { presentationAdmitted = true }
        return presentationAdmitted
    }

    func captions() async throws -> [ExperienceInteractiveVideoCaption] {
        guard !closed else { return [] }
        try await reconcile()
        var values: [ExperienceInteractiveVideoCaption] = []
        for decoder in decoders where !decoder.disposed && !decoder.failed {
            let caption = try await runtime.videoCaption(componentID: decoder.componentID)
            guard !closed, !decoder.disposed else { continue }
            if !caption.text.isEmpty {
                values.append(.init(componentID: decoder.componentID, language: caption.language, text: caption.text))
            }
        }
        return values
    }

    func apply(_ action: JourneyVideoAction) async throws {
        guard !closed else { throw ExperienceInteractiveScreenError.stateContract("video playback is closed") }
        let matches = targets.filter { $0.artboardId == action.artboardId && $0.viewNodeId == action.viewNodeId }
        let live = try await runtime.videos().filter { occurrence in
            matches.contains { target in
                Int(target.sourceArtboardIndex) == occurrence.sourceArtboardIndex &&
                Int(target.componentId) == occurrence.sourceComponentID
            }
        }
        guard !closed, !live.isEmpty else {
            throw ExperienceInteractiveScreenError.stateContract("video target is not mounted in this screen")
        }
        for occurrence in live {
            try await runtime.videoCommand(componentID: occurrence.componentID,
                kind: action.commandKind, value: action.commandValue)
        }
    }

    private func apply(_ actions: [NuxieNativeVideoAction], to decoder: Decoder) async throws {
        for action in actions {
            if action.kind == 3 { requestedRates[decoder.componentID] = action.value }
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
                dispose(decoder)
            default: throw ExperienceInteractiveScreenError.assetContract("unknown native video action")
            }
        }
    }

    private func admit(_ occurrences: [NuxieNativeVideoOccurrence], budget: NuxieNativeVideoDecoderBudget?) async throws -> [NuxieNativeVideoOccurrence] {
        for video in occurrences where video.state != 7 && video.state != 8 {
            let actions = try await runtime.videoStep(componentID: video.componentID, observation: 0, generation: video.generation)
            guard !closed else { return [] }
            for action in actions where action.kind == 3 { requestedRates[video.componentID] = action.value }
            if let decoder = decoders.first(where: { $0.componentID == video.componentID && !$0.disposed }) {
                try await apply(actions, to: decoder)
            }
        }
        let current = try await runtime.videos()
        guard !closed else { return [] }
        let demands: [Int: ExperienceVideoDecoderPool.Request] = Dictionary(uniqueKeysWithValues: current.map { video in
            let cost = sources[video.assetID]?.media?.decodeCost ?? 0
            let scaled = ceil(Double(cost) * max(1, requestedRates[video.componentID] ?? 1))
            let pixels = scaled >= Double(UInt64.max) ? UInt64.max : UInt64(scaled)
            return (video.componentID, ExperienceVideoDecoderPool.Request(pixelsPerSecond: pixels,
                priority: video.priority, visible: suspensionReasons.isEmpty && video.state != 7 && video.state != 8 && cost > 0))
        })
        let choices: [NuxieNativeVideoAllocation]
        if let decoderPool {
            let admitted = try decoderPool.update(owner: decoderOwner, requests: demands)
            choices = current.map { admitted.contains($0.componentID) ? .platformManaged : .poster }
        } else if let budget {
            choices = try NuxieNativeRuntime.allocateVideoDecoders(current.map { video in
                let demand = demands[video.componentID]!
                return NuxieNativeVideoDecoderRequest(id: UInt64(video.componentID), pixelsPerSecond: demand.pixelsPerSecond,
                    priority: demand.priority, visible: demand.visible)
            }, budget: budget)
        } else { return current }
        for (index, video) in current.enumerated() where video.state != 7 && video.state != 8 && sources[video.assetID]?.media != nil {
            let blocked = choices[index] == .poster
            guard blocked || choices[index] == .platformManaged else {
                throw ExperienceInteractiveScreenError.assetContract("AVPlayer cannot force a decoder implementation")
            }
            if blocked && !resourceBlocked.contains(video.componentID) {
                if let decoder = decoders.first(where: { $0.componentID == video.componentID }) { dispose(decoder) }
                decoders.removeAll { $0.componentID == video.componentID }
                decoderPool?.release(owner: decoderOwner, componentID: video.componentID)
                resourceBlocked.insert(video.componentID)
                _ = try await runtime.reclaimVideoDecoder(componentID: video.componentID, blocked: true)
                guard !closed else { return [] }
            }
        }
        for (index, video) in current.enumerated() where choices[index] == .platformManaged && resourceBlocked.contains(video.componentID) {
            _ = try await runtime.reclaimVideoDecoder(componentID: video.componentID, blocked: false)
            guard !closed else { return [] }
            resourceBlocked.remove(video.componentID)
        }
        return try await runtime.videos()
    }

    /// Called after Luau/state-machine stepping and before drawing the scene.
    func tick() async throws -> Bool {
        guard !closed else { return false }
        try await reconcile()
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
            guard !closed, !decoder.disposed else { continue }
            try await apply(actions, to: decoder)
            guard !decoder.disposed else { continue }
            let clock = decoder.player.currentTime().seconds
            try await runtime.videoClock(componentID: decoder.componentID, generation: decoder.generation,
                seconds: clock.isFinite ? clock : 0, rate: Double(decoder.player.rate),
                playing: decoder.player.timeControlStatus == .playing, available: decoder.ready && !decoder.seeking)
            guard !closed, !decoder.disposed else { continue }
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
        guard !closed else { return }
        advanceAdmissionClock()
        let changed = enabled ? suspensionReasons.insert(reason).inserted : suspensionReasons.remove(reason) != nil
        guard changed else { return }
        if enabled { for decoder in decoders { decoder.player.pause() } }
        try await reconcile()
        for decoder in decoders where !decoder.disposed {
            // Stop output immediately even if the app has stopped requesting frames.
            if enabled { decoder.player.pause() }
            try await runtime.videoCommand(componentID: decoder.componentID, kind: 6, value: suspensionReasons.contains(reason) ? 1 : 0, reason: reason)
        }
        _ = try await tick()
    }

    var playbackDiagnostics: String {
        decoders.map { "id=\($0.componentID) generation=\($0.generation) time=\($0.player.currentTime().seconds) rate=\($0.player.rate) seeking=\($0.seeking) wants=\($0.wantsPlay) failed=\($0.failed) suspension=\(suspensionReasons)" }.joined(separator: "; ")
    }

    func close() {
        guard !closed else { return }
        closed = true
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for decoder in decoders { dispose(decoder) }
        decoders.removeAll()
        decoderPool?.remove(owner: decoderOwner)
        sources.removeAll()
        admissions.removeAll()
        resourceBlocked.removeAll()
        requestedRates.removeAll()
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
