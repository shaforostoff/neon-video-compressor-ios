//
//  EncodeSettings.swift
//  User-facing encoding options, mapped to the engine's TVCEncodeOptions.
//
import Foundation

/// What to do with a single stream (video or audio).
enum StreamAction: String, CaseIterable, Identifiable, Hashable, Codable {
    case encode = "Encode"
    case copy   = "Copy"
    case remove = "Remove"
    var id: String { rawValue }

    var tvc: TVCStreamMode {
        switch self {
        case .encode: return .encode
        case .copy:   return .copy
        case .remove: return .remove
        }
    }
}

enum X265Preset: String, CaseIterable, Identifiable, Hashable, Codable {
    case ultrafast, superfast, veryfast, faster, fast
    case medium, slow, slower, veryslow, placebo
    var id: String { rawValue }
}

enum AudioProfileOption: String, CaseIterable, Identifiable, Hashable, Codable {
    case aacLC  = "AAC-LC"
    case heAAC  = "HE-AAC"
    case heAACv2 = "HE-AAC v2"
    var id: String { rawValue }

    var tvc: TVCAudioProfile {
        switch self {
        case .aacLC:   return .lowComplexity
        case .heAAC:   return .highEfficiency
        case .heAACv2: return .highEfficiencyV2
        }
    }
}

/// Which encoder produces the HEVC video track.
enum VideoEncoderKind: String, CaseIterable, Identifiable, Hashable, Codable {
    /// libx265 via ffmpeg — software, CRF-based, slow but best quality per byte.
    case x265 = "HEVC (x265)"
    /// VideoToolbox — the hardware block. Much faster, coarser quality control.
    case videoToolbox = "HEVC (HW accelerated)"
    var id: String { rawValue }
}

/// How the VideoToolbox encoder is told what quality to aim for.
///
/// Only `averageBitrate` is documented by Apple as universally supported on iOS.
/// The rest are exposed so they can be tried on real hardware — VideoToolbox
/// returns `kVTPropertyNotSupportedErr` for knobs the current encoder doesn't
/// implement, and `HardwareTranscoder` reports that back to the UI.
enum VTRateControl: String, CaseIterable, Identifiable, Hashable, Codable {
    /// kVTCompressionPropertyKey_Quality — the closest analogue to CRF.
    case constantQuality = "Constant quality"
    /// kVTCompressionPropertyKey_AverageBitRate — ABR, the safe baseline.
    case averageBitrate = "Average bitrate"
    /// kVTCompressionPropertyKey_ConstantBitRate — true CBR (iOS 16+, HW only).
    case constantBitrate = "Constant bitrate"
    /// ABR plus MaxAllowedFrameQP/MinAllowedFrameQP — bitrate target with a
    /// quality floor, the most CRF-like combination that Apple documents on iOS.
    case bitrateWithQPCap = "Bitrate + QP cap"
    /// Quality plus DataRateLimits — constant quality with a hard ceiling.
    case qualityWithCap = "Quality + hard cap"
    var id: String { rawValue }
}

struct EncodeSettings: Hashable, Codable {
    var videoAction: StreamAction = .encode
    var audioAction: StreamAction = .encode
    var videoEncoder: VideoEncoderKind = .x265
    var crf: Double = 30
    var preset: X265Preset = .slow
    var audioProfile: AudioProfileOption = .heAAC
    var audioBitrateKbps: Int = 40
    /// Downgrade 10/12-bit (HDR) sources to 8-bit output — smaller files and
    /// wider compatibility at the cost of color depth. Off = match the source.
    var forceEightBit: Bool = false

    // MARK: VideoToolbox knobs (ignored when videoEncoder == .x265)

