//
//  EncodeSession.swift
//  Drives a single TVCTranscoder run and owns best-effort background lifecycle.
//
import Foundation
import UIKit

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

    private let transcoder = TVCTranscoder()
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var autoPaused = false

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
            if success { self.phase = .finished }
            else if error == "cancelled" { self.phase = .cancelled }
            else { self.phase = .failed(error ?? "Unknown error") }
        }

        phase = .running
        transcoder.start(with: o)
    }

    // MARK: user controls
    func pause() { autoPaused = false; transcoder.pause(); phase = .paused }
    func resume() { autoPaused = false; transcoder.resume(); phase = .running }
    func cancel() { transcoder.cancel() }

    // MARK: best-effort background handling
    func didEnterBackground() {
        guard phase == .running else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "encode") { [weak self] in
            // The OS is about to suspend us — pause to checkpoint in memory.
            self?.autoPauseForExpiration()
        }
    }

    func willEnterForeground() {
        endBackgroundTask()
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
