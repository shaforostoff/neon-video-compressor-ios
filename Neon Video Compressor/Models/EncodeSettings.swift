//
//  EncodeSettings.swift
//  User-facing encoding options, mapped to the engine's TVCEncodeOptions.
//
import Foundation

enum ConversionMode: String, CaseIterable, Identifiable, Hashable {
    case both       = "Video + Audio"
    case videoOnly  = "Video only (copy audio)"
    case audioOnly  = "Audio only (copy video)"
    var id: String { rawValue }

    var videoMode: TVCStreamMode { self == .audioOnly ? .copy : .encode }
    var audioMode: TVCStreamMode { self == .videoOnly ? .copy : .encode }
    var encodesVideo: Bool { videoMode == .encode }
    var encodesAudio: Bool { audioMode == .encode }
}

enum X265Preset: String, CaseIterable, Identifiable, Hashable {
    case ultrafast, superfast, veryfast, faster, fast
    case medium, slow, slower, veryslow, placebo
    var id: String { rawValue }
}

enum AudioProfileOption: String, CaseIterable, Identifiable, Hashable {
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

struct EncodeSettings: Hashable {
    var mode: ConversionMode = .both
    var crf: Double = 30
    var preset: X265Preset = .slow
    var audioProfile: AudioProfileOption = .heAAC
    var audioBitrateKbps: Int = 40

    static let bitrateChoices = [24, 32, 40, 48, 64, 96, 128]
}

/// A fully-specified job handed to the progress screen.
struct EncodeJob: Hashable {
    let inputURL: URL
    let outputURL: URL
    let settings: EncodeSettings
    let totalSeconds: Double
}
