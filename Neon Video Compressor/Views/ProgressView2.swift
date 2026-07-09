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
    @State private var replacedOriginal = false
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

            VStack(spacing: 6) {
                HStack {
                    Label("Memory", systemImage: "memorychip")
                    Spacer()
                    Text(byteString(session.ramBytes)).monospacedDigit()
                }
                HStack {
                    Label("Processed", systemImage: "arrow.right.doc.on.clipboard")
                    Spacer()
                    Text(dataProgressText).monospacedDigit()
                }
            }
            .font(.footnote).foregroundStyle(.secondary)

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

            Toggle(isOn: $session.keepAwake) {
                Label("Keep converting when locked", systemImage: "bolt.fill")
            }
            .font(.subheadline)

            if session.keepAwake {
                Label("Keeps converting while locked (slower, and uses more battery). Return to the app for full speed.",
                      systemImage: "battery.25")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Label("Long conversions may not finish while the app is in the background — return to the app to keep going.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: result

    private var resultView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56)).foregroundStyle(.green)
            Text("Done").font(.title2).bold()
            if savedToPhotos {
                Label(replacedOriginal ? "Replaced original in Photos" : "Saved to Photos",
                      systemImage: "checkmark")
                    .foregroundStyle(.secondary)
                if replacedOriginal {
                    Text("The original moved to Recently Deleted, and frees space once that empties.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else if let url = session.outputURL {
                Text(url.lastPathComponent).font(.footnote).foregroundStyle(.secondary)
                Text(fileSize(url)).font(.footnote).foregroundStyle(.secondary)

                ShareLink(item: url) {
                    Label("Share / Save to Files", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)

                // Photos can't store a bare audio file, so the Photos actions only
                // apply when the output has a video track.
                if job.settings.videoAction != .remove {
                    Button {
                        saveToPhotos(url)
                    } label: {
                        Label("Save to Photos", systemImage: "photo.badge.plus")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered)

                    if let assetID = job.sourceAssetID {
                        Button(role: .destructive) {
                            replaceOriginal(url, assetID: assetID)
                        } label: {
                            Label("Replace original in Photos", systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered)
                    }
                }
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
                    if ok {
                        // The video now lives in Photos — drop the duplicate copy
                        // sitting in the app's Documents folder.
                        session.discardOutput()
                        savedToPhotos = true
                    } else {
                        saveError = err?.localizedDescription ?? "Save failed."
                    }
                }
            }
        }
    }

    /// Save the compressed video to Photos, then delete the source asset it was
    /// made from. Ordered add-then-delete so the compressed copy is safely in
    /// Photos before the original is touched — a declined/failed delete never
    /// costs the user their video. iOS shows its own confirmation for the delete.
    private func replaceOriginal(_ url: URL, assetID: String) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized else {
                DispatchQueue.main.async {
                    saveError = "Full Photos access is needed to replace the original."
                }
                return
            }
            // 1) Add the compressed video.
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset()
                    .addResource(with: .video, fileURL: url, options: nil)
            } completionHandler: { ok, err in
                guard ok else {
                    DispatchQueue.main.async {
                        saveError = err?.localizedDescription ?? "Save failed."
                    }
                    return
                }
                // Compressed copy is in Photos — drop the app's Documents duplicate.
                DispatchQueue.main.async {
                    session.discardOutput()
                    savedToPhotos = true
                }
                // 2) Delete the original (system prompts the user to confirm).
                let originals = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
                guard originals.count > 0 else { return }   // original already gone; leave as saved
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(originals)
                } completionHandler: { delOk, _ in
                    DispatchQueue.main.async {
                        if delOk { replacedOriginal = true }
                        // Declined/failed delete: the compressed copy is still saved,
                        // so the UI simply stays at "Saved to Photos".
                    }
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
    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
    // "12.3 MB of 45 MB → 4.1 MB" (or without the total when it's unknown).
    private var dataProgressText: String {
        let read = byteString(session.inputBytes)
        let written = byteString(session.outputBytes)
        if session.totalInputBytes > 0 {
            return "\(read) of \(byteString(session.totalInputBytes)) → \(written)"
        }
        return "\(read) → \(written)"
    }
}
