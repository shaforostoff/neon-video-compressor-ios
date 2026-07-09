//
//  PreviewController.swift
//  Drives a short "preview" encode (first N seconds, fastest preset) and plays
//  the result looping next to the original for an A/B quality comparison.
//
//  Two AVQueuePlayers loop the same 5 s window: the encoded clip (audible) and
//  the untouched original (muted). Both share a single host-time master clock so
//  they stay frame-synced; the view cross-fades between their layers while a
//  finger is held. See DualPlayerView / PreviewCompareView for the UI.
//
import Foundation
import AVFoundation
import UIKit

@Observable
final class PreviewController {
    enum Phase: Equatable { case encoding, ready, failed(String) }

    // How much of the head of the video we preview.
    static let previewSeconds: Double = 5

    // MARK: playback / status
    private(set) var phase: Phase = .encoding
    /// Progress of the preview encode (0…1), so the spinner can show a bar.
    private(set) var encodeFraction: Double = 0
    /// Display aspect ratio (w/h) of the source, honoring rotation. nil until known.
    private(set) var aspectRatio: CGFloat?

    /// While true, the original (untouched) video is shown for comparison.
    var isComparing = false

    // MARK: zoom / pan (driven by gestures, consumed by the view)
    var scale: CGFloat = 1
    var panOffset: CGSize = .zero
    private var committedScale: CGFloat = 1
    private var committedOffset: CGSize = .zero
    private let maxScale: CGFloat = 4
    /// Set by the view so pan can be clamped to the on-screen video bounds.
    var contentSize: CGSize = .zero

    // MARK: AVFoundation
    let encodedPlayer = AVQueuePlayer()
    let originalPlayer = AVQueuePlayer()
    private var encodedLooper: AVPlayerLooper?
    private var originalLooper: AVPlayerLooper?
    private let clock = CMClockGetHostTimeClock()
    private var statusObservations: [NSKeyValueObservation] = []
    private var resyncObserver: Any?
    private var started = false          // encode kicked off
    private var playbackStarted = false  // synced playback issued once both ready

    // MARK: engine
    private let transcoder = TVCTranscoder()
    private var previewURL: URL?
    private var audioSessionActive = false

    private var previewTime: CMTime {
        CMTime(seconds: Self.previewSeconds, preferredTimescale: 600)
    }
    /// Actual shared loop length (≤ previewSeconds), set once assets are loaded.
    private var loopSeconds: Double = PreviewController.previewSeconds

    // MARK: - lifecycle

    func start(job: EncodeJob) {
        guard !started else { return }
        started = true

        let out = Self.previewDir()
            .appendingPathComponent("preview_\(job.inputURL.deletingPathExtension().lastPathComponent).mp4")
        try? FileManager.default.removeItem(at: out)
        previewURL = out

        let o = TVCEncodeOptions()
        o.inputPath = job.inputURL.path
        o.outputPath = out.path
        o.videoMode = job.settings.videoAction.tvc
        o.audioMode = job.settings.audioAction.tvc
        o.crf = Int(job.settings.crf)
        // Fastest x265 preset — the preview trades a little quality/size fidelity
        // (preset affects both) for speed. CRF/mode/audio still match the real job.
        o.preset = X265Preset.ultrafast.rawValue
        o.audioProfile = job.settings.audioProfile.tvc
        o.audioBitrate = job.settings.audioBitrateKbps * 1000
        o.forceEightBit = job.settings.forceEightBit
        o.durationLimitSeconds = Self.previewSeconds

        transcoder.onProgress = { [weak self] processed, total, _, _, _, _ in
            guard let self, total > 0 else { return }
            self.encodeFraction = min(1, processed / total)
        }
        transcoder.onFinished = { [weak self] success, error in
            guard let self else { return }
            if success { self.buildPlayers(originalURL: job.inputURL, encodedURL: out) }
            else { self.phase = .failed(error ?? "Preview encode failed.") }
        }
        transcoder.start(with: o)
    }

