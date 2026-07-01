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

        transcoder.onProgress = { [weak self] processed, total, speed in
            guard let self else { return }
            self.processedSeconds = processed
            if total > 0 { self.totalSeconds = total }
            self.speed = speed
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