    var vtRateControl: VTRateControl = .averageBitrate
    /// 0…1 for kVTCompressionPropertyKey_Quality. Higher = better.
    var vtQuality: Double = 0.65
    /// Target for ABR/CBR modes.
    var vtBitrateMbps: Double = 8
    /// Ceiling for `qualityWithCap`, as a multiple of the bitrate target.
    var vtCapMultiplier: Double = 1.5
    /// MaxAllowedFrameQP — the quality floor. HEVC QP range is 1…51.
    var vtMaxQP: Int = 40
    /// MinAllowedFrameQP — the quality ceiling. 0 = leave unset.
    var vtMinQP: Int = 0
    /// Keyframe interval in seconds. 0 = let the encoder decide.
    var vtKeyframeSeconds: Double = 2
    /// B-frames (kVTCompressionPropertyKey_AllowFrameReordering).
    var vtAllowFrameReordering: Bool = true
    /// kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality.
    var vtPrioritizeSpeed: Bool = false
    /// kVTCompressionPropertyKey_MaximizePowerEfficiency.
    var vtPowerEfficient: Bool = false

    static let bitrateChoices = [24, 32, 40, 48, 64, 96, 128]

    /// True when the CRF/preset controls apply — x265 only. VideoToolbox has no
    /// CRF mode, so those controls are hidden for it.
    var usesCRF: Bool { videoEncoder == .x265 }

    init() {}

    // Decode leniently so adding a new option doesn't discard a user's saved
    // settings — any missing key falls back to its default.
    enum CodingKeys: String, CodingKey {
        case videoAction, audioAction, videoEncoder, crf, preset, audioProfile
        case audioBitrateKbps, forceEightBit
        case vtRateControl, vtQuality, vtBitrateMbps, vtCapMultiplier
        case vtMaxQP, vtMinQP, vtKeyframeSeconds, vtAllowFrameReordering
        case vtPrioritizeSpeed, vtPowerEfficient
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoAction = try c.decodeIfPresent(StreamAction.self, forKey: .videoAction) ?? .encode
        audioAction = try c.decodeIfPresent(StreamAction.self, forKey: .audioAction) ?? .encode
        videoEncoder = try c.decodeIfPresent(VideoEncoderKind.self, forKey: .videoEncoder) ?? .x265
        crf = try c.decodeIfPresent(Double.self, forKey: .crf) ?? 30
        preset = try c.decodeIfPresent(X265Preset.self, forKey: .preset) ?? .slow
        audioProfile = try c.decodeIfPresent(AudioProfileOption.self, forKey: .audioProfile) ?? .heAAC
        audioBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .audioBitrateKbps) ?? 40
        forceEightBit = try c.decodeIfPresent(Bool.self, forKey: .forceEightBit) ?? false
        vtRateControl = try c.decodeIfPresent(VTRateControl.self, forKey: .vtRateControl) ?? .averageBitrate
        vtQuality = try c.decodeIfPresent(Double.self, forKey: .vtQuality) ?? 0.65
        vtBitrateMbps = try c.decodeIfPresent(Double.self, forKey: .vtBitrateMbps) ?? 8
        vtCapMultiplier = try c.decodeIfPresent(Double.self, forKey: .vtCapMultiplier) ?? 1.5
        vtMaxQP = try c.decodeIfPresent(Int.self, forKey: .vtMaxQP) ?? 40
        vtMinQP = try c.decodeIfPresent(Int.self, forKey: .vtMinQP) ?? 0
        vtKeyframeSeconds = try c.decodeIfPresent(Double.self, forKey: .vtKeyframeSeconds) ?? 2
        vtAllowFrameReordering = try c.decodeIfPresent(Bool.self, forKey: .vtAllowFrameReordering) ?? true
        vtPrioritizeSpeed = try c.decodeIfPresent(Bool.self, forKey: .vtPrioritizeSpeed) ?? false
        vtPowerEfficient = try c.decodeIfPresent(Bool.self, forKey: .vtPowerEfficient) ?? false
    }

    // MARK: persistence — remembers the user's last-chosen options across launches.

    private static let defaultsKey = "EncodeSettings.saved"

    static func loadSaved() -> EncodeSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(EncodeSettings.self, from: data)
        else { return EncodeSettings() }
        return saved
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

/// A fully-specified job handed to the progress screen.
struct EncodeJob: Hashable, Identifiable {
    let id = UUID()
    let inputURL: URL
    let outputURL: URL
    let settings: EncodeSettings
    let totalSeconds: Double
    /// Photos `localIdentifier` of the source asset, when imported from Photos.
    /// nil for Files imports — enables the "Replace original" flow.
    var sourceAssetID: String? = nil
}