    /// Cancel/clean up everything. Safe to call multiple times.
    func teardown() {
        transcoder.cancel()
        encodedPlayer.pause()
        originalPlayer.pause()
        statusObservations.forEach { $0.invalidate() }
        statusObservations.removeAll()
        if let resyncObserver { encodedPlayer.removeTimeObserver(resyncObserver) }
        resyncObserver = nil
        encodedLooper = nil
        originalLooper = nil
        encodedPlayer.removeAllItems()
        originalPlayer.removeAllItems()
        if audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            audioSessionActive = false
        }
        if let previewURL { try? FileManager.default.removeItem(at: previewURL) }
    }

    // MARK: - player setup

    private func buildPlayers(originalURL: URL, encodedURL: URL) {
        Task { @MainActor in
            // Load keys up front so the first loop cycle doesn't stall.
            let encodedAsset = AVURLAsset(url: encodedURL)
            let originalAsset = AVURLAsset(url: originalURL)
            let encDur = (try? await encodedAsset.load(.duration))?.seconds ?? Self.previewSeconds
            let origDur = (try? await originalAsset.load(.duration))?.seconds ?? Self.previewSeconds
            await self.computeAspect(from: originalAsset)

            // Loop BOTH players over the exact same window so they wrap in lockstep
            // (an encoded clip that came out slightly ≠ 5 s would otherwise wrap at a
            // different instant than the original and desync every cycle — the jump
            // near the loop point). Clamp to whatever is actually available.
            let loop = max(0.1, min(min(encDur, origDur), Self.previewSeconds))
            self.loopSeconds = loop
            let range = CMTimeRange(start: .zero, duration: CMTime(seconds: loop, preferredTimescale: 600))

            let encodedItem = AVPlayerItem(asset: encodedAsset)
            let originalItem = AVPlayerItem(asset: originalAsset)

            self.configureAudioSession()

            self.encodedPlayer.automaticallyWaitsToMinimizeStalling = false
            self.originalPlayer.automaticallyWaitsToMinimizeStalling = false
            self.encodedPlayer.masterClock = self.clock
            self.originalPlayer.masterClock = self.clock
            self.encodedPlayer.isMuted = false      // preview audio audible
            self.originalPlayer.isMuted = true       // avoid double audio on compare

            self.encodedLooper = AVPlayerLooper(player: self.encodedPlayer,
                                                templateItem: encodedItem, timeRange: range)
            self.originalLooper = AVPlayerLooper(player: self.originalPlayer,
                                                 templateItem: originalItem, timeRange: range)

            self.observeReadyThenStart()
            self.phase = .ready
        }
    }

    private func computeAspect(from asset: AVURLAsset) async {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return }
        let display = size.applying(transform)
        let w = abs(display.width), h = abs(display.height)
        if w > 0, h > 0 { aspectRatio = w / h }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            audioSessionActive = true
        } catch {
            audioSessionActive = false
        }
    }

    /// Start both players at the same media time on the same host clock, once both
    /// have a ready item — the key to frame-accurate sync.
    private func observeReadyThenStart() {
        let tryStart: () -> Void = { [weak self] in
            guard let self, !self.playbackStarted,
                  self.encodedPlayer.status == .readyToPlay,
                  self.originalPlayer.status == .readyToPlay else { return }
            self.playbackStarted = true
            self.startSynced()
            self.installResync()
        }
        statusObservations = [encodedPlayer, originalPlayer].map { player in
            player.observe(\.status, options: [.initial, .new]) { _, _ in tryStart() }
        }
    }

    private func startSynced() {
        let host = CMClockGetTime(clock)
        let at = CMTimeAdd(host, CMTime(seconds: 0.15, preferredTimescale: 600))
        encodedPlayer.setRate(1, time: .zero, atHostTime: at)
        originalPlayer.setRate(1, time: .zero, atHostTime: at)
    }

    /// While the original is hidden, continuously re-lock it to the encoded player
    /// so the two loops stay at the same timestamp — the instant the user holds to
    /// compare, both are on the same frame. Skipped while comparing so we never
    /// nudge the original the user is actually looking at.
    private func installResync() {
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        // Re-anchoring takes effect `lead` seconds from now; aim the original at
        // where the encoded WILL be by then, or it lands `lead` seconds behind.
        let lead = CMTime(seconds: 0.08, preferredTimescale: 600)
        resyncObserver = encodedPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            guard let self, !self.isComparing,
                  self.encodedPlayer.timeControlStatus == .playing else { return }
            let loop = self.loopSeconds
            let enc = self.encodedPlayer.currentTime().seconds
            let orig = self.originalPlayer.currentTime().seconds
            // Fold the difference into ±loop/2 so being on opposite sides of the wrap
            // (e.g. enc 0.02 vs orig 4.98) reads as a tiny drift, not a full loop.
            var drift = (enc - orig).truncatingRemainder(dividingBy: loop)
            if drift > loop / 2 { drift -= loop }
            else if drift < -loop / 2 { drift += loop }
            if abs(drift) > 0.03 {
                let at = CMTimeAdd(CMClockGetTime(self.clock), lead)
                // Where the encoded will be at host time `at`, wrapped into the loop.
                let targetSec = (enc + lead.seconds).truncatingRemainder(dividingBy: loop)
                let target = CMTime(seconds: targetSec, preferredTimescale: 600)
                self.originalPlayer.setRate(1, time: target, atHostTime: at)
            }
        }
    }

    // MARK: - gesture intents

    func applyMagnify(_ magnification: CGFloat) {
        scale = min(max(committedScale * magnification, 1), maxScale)
        if scale <= 1 { panOffset = .zero }
    }
    func commitMagnify() {
        committedScale = scale
        if scale <= 1 { resetZoom() } else { panOffset = clampedPan(panOffset) }
    }

    /// Toggle between 1x and 2x. The caller wraps this in `withAnimation`.
    func toggleZoom() {
        if scale > 1 {
            resetZoom()
        } else {
            scale = 2; committedScale = 2
            panOffset = .zero; committedOffset = .zero
        }
    }

    func applyPan(_ translation: CGSize) {
        guard scale > 1 else { return }
        panOffset = clampedPan(CGSize(width: committedOffset.width + translation.width,
                                      height: committedOffset.height + translation.height))
    }
    func commitPan() { committedOffset = panOffset }

    private func resetZoom() {
        scale = 1; committedScale = 1
        panOffset = .zero; committedOffset = .zero
    }

    /// Keep the scaled content from being dragged past its own edges.
    private func clampedPan(_ offset: CGSize) -> CGSize {
        guard scale > 1, contentSize.width > 0 else { return offset }
        let maxX = (contentSize.width * scale - contentSize.width) / 2
        let maxY = (contentSize.height * scale - contentSize.height) / 2
        return CGSize(width: min(max(offset.width, -maxX), maxX),
                      height: min(max(offset.height, -maxY), maxY))
    }

    // MARK: - paths
    private static func previewDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}
