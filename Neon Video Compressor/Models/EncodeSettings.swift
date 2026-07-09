//
//  EncodeSettings.swift
//  User-facing encoding options, mapped to the engine's TVCEncodeOptions.
//
import Foundation

enum ConversionMode: String, CaseIterable, Identifiable, Hashable, Codable {
    case both       = "Video + Audio"
    case videoOnly  = "Video only (copy audio)"
    case audioOnly  = "Audio only (copy video)"
    var id: String { rawValue }

    var videoMode: TVCStreamMode { self == .audioOnly ? .copy : .encode }
    var audioMode: TVCStreamMode { self == .videoOnly ? .copy : .encode }
    var encodesVideo: Bool { videoMode == .encode }
    var encodesAudio: Bool { audioMode == .encode }
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

struct EncodeSettings: Hashable, Codable {
    var mode: ConversionMode = .both
    var crf: Double = 30
    var preset: X265Preset = .slow
    var audioProfile: AudioProfileOption = .heAAC
    var audioBitrateKbps: Int = 40
    /// Downgrade 10/12-bit (HDR) sources to 8-bit output — smaller files and
    /// wider compatibility at the cost of color depth. Off = match the source.
    var forceEightBit: Bool = false

    static let bitrateChoices = [24, 32, 40, 48, 64, 96, 128]

    init() {}

    // Decode leniently so adding a new option doesn't discard a user's saved
    // settings — any missing key falls back to its default.
    enum CodingKeys: String, CodingKey {
        case mode, crf, preset, audioProfile, audioBitrateKbps, forceEightBit
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(ConversionMode.self, forKey: .mode) ?? .both
        crf = try c.decodeIfPresent(Double.self, forKey: .crf) ?? 30
        preset = try c.decodeIfPresent(X265Preset.self, forKey: .preset) ?? .slow
        audioProfile = try c.decodeIfPresent(AudioProfileOption.self, forKey: .audioProfile) ?? .heAAC
        audioBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .audioBitrateKbps) ?? 40
        forceEightBit = try c.decodeIfPresent(Bool.self, forKey: .forceEightBit) ?? false
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
