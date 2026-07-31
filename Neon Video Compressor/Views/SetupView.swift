//
//  SetupView.swift
//  Screen 1: pick a video (Photos or Files) and choose encoding options.
//
import SwiftUI
import AVFoundation
import Photos
import PhotosUI
import UniformTypeIdentifiers

struct SetupView: View {
    @State private var settings = EncodeSettings.loadSaved()
    @State private var inputURL: URL?
    @State private var info: TVCMediaInfo?
    /// Data rate of the source's video track, in Mbps. Caps the bitrate slider —
    /// nil when it can't be determined, which falls back to an absolute ceiling.
    @State private var sourceBitrateMbps: Double?
    @State private var baseName: String = "video"

    @State private var photoItem: PhotosPickerItem?
    @State private var sourceAssetID: String?   // Photos localIdentifier of the picked video
    @State private var showFileImporter = false
    @State private var loading = false
    @State private var loadError: String?
    @State private var previewJob: EncodeJob?

    var body: some View {
        Form {
            sourceSection
            if inputURL != nil {
                videoSection
                audioSection
                convertSection
            }
        }
        .navigationTitle("Neon Compressor")
        .onChange(of: photoItem) { _, item in Task { await loadPhotoItem(item) } }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie, .video],
                      allowsMultipleSelection: false) { handleFileImport($0) }
        .fullScreenCover(item: $previewJob) { job in
            PreviewCompareView(job: job)
        }
        .onChange(of: settings) { _, newValue in newValue.save() }
    }

    // MARK: sections

    private var sourceSection: some View {
        Section("Source") {
            HStack {
                PhotosPicker(selection: $photoItem, matching: .videos,
                             photoLibrary: .shared()) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
                Spacer()
                Button { showFileImporter = true } label: {
                    Label("Files", systemImage: "folder")
                }
            }
            if loading { ProgressView("Loading…") }
            if let loadError { Text(loadError).foregroundStyle(.red).font(.footnote) }
            if let info {
                LabeledContent("Duration", value: timeString(info.durationSeconds))
                if info.videoWidth > 0 {
                    LabeledContent("Video", value: "\(info.videoWidth)×\(info.videoHeight)")
                }
                if let sourceBitrateMbps {
                    LabeledContent("Bitrate",
                        value: String(format: "%.1f Mbps", sourceBitrateMbps))
                }
                if !info.audioCodec.isEmpty {
                    LabeledContent("Audio",
                        value: "\(info.audioChannels)ch · \(info.audioSampleRate/1000)kHz")
                }
            }
        }
    }

    @ViewBuilder private var videoSection: some View {
        Section("Video") {
            Picker("Mode", selection: $settings.videoAction) {
                ForEach(StreamAction.allCases) { Text($0.rawValue).tag($0) }
            }
            switch settings.videoAction {
            case .encode:
                Picker("Encoder", selection: $settings.videoEncoder) {
                    ForEach(VideoEncoderKind.allCases) { Text($0.rawValue).tag($0) }
                }
                switch settings.videoEncoder {
                case .x265:      x265Controls
                case .videoToolbox: videoToolboxControls
                }
                Picker("Bit depth", selection: $settings.forceEightBit) {
                    Text("Match source").tag(false)
                    Text("Force 8-bit").tag(true)
                }
                Text("10-bit preserves HDR and smooth gradients; 8-bit is smaller and more widely compatible.")
                    .font(.caption).foregroundStyle(.secondary)
            case .copy:
                Text("Kept as-is, not re-encoded.").font(.caption).foregroundStyle(.secondary)
            case .remove:
                Text("Dropped — output is audio-only (.m4a).").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// CRF + preset — software x265 only. VideoToolbox has no CRF mode, which is
    /// why these controls are scoped to this branch.
    @ViewBuilder private var x265Controls: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("CRF (quality)")
                Spacer()
                Text("\(Int(settings.crf))").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $settings.crf, in: 0...51, step: 1)
            Text("HEVC (libx265, tag hvc1). Lower CRF = better quality, larger file. 28–32 is typical.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Picker("Preset", selection: $settings.preset) {
            ForEach(X265Preset.allCases) { Text($0.rawValue).tag($0) }
        }
    }

    /// VideoToolbox quality knobs. Several of these are undocumented or
    /// unsupported on iOS hardware — the result screen reports which ones the
    /// encoder actually accepted, so the duds can be identified and removed.
    @ViewBuilder private var videoToolboxControls: some View {
        Picker("Rate control", selection: $settings.vtRateControl) {
            ForEach(VTRateControl.allCases) { Text($0.rawValue).tag($0) }
        }
        Text(rateControlHelp).font(.caption).foregroundStyle(.secondary)

        // Quality slider — only the two Quality-based modes use it.
        if settings.vtRateControl == .constantQuality || settings.vtRateControl == .qualityWithCap {
            VStack(alignment: .leading) {
                HStack {
                    Text("Quality")
                    Spacer()
                    Text(String(format: "%.2f", settings.vtQuality))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $settings.vtQuality, in: 0...1, step: 0.05)
            }
        }

        // Bitrate — every mode except pure constant quality.
        if settings.vtRateControl != .constantQuality {
            VStack(alignment: .leading) {
                HStack {
                    Text(settings.vtRateControl == .qualityWithCap ? "Hard cap" : "Bitrate")
                    Spacer()
                    Text(String(format: "%.1f Mbps", settings.vtBitrateMbps))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $settings.vtBitrateMbps,
                       in: bitrateRange, step: bitrateStep)
                if let sourceBitrateMbps {
                    Text(String(format: "Limited to the source's %.1f Mbps — a higher target can't add back detail the original never had.", sourceBitrateMbps))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }

        if settings.vtRateControl == .qualityWithCap {
            VStack(alignment: .leading) {
                HStack {
                    Text("Cap headroom")
                    Spacer()
                    Text(String(format: "%.1f×", settings.vtCapMultiplier))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $settings.vtCapMultiplier, in: 1...4, step: 0.1)
            }
        }

        if settings.vtRateControl == .bitrateWithQPCap {
            Stepper("Max QP: \(settings.vtMaxQP)", value: $settings.vtMaxQP, in: 1...51)
            Stepper(settings.vtMinQP == 0 ? "Min QP: off" : "Min QP: \(settings.vtMinQP)",
                    value: $settings.vtMinQP, in: 0...51)
            Text("Max QP is the quality floor (lower = better). Apple warns the encoder may drop frames to satisfy both the bitrate and the QP goal — check the output frame count.")
                .font(.caption).foregroundStyle(.secondary)
        }

        VStack(alignment: .leading) {
            HStack {
                Text("Keyframe interval")
                Spacer()
                Text(settings.vtKeyframeSeconds == 0
                     ? "auto"
                     : String(format: "%.0f s", settings.vtKeyframeSeconds))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $settings.vtKeyframeSeconds, in: 0...10, step: 1)
        }

        Toggle("B-frames (frame reordering)", isOn: $settings.vtAllowFrameReordering)
            .disabled(settings.vtRateControl == .constantBitrate)
        Toggle("Prioritize speed over quality", isOn: $settings.vtPrioritizeSpeed)
        Toggle("Maximize power efficiency", isOn: $settings.vtPowerEfficient)
    }

    /// Upper bound for the bitrate slider: the source's own video data rate.
    /// Asking the encoder for more bits than the original carries only inflates
    /// the file. Falls back to a fixed ceiling when the source rate is unknown.
    ///
    /// Rounds *down* to the slider's granularity so the end stop is always at or
    /// below the real source rate, and so a clamped value lands exactly on it.
    /// Both the slider range and the clamp in `adopt` go through here, so they
    /// can't drift apart.
    static func bitrateCeiling(for sourceMbps: Double?) -> Double {
        let raw = (sourceMbps ?? 0) > 0 ? sourceMbps! : 80
        // Never degenerate, or Slider traps on an empty range.
        return max(0.2, (raw * 10).rounded(.down) / 10)
    }

    private var bitrateRange: ClosedRange<Double> {
        0.1...Self.bitrateCeiling(for: sourceBitrateMbps)
    }

    private var bitrateStep: Double {
        Self.bitrateCeiling(for: sourceBitrateMbps) > 20 ? 0.5 : 0.1
    }

    private var rateControlHelp: String {
        switch settings.vtRateControl {
        case .constantQuality:
            return "kVTCompressionPropertyKey_Quality. The closest thing to CRF, but Apple documents it as a JPEG-style knob and never promises HEVC support on iOS — this mode is here to find out whether the hardware honors it."
        case .averageBitrate:
            return "kVTCompressionPropertyKey_AverageBitRate. The only mode Apple documents as broadly supported — the safe baseline."
        case .constantBitrate:
            return "kVTCompressionPropertyKey_ConstantBitRate (iOS 16+). Pads frames to hold the rate, so it wastes space on low-motion scenes. Poor fit for compression; included for completeness."
        case .bitrateWithQPCap:
            return "Average bitrate plus MaxAllowedFrameQP — a bitrate target with a quality floor. The most CRF-like combination Apple actually documents on iOS."
        case .qualityWithCap:
            return "Constant quality plus DataRateLimits, so a busy scene can't run away. Depends on Quality being honored."
        }
    }

    @ViewBuilder private var audioSection: some View {
        Section("Audio") {
            Picker("Mode", selection: $settings.audioAction) {
                ForEach(StreamAction.allCases) { Text($0.rawValue).tag($0) }
            }
            switch settings.audioAction {
            case .encode:
                Picker("Profile", selection: $settings.audioProfile) {
                    ForEach(AudioProfileOption.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Bitrate", selection: $settings.audioBitrateKbps) {
                    ForEach(EncodeSettings.bitrateChoices, id: \.self) { Text("\($0) kbps").tag($0) }
                }
                Text("AAC (AudioToolbox).").font(.caption).foregroundStyle(.secondary)
            case .copy:
                Text("Kept as-is, not re-encoded.").font(.caption).foregroundStyle(.secondary)
            case .remove:
                Text("Dropped — output has no audio.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var convertSection: some View {
        Section {
            TextField("Output name", text: $baseName)
                .textInputAutocapitalization(.never)
            if let job = buildJob() {
                // The A/B preview is a visual compare, so it's meaningless for an
                // audio-only (video removed) output.
                if settings.videoAction != .remove {
                    Button { previewJob = job } label: {
                        Label("Preview first 5s", systemImage: "eye")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                NavigationLink(value: job) {
                    Label("Convert", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
            } else if settings.videoAction == .remove && settings.audioAction == .remove {
                Text("Select at least one stream to keep.")
                    .font(.footnote).foregroundStyle(.red)
            }
        } footer: {
            Text("Output: \(outputFileName) with +faststart, saved to the app's Documents.")
        }
    }

    // MARK: loading

    private func loadPhotoItem(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        loading = true; loadError = nil
        defer { loading = false }

        sourceAssetID = item.itemIdentifier   // localIdentifier, for "Replace original"

        // Fast path: hand the encoder the original library file in place, with no
        // copy at all. Only works for a plain local asset the encoder can open —
        // the probe below is the capability test.
        if let id = item.itemIdentifier,
           let original = await originalFileURL(forAssetID: id) {
            let probed = await Task.detached { TVCTranscoder.probe(original.path) }.value
            if probed.ok {
                await adopt(url: original, info: probed)
                return
            }
            // ffmpeg couldn't read it after all — fall through to the export copy.
        }

        // Fallback: export a temp copy (iCloud, slo-mo/edited, no permission, or
        // an original the sandbox won't let us read directly).
        do {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                loadError = "Could not load that video."
                return
            }
            // Probe off the main thread so reading the file header doesn't hitch the UI.
            let probed = await Task.detached { TVCTranscoder.probe(movie.url.path) }.value
            await adopt(url: movie.url, info: probed)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Resolve a directly-readable file URL for a picked Photos asset so the
    /// encoder can read the original in place — no export, no copy. Returns nil
    /// (caller falls back to copying) when we lack read access, the asset lives
    /// in iCloud, or it's slo-mo/edited/composited (no single backing file).
    private func originalFileURL(forAssetID id: String) async -> URL? {
        guard await requestPhotoReadAccess() == .authorized,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        else { return nil }

        let opts = PHVideoRequestOptions()
        opts.isNetworkAccessAllowed = false          // no iCloud download here — fall back instead
        opts.deliveryMode = .highQualityFormat       // the untranscoded original
        opts.version = .current                      // include edits (edited assets → composition → nil)

        let avAsset: AVAsset? = await withCheckedContinuation { cont in
            var resumed = false
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { av, _, _ in
                if resumed { return }               // requestAVAsset can call back more than once
                resumed = true
                cont.resume(returning: av)
            }
        }
        // AVComposition (slo-mo/edited) has no single URL → nil → export fallback.
        return (avAsset as? AVURLAsset)?.url
    }

    /// Current Photos read/write authorization, prompting once if undetermined.
    private func requestPhotoReadAccess() async -> PHAuthorizationStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { cont.resume(returning: $0) }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let src = urls.first else { return }
            Task { await importFile(src) }
        case .failure(let err):
            loadError = err.localizedDescription
        }
    }

    /// Copy the picked file into our temp dir and probe it, both off the main
    /// thread so the UI stays responsive during the (potentially large) copy.
    private func importFile(_ src: URL) async {
        loading = true; loadError = nil
        defer { loading = false }
        do {
            let dst: URL = try await Task.detached {
                let needsStop = src.startAccessingSecurityScopedResource()
                defer { if needsStop { src.stopAccessingSecurityScopedResource() } }
                let dst = SetupView.tempDir().appendingPathComponent(src.lastPathComponent)
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.copyItem(at: src, to: dst)
                return dst
            }.value
            let probed = await Task.detached { TVCTranscoder.probe(dst.path) }.value
            sourceAssetID = nil   // Files import has no Photos asset to replace
            await adopt(url: dst, info: probed)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func adopt(url: URL, info probed: TVCMediaInfo) async {
        inputURL = url
        baseName = url.deletingPathExtension().lastPathComponent
        info = probed
        if !probed.ok { loadError = probed.error ?? "Unsupported file." }

        // Clamp against the local rate rather than reading @State back, so the new
        // ceiling is definitely the one being applied.
        let rate = await Self.videoBitrateMbps(of: url)
        sourceBitrateMbps = rate
        // A target carried over from a bigger source would now sit past the end of
        // the slider, so bring it back into range.
        let ceiling = Self.bitrateCeiling(for: rate)
        if settings.vtBitrateMbps > ceiling {
            settings.vtBitrateMbps = ceiling
        }
    }

    /// Data rate of the video track in Mbps, or nil if AVFoundation can't
    /// estimate it (which leaves the slider on its fixed ceiling).
    private static func videoBitrateMbps(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let rate = try? await track.load(.estimatedDataRate),
              rate.isFinite, rate > 0
        else { return nil }
        return Double(rate) / 1_000_000
    }

    /// Output filename — audio-only (video removed) is an .m4a, otherwise an .mp4.
    private var outputFileName: String {
        let safe = baseName.isEmpty ? "video" : baseName
        return settings.videoAction == .remove ? "\(safe)_audio.m4a" : "\(safe)_hevc.mp4"
    }

    private func buildJob() -> EncodeJob? {
        guard let inputURL, let info, info.ok else { return nil }
        // At least one stream must be kept.
        guard !(settings.videoAction == .remove && settings.audioAction == .remove) else { return nil }
        let out = Self.docsDir().appendingPathComponent(outputFileName)
        return EncodeJob(inputURL: inputURL, outputURL: out,
                         settings: settings, totalSeconds: info.durationSeconds,
                         sourceAssetID: sourceAssetID)
    }

    // MARK: helpers
    private func timeString(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "—" }
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
    static func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("input", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func docsDir() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}

/// PhotosPicker → temp file URL.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dst = SetupView.tempDir()
                .appendingPathComponent(received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            // The picker already exported the asset to `received.file` (one full
            // copy). Move it rather than copy again to avoid a second full copy.
            do { try FileManager.default.moveItem(at: received.file, to: dst) }
            catch { try FileManager.default.copyItem(at: received.file, to: dst) }
            return PickedMovie(url: dst)
        }
    }
}
