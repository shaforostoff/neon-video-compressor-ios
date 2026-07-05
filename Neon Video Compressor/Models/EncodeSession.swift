//
//  EncodeSession.swift
//  Drives a single TVCTranscoder run and owns best-effort background lifecycle.
//
import Foundation
import UIKit
import AVFoundation

@Observable
final class EncodeSession {
    enum Phase: Equatable {
        case running, paused, finished, failed(String), cancelled
    }

    var phase: Phase = .running
    var processedSeconds: Double = 0
    var totalSeconds: Double = 0
    var speed: Double = 0
    var inputBytes: Int64 = 0        // read from the source so far
    var totalInputBytes: Int64 = 0   // total source size (0 if unknown)
    var outputBytes: Int64 = 0       // written to the new file so far
    var ramBytes: Int64 = 0          // app memory footprint, sampled each tick
    private(set) var outputURL: URL?

    /// When on, keep encoding while the screen is locked via a silent audio
    /// session (costs battery). User-controlled from the progress screen.
    var keepAwake: Bool = true {
        didSet { if keepAwake != oldValue { updateKeepAlive() } }
    }

    private let transcoder = TVCTranscoder()
    private let keepAlive = KeepAliveAudio()
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var autoPaused = false

    deinit { keepAlive.stop() }

    var fraction: Double {
        totalSeconds > 0 ? min(1, processedSeconds / totalSeconds) : 0
    }
    var etaSeconds: Double? {
        guard speed > 0.01, totalSeconds > 0 else { return nil }
        return max(0, (totalSeconds - processedSeconds) / speed)
    }

    func start(job: EncodeJob) {
        outputURL = job.outputURL
        totalSeconds = job.totalSeconds

        let o = TVCEncodeOptions()
        o.inputPath = job.inputURL.path
        o.outputPath = job.outputURL.path
        o.videoMode = job.settings.mode.videoMode
        o.audioMode = job.settings.mode.audioMode
        o.crf = Int(job.settings.crf)
        o.preset = job.settings.preset.rawValue
        o.audioProfile = job.settings.audioProfile.tvc
        o.audioBitrate = job.settings.audioBitrateKbps * 1000

        transcoder.onProgress = { [weak self] processed, total, speed, inBytes, totalIn, outBytes in
            guard let self else { return }
            self.processedSeconds = processed
            if total > 0 { self.totalSeconds = total }
            self.speed = speed
            self.inputBytes = inBytes
            if totalIn > 0 { self.totalInputBytes = totalIn }
            self.outputBytes = outBytes
            self.ramBytes = currentMemoryFootprint()
        }
        transcoder.onFinished = { [weak self] success, error in
            guard let self else { return }
            self.endBackgroundTask()
            self.keepAlive.stop()   // encode is over — release the audio session
            if success { self.phase = .finished }
            else if error == "cancelled" { self.phase = .cancelled }
            else { self.phase = .failed(error ?? "Unknown error") }
        }

        phase = .running
        transcoder.start(with: o)
        updateKeepAlive()
    }

    // MARK: user controls
    func pause() { autoPaused = false; transcoder.pause(); phase = .paused }
    func resume() { autoPaused = false; transcoder.resume(); phase = .running }
    func cancel() { transcoder.cancel() }

    // MARK: best-effort background handling
    func didEnterBackground() {
        guard phase == .running else { return }
        // When keep-awake is on, the active audio session keeps us running while
        // locked. Pace the encoder to stay under iOS's background CPU limit
        // (~80%/60s), which otherwise kills the process mid-encode.
        if keepAwake && keepAlive.isActive {
            transcoder.setThrottled(true)
            return
        }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "encode") { [weak self] in
            // The OS is about to suspend us — pause to checkpoint in memory.
            self?.autoPauseForExpiration()
        }
    }

    private func updateKeepAlive() {
        let active = phase == .running || phase == .paused
        if keepAwake && active { keepAlive.start() } else { keepAlive.stop() }
    }

    func willEnterForeground() {
        endBackgroundTask()
        transcoder.setThrottled(false)   // full speed again in the foreground
        if autoPaused {
            autoPaused = false
            resume()
        }
    }

    private func autoPauseForExpiration() {
        autoPaused = true
        transcoder.pause()
        phase = .paused
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }
}

/// Current process memory footprint in bytes — `phys_footprint` is the same
/// figure iOS uses for its per-app memory limit (closer to reality than
/// resident_size). Returns 0 if the query fails.
func currentMemoryFootprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    return Int64(info.phys_footprint)
}

/// Keeps the app running in the background by looping silence through an active
/// audio session — the only reliable on-demand way to keep CPU work going while
/// the screen is locked. Enabled only when the user opts in (battery cost).
final class KeepAliveAudio {
    private var player: AVAudioPlayer?
    private var interruptionObserver: NSObjectProtocol?

    var isActive: Bool { player?.isPlaying ?? false }

    func start() {
        guard player == nil else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            // .mixWithOthers so we don't stop the user's music/podcast. If
            // background keep-alive ever proves unreliable while other audio
            // plays, dropping this option makes us the primary audio.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let p = try AVAudioPlayer(data: KeepAliveAudio.silentWAV)
            p.numberOfLoops = -1
            p.volume = 0
            p.prepareToPlay()
            p.play()
            player = p
        } catch {
            player = nil
            try? session.setActive(false)
            return
        }
        // Resume after an interruption (phone call, Siri, alarm) ends.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            self.player?.play()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            interruptionObserver = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// A tiny in-memory silent WAV (1 s, 8 kHz mono 16-bit) looped forever, so we
    /// don't need to bundle an asset.
    private static let silentWAV: Data = {
        let sampleRate: UInt32 = 8000, dataSize: UInt32 = 8000 * 2  // 1 s, 16-bit mono
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)] }
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8)); d.append(contentsOf: le32(36 + dataSize))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); d.append(contentsOf: le32(16))
        d.append(contentsOf: le16(1))                       // PCM
        d.append(contentsOf: le16(1))                       // mono
        d.append(contentsOf: le32(sampleRate))
        d.append(contentsOf: le32(sampleRate * 2))          // byte rate
        d.append(contentsOf: le16(2))                       // block align
        d.append(contentsOf: le16(16))                      // bits/sample
        d.append(contentsOf: Array("data".utf8)); d.append(contentsOf: le32(dataSize))
        d.append(Data(count: Int(dataSize)))                // silence
        return d
    }()
}
