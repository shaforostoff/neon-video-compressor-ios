//
//  ProgressView2.swift
//  Screen 2: live progress, pause/resume/cancel, background handling, result.
//
import SwiftUI
import Photos

struct ProgressView2: View {
    let job: EncodeJob

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var session = EncodeSession()
    @State private var started = false
    @State private var savedToPhotos = false
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 24) {
            switch session.phase {
            case .running, .paused: activeView
            case .finished:         resultView
            case .failed(let msg):  failView(msg)
            case .cancelled:        cancelledView
            }
        }
        .padding()
        .navigationTitle("Converting")
        .navigationBarBackButtonHidden(isBusy)
        .onAppear {
            guard !started else { return }
            started = true
            session.start(job: job)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: session.didEnterBackground()
            case .active:     session.willEnterForeground()
            default: break
            }
        }
    }

    private var isBusy: Bool {
        session.phase == .running || session.phase == .paused
    }

    // MARK: active

    private var activeView: some View {
        VStack(spacing: 20) {
            ProgressView(value: session.fraction)
                .progressViewStyle(.linear)

            HStack {
                Text("\(timeString(session.processedSeconds)) / \(timeString(session.totalSeconds))")
                Spacer()
                Text(String(format: "%.1f× realtime", session.speed)).monospacedDigit()
            }
            .font(.subheadline).foregroundStyle(.secondary)

            if let eta = session.etaSeconds {
                Text("About \(timeString(eta)) remaining")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                if session.phase == .paused {
                    Button { session.resume() } label: {
                        Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent)
                } else {
                    Button { session.pause() } label: {
                        Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered)
                }
                Button(role: .destructive) { session.cancel() } label: {
                    Label("Cancel", systemImage: "xmark").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered)
            }

            Label("Long conversions may not finish while the app is in the background — return to the app to keep going.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: result

    private var resultView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56)).foregroundStyle(.green)
            Text("Done").font(.title2).bold()
            if let url = session.outputURL {
                Text(url.lastPathComponent).font(.footnote).foregroundStyle(.secondary)
                Text(fileSize(url)).font(.footnote).foregroundStyle(.secondary)

                ShareLink(item: url) {
                    Label("Share / Save to Files", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)

                Button {
                    saveToPhotos(url)
                } label: {
                    Label(savedToPhotos ? "Saved to Photos" : "Save to Photos",
                          systemImage: savedToPhotos ? "checkmark" : "photo.badge.plus")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).disabled(savedToPhotos)
            }
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
            Button("Convert another") { dismiss() }.padding(.top, 8)
        }
    }

    private func failView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.octagon.fill").font(.system(size: 48)).foregroundStyle(.red)
            Text("Conversion failed").font(.title3).bold()
            Text(msg).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Back") { dismiss() }
        }
    }

    private var cancelledView: some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.circle").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Cancelled").font(.title3)
            Button("Back") { dismiss() }
        }
    }

    // MARK: helpers

    private func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { saveError = "Photos access denied." }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset()
                    .addResource(with: .video, fileURL: url, options: nil)
            } completionHandler: { ok, err in
                DispatchQueue.main.async {
                    if ok { savedToPhotos = true }
                    else { saveError = err?.localizedDescription ?? "Save failed." }
                }
            }
        }
    }

    private func timeString(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "0:00" }
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
    private func fileSize(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
