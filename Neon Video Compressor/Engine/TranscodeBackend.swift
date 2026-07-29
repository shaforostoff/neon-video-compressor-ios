//
//  TranscodeBackend.swift
//  A single interface over the two encoders the app can run:
//
//    • FFmpegBackend      — libx265, software, CRF-based (the original engine)
//    • HardwareTranscoder — VideoToolbox, hardware, bitrate/QP-based
//
//  Both call sites (EncodeSession, PreviewController) talk to this protocol so
//  switching encoders is a one-line choice rather than a parallel code path.
//
import Foundation

struct TranscodeProgress {
    var processedSeconds: Double = 0
    var totalSeconds: Double = 0
    var speed: Double = 0
    var inputBytes: Int64 = 0
    var totalInputBytes: Int64 = 0
    var outputBytes: Int64 = 0
}

struct BackendOptions {
    var inputURL: URL
    var outputURL: URL
    var settings: EncodeSettings
    /// Stop after N seconds (0 = whole file). Used by the 5 s A/B preview.
    var durationLimitSeconds: Double = 0
    /// Preview mode: trade quality for speed (x265 `ultrafast`, VT speed-priority)
    /// so the A/B comparison appears quickly.
    var favorSpeed: Bool = false
}

protocol TranscodeBackend: AnyObject {
    /// Fired on the main queue, ~5×/sec.
    var onProgress: ((TranscodeProgress) -> Void)? { get set }
    /// Fired on the main queue exactly once. `notes` carries per-property results
    /// from the hardware encoder (which quality knobs it accepted or rejected);
    /// it is always empty for the ffmpeg backend.
    var onFinished: ((Bool, String?, [String]) -> Void)? { get set }

    func start(_ options: BackendOptions)
    func pause()
    func resume()
    func cancel()
    func setThrottled(_ on: Bool)
}

/// Pick the encoder for a job. VideoToolbox only handles the case where we are
/// actually encoding video — copy/remove is pure muxing, which ffmpeg already
/// does (and does for the audio track in every case).
func makeTranscodeBackend(for settings: EncodeSettings) -> TranscodeBackend {
    if settings.videoEncoder == .videoToolbox, settings.videoAction == .encode {
        return HardwareTranscoder()
    }
    return FFmpegBackend()
}

/// Adapts the existing Objective-C/C++ ffmpeg + libx265 engine to the protocol.
final class FFmpegBackend: TranscodeBackend {
    var onProgress: ((TranscodeProgress) -> Void)?
    var onFinished: ((Bool, String?, [String]) -> Void)?

    private let transcoder = TVCTranscoder()

    func start(_ options: BackendOptions) {
        let s = options.settings
        let o = TVCEncodeOptions()
        o.inputPath = options.inputURL.path
        o.outputPath = options.outputURL.path
        o.videoMode = s.videoAction.tvc
        o.audioMode = s.audioAction.tvc
        o.crf = Int(s.crf)
        o.preset = options.favorSpeed ? X265Preset.ultrafast.rawValue : s.preset.rawValue
        o.audioProfile = s.audioProfile.tvc
        o.audioBitrate = s.audioBitrateKbps * 1000
        o.forceEightBit = s.forceEightBit
        o.durationLimitSeconds = options.durationLimitSeconds

        transcoder.onProgress = { [weak self] processed, total, speed, inBytes, totalIn, outBytes in
            self?.onProgress?(TranscodeProgress(processedSeconds: processed,
                                                totalSeconds: total,
                                                speed: speed,
                                                inputBytes: inBytes,
                                                totalInputBytes: totalIn,
                                                outputBytes: outBytes))
        }
        transcoder.onFinished = { [weak self] success, error in
            self?.onFinished?(success, error, [])
        }
        transcoder.start(with: o)
    }

    func pause()  { transcoder.pause() }
    func resume() { transcoder.resume() }
    func cancel() { transcoder.cancel() }
    func setThrottled(_ on: Bool) { transcoder.setThrottled(on) }
}
