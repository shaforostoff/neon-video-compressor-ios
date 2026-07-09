//
//  SetupView.swift
//  Screen 1: pick a video (Photos or Files) and choose encoding options.
//
import SwiftUI
import Photos
import PhotosUI
import UniformTypeIdentifiers

struct SetupView: View {
    @State private var settings = EncodeSettings.loadSaved()
    @State private var inputURL: URL?
    @State private var info: TVCMediaInfo?
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
                optionsSection
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
                if !info.audioCodec.isEmpty {
                    LabeledContent("Audio",
                        value: "\(info.audioChannels)ch · \(info.audioSampleRate/1000)kHz")
                }
            }
        }
    }

    private var optionsSection: some View {
        Section("What to convert") {
            Picker("Streams", selection: $settings.mode) {
                ForEach(ConversionMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    @ViewBuilder private var videoSection: some View {
        if settings.mode.encodesVideo {
            Section("Video — HEVC (libx265, tag hvc1)") {
                VStack(alignment: .leading) {
                    HStack {
                        Text("CRF (quality)")
                        Spacer()
                        Text("\(Int(settings.crf))").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.crf, in: 0...51, step: 1)
                    Text("Lower = better quality, larger file. 28–32 is typical.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Preset", selection: $settings.preset) {
                    ForEach(X265Preset.allCases) { Text($0.rawValue).tag($0) }
                }
            }
        } else {
            Section("Video") { Text("Copied without re-encoding").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var audioSection: some View {
        if settings.mode.encodesAudio {
            Section("Audio — AAC (AudioToolbox)") {
                Picker("Profile", selection: $settings.audioProfile) {
                    ForEach(AudioProfileOption.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Bitrate", selection: $settings.audioBitrateKbps) {
                    ForEach(EncodeSettings.bitrateChoices, id: \.self) { Text("\($0) kbps").tag($0) }
                }
            }
        } else {
            Section("Audio") { Text("Copied without re-encoding").foregroundStyle(.secondary) }
        }
    }

    private var convertSection: some View {
        Section {
            TextField("Output name", text: $baseName)
                .textInputAutocapitalization(.never)
            if let job = buildJob() {
                Button { previewJob = job } label: {
                    Label("Preview first 5s", systemImage: "eye")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                NavigationLink(value: job) {
                    Label("Convert", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
            }
        } footer: {
            Text("Output: \(baseName)_hevc.mp4 with +faststart, saved to the app's Documents.")
        }
    }

    // MARK: loading

    private func loadPhotoItem(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        loading = true; loadError = nil
        defer { loading = false }
        do {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                loadError = "Could not load that video."
                return
            }
            // Probe off the main thread so reading the file header doesn't hitch the UI.
            let probed = await Task.detached { TVCTranscoder.probe(movie.url.path) }.value
            sourceAssetID = item.itemIdentifier   // localIdentifier, for "Replace original"
            adopt(url: movie.url, info: probed)
        } catch {
            loadError = error.localizedDescription
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
            adopt(url: dst, info: probed)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func adopt(url: URL, info probed: TVCMediaInfo) {
        inputURL = url
        baseName = url.deletingPathExtension().lastPathComponent
        info = probed
        if !probed.ok { loadError = probed.error ?? "Unsupported file." }
    }

    private func buildJob() -> EncodeJob? {
        guard let inputURL, let info, info.ok else { return nil }
        let safe = baseName.isEmpty ? "video" : baseName
        let out = Self.docsDir().appendingPathComponent("\(safe)_hevc.mp4")
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
