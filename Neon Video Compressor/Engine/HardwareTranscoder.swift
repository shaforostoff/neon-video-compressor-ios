//
//  HardwareTranscoder.swift
//  HEVC encoding through VideoToolbox's hardware block.
//
//  Pipeline: AVAssetReader (decode) → VTCompressionSession (encode) →
//  AVAssetWriter (mux). We drive VideoToolbox directly rather than handing
//  compression settings to AVAssetWriter because AVFoundation swallows the
//  per-property status codes — and knowing exactly which quality knobs the
//  device's encoder accepts is the whole point of this backend. Every property
//  we set is recorded in `notes` (✓ accepted / ✗ rejected) and surfaced in the UI.
//
//  Unlike x265 there is no CRF here. See VTRateControl for the modes VideoToolbox
//  actually offers.
//
import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia
import CoreVideo

final class HardwareTranscoder: TranscodeBackend {
    var onProgress: ((TranscodeProgress) -> Void)?
    var onFinished: ((Bool, String?, [String]) -> Void)?

    // MARK: state

    private let queue = DispatchQueue(label: "tvc.hw.video")
    private let audioQueue = DispatchQueue(label: "tvc.hw.audio")

    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var videoTrackOutput: AVAssetReaderTrackOutput?
    private var audioTrackOutput: AVAssetReaderTrackOutput?
    private var session: VTCompressionSession?

    /// Per-property outcomes, for the "what worked on this device" report.
    private var notes: [String] = []
    private let notesLock = NSLock()

    private let stateLock = NSLock()
    private var cancelled = false
    private var paused = false
    private var throttled = false
    private let pauseGate = NSCondition()
    private var finishedOnce = false

    /// Set when a frame fails to encode or append, so the run reports failure.
    /// Written from both the read loop and VideoToolbox's callback thread.
    private var failureText: String?

    /// Bounds how many frames can be in VideoToolbox's queue at once. Without
    /// this the reader decodes far ahead of the encoder and the undelivered
    /// pixel buffers pile up — on 4K that is hundreds of MB and an OOM kill.
    private let inFlight = DispatchSemaphore(value: 12)

    /// Holds the first encoded frame during priming, before the writer exists.
    private var primedSample: CMSampleBuffer?

    /// Frames read from the source vs. frames the encoder actually gave back.
    /// A gap means VideoToolbox dropped frames, which Apple documents as a
    /// possible consequence of MaxAllowedFrameQP.
    private var framesRead = 0
    private var framesWritten = 0

    private var totalSeconds: Double = 0
    private var totalInputBytes: Int64 = 0
    private var startWall: CFAbsoluteTime = 0
    private var lastProgressReport: CFAbsoluteTime = 0
    private var outputURL: URL?

    // Source characteristics, resolved before the session is created.
    private var expectedFrameRate: Float = 30
    private var sourceFormatDescription: CMFormatDescription?

    // MARK: - TranscodeBackend

    func start(_ options: BackendOptions) {
        outputURL = options.outputURL
        queue.async { [weak self] in self?.run(options) }
    }

    func pause() {
        pauseGate.lock()
        paused = true
        pauseGate.unlock()
    }

    func resume() {
        pauseGate.lock()
        paused = false
        pauseGate.broadcast()
        pauseGate.unlock()
    }

    func cancel() {
        stateLock.lock()
        cancelled = true
        stateLock.unlock()
        // Unblock the read loop if it is sitting in the pause gate.
        pauseGate.lock(); pauseGate.broadcast(); pauseGate.unlock()
    }

    func setThrottled(_ on: Bool) {
        stateLock.lock()
        throttled = on
        stateLock.unlock()
    }

    private var isCancelled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return cancelled
    }

    private var isThrottled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return throttled
    }

    /// Block while paused. Returns false if the run was cancelled meanwhile.
    private func waitIfPaused() -> Bool {
        pauseGate.lock()
        while paused && !isCancelled {
            pauseGate.wait()
        }
        pauseGate.unlock()
        return !isCancelled
    }

    /// First failure wins — later ones are usually knock-on effects of it.
    private func setFailure(_ text: String) {
        stateLock.lock()
        if failureText == nil { failureText = text }
        stateLock.unlock()
    }

    private var failure: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return failureText
    }

    private func note(_ line: String) {
        notesLock.lock(); notes.append(line); notesLock.unlock()
    }

    private func takeNotes() -> [String] {
        notesLock.lock(); defer { notesLock.unlock() }
        return notes
    }

    // MARK: - main run

    private func run(_ o: BackendOptions) {
        startWall = CFAbsoluteTimeGetCurrent()
        totalInputBytes = fileSize(o.inputURL)

        let asset = AVURLAsset(url: o.inputURL,
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        guard let duration = blocking({ try await asset.load(.duration) }) else {
            return finish(false, "Could not read the source duration.")
        }
        totalSeconds = duration.seconds
        if o.durationLimitSeconds > 0 {
            totalSeconds = min(totalSeconds, o.durationLimitSeconds)
        }

        guard let videoTrack = blocking({ try await asset.loadTracks(withMediaType: .video).first })
                ?? nil else {
            return finish(false, "No video track in the source.")
        }

        // Track properties we need before building the encoder.
        let naturalSize = blocking { try await videoTrack.load(.naturalSize) } ?? .zero
        let transform = blocking { try await videoTrack.load(.preferredTransform) } ?? .identity
        let nominalFPS = blocking { try await videoTrack.load(.nominalFrameRate) } ?? 30
        sourceFormatDescription = (blocking { try await videoTrack.load(.formatDescriptions) })?.first
        expectedFrameRate = nominalFPS > 0 ? nominalFPS : 30

        guard naturalSize.width >= 1, naturalSize.height >= 1 else {
            return finish(false, "Source has an unusable frame size.")
        }

        // MARK: reader

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { return finish(false, "Could not open the source: \(error.localizedDescription)") }
        self.reader = reader

        if o.durationLimitSeconds > 0 {
            reader.timeRange = CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: o.durationLimitSeconds, preferredTimescale: 600))
        }

        // A video reader output MUST be given a pixel format — with nil settings it
        // vends the source's still-compressed samples instead of decoded frames.
        // So the bit depth has to be decided here, before anything is decoded.
        let (sourceTenBit, depthBasis) = detectTenBit(track: videoTrack)
        let wantTenBit = sourceTenBit && !o.settings.forceEightBit
        note("• source: \(sourceTenBit ? "10-bit" : "8-bit") (\(depthBasis))"
             + " → decoding to \(wantTenBit ? "10-bit" : "8-bit")")

        let videoOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: wantTenBit
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        let vOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoOutputSettings)
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { return finish(false, "Cannot read this video format.") }
        reader.add(vOut)
        videoTrackOutput = vOut

        // MARK: audio reader output
        //
        // Every reader output has to be added before startReading, so the audio
        // side is split: the reader output here, the writer input further down
        // once the writer exists.
        let audioTrack = o.settings.audioAction == .remove
            ? nil
            : (blocking { try await asset.loadTracks(withMediaType: .audio).first }) ?? nil
        if let audioTrack {
            addAudioReaderOutput(track: audioTrack, settings: o.settings, reader: reader)
        }

        // MARK: prime the encoder
        //
        // AVAssetWriter rejects a passthrough input whose format it doesn't know,
        // and the only authoritative HEVC format description comes from the
        // encoder itself — so encode the first frame before building the writer
        // and use that frame's format as the hint. Frame one is an IDR anyway, so
        // flushing the encoder this early costs nothing.
        guard reader.startReading() else {
            return finish(false, reader.error?.localizedDescription ?? "Could not start reading.")
        }
        guard let primed = primeEncoder(o: o, output: vOut) else {
            return finish(false, failure ?? "Could not start the hardware encoder.")
        }

        // MARK: writer

        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: o.outputURL, fileType: .mp4) }
        catch { return finish(false, "Could not create the output: \(error.localizedDescription)") }
        self.writer = writer
        writer.shouldOptimizeForNetworkUse = true   // faststart, matching the ffmpeg path

        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                     sourceFormatHint: primed.format)
        vIn.expectsMediaDataInRealTime = false
        vIn.transform = transform                  // keep rotation as metadata
        guard writer.canAdd(vIn) else { return finish(false, "Cannot write HEVC to this container.") }
        writer.add(vIn)
        videoInput = vIn

        if let audioTrack, audioTrackOutput != nil {
            addAudioWriterInput(track: audioTrack, settings: o.settings, writer: writer)
        }

        // MARK: go

        guard writer.startWriting() else {
            return finish(false, writer.error?.localizedDescription ?? "Could not start writing.")
        }
        writer.startSession(atSourceTime: .zero)

        append(primed.sample, to: vIn)   // the frame we encoded to get the format

        let group = DispatchGroup()

        if let aIn = audioInput, let aOut = audioTrackOutput {
            group.enter()
            aIn.requestMediaDataWhenReady(on: audioQueue) { [weak self] in
                guard let self else { return }
                self.pumpAudio(input: aIn, output: aOut, done: { group.leave() })
            }
        }

        group.enter()
        encodeVideo(o: o, output: vOut, input: vIn)
        group.leave()

        group.wait()

        // MARK: finish

        if isCancelled {
            writer.cancelWriting()
            reader.cancelReading()
            try? FileManager.default.removeItem(at: o.outputURL)
            return finish(false, "cancelled")
        }
        if let failure {
            writer.cancelWriting()
            reader.cancelReading()
            try? FileManager.default.removeItem(at: o.outputURL)
            return finish(false, failure)
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: o.outputURL)
            return finish(false, reader.error?.localizedDescription ?? "Reading failed.")
        }

        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()

        // Read vs. written is the direct test of Apple's "the encoder may drop
        // frames" caveat on MaxAllowedFrameQP — a gap here means frames were lost.
        stateLock.lock()
        let written = framesWritten
        stateLock.unlock()
        note("• frames: \(framesRead) read → \(written) written"
             + (written < framesRead ? "  ⚠︎ \(framesRead - written) DROPPED" : ""))

        if writer.status == .completed {
            finish(true, nil)
        } else {
            try? FileManager.default.removeItem(at: o.outputURL)
            finish(false, writer.error?.localizedDescription ?? "Writing failed.")
        }
    }

    /// Work out whether the source is more than 8-bit, and say on what basis so
    /// the report shows how the call was made.
    ///
    /// The format description usually carries BitsPerComponent, but CoreMedia
    /// explicitly warns it is often absent — so fall back to the HDR
    /// characteristic, which on phone footage means 10-bit in practice.
    private func detectTenBit(track: AVAssetTrack) -> (Bool, String) {
        if let fd = sourceFormatDescription,
           let bits = CMFormatDescriptionGetExtension(
                fd, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? NSNumber {
            return (bits.intValue > 8, "BitsPerComponent=\(bits.intValue)")
        }
        let characteristics = blocking { try await track.load(.mediaCharacteristics) } ?? []
        let isHDR = characteristics.contains(.containsHDRVideo)
        return (isHDR, isHDR ? "HDR track, no BitsPerComponent" : "no BitsPerComponent, not HDR")
    }

    // MARK: - audio

    private func addAudioReaderOutput(track: AVAssetTrack,
                                     settings: EncodeSettings,
                                     reader: AVAssetReader) {
        let copyOnly = settings.audioAction == .copy

        // Copy: read compressed frames untouched. Encode: decode to PCM so the
        // writer's AAC encoder can consume them.
        let readerSettings: [String: Any]? = copyOnly ? nil : [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let aOut = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
        aOut.alwaysCopiesSampleData = false
        guard reader.canAdd(aOut) else {
            note("✗ audio — source format unreadable, output will be silent")
            return
        }
        reader.add(aOut)
        audioTrackOutput = aOut
    }

    private func addAudioWriterInput(track: AVAssetTrack,
                                     settings: EncodeSettings,
                                     writer: AVAssetWriter) {
        let copyOnly = settings.audioAction == .copy

        var writerSettings: [String: Any]?
        if !copyOnly {
            let desc = (blocking { try await track.load(.formatDescriptions) })?.first
            let asbd = desc.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let sampleRate = asbd?.mSampleRate ?? 44100
            var channels = Int(asbd?.mChannelsPerFrame ?? 2)
            if channels < 1 { channels = 2 }

            // HE-AAC v2 is stereo-only (it is parametric stereo by definition);
            // asking for it with any other channel count fails the whole export.
            var profile = settings.audioProfile
            if profile == .heAACv2 && channels != 2 {
                profile = .heAAC
                note("⚠︎ audio — HE-AAC v2 needs 2 channels, fell back to HE-AAC")
            }
            writerSettings = [
                AVFormatIDKey: profile.audioFormatID,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: settings.audioBitrateKbps * 1000
            ]
        }

        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        aIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(aIn) else {
            note(copyOnly
                 ? "✗ audio — this container won't take the source audio as-is, output will be silent"
                 : "✗ audio — those AAC settings were rejected, output will be silent")
            return
        }
        writer.add(aIn)
        audioInput = aIn
    }

    /// Pull audio for as long as the writer will take it. Re-invoked by
    /// AVFoundation whenever the input drains, so it must return when not ready.
    private func pumpAudio(input: AVAssetWriterInput,
                           output: AVAssetReaderTrackOutput,
                           done: @escaping () -> Void) {
        while input.isReadyForMoreMediaData {
            if isCancelled {
                input.markAsFinished()
                return done()
            }
            guard let sample = output.copyNextSampleBuffer() else {
                input.markAsFinished()
                return done()
            }
            if !input.append(sample) {
                input.markAsFinished()
                return done()
            }
        }
    }

    // MARK: - video

    /// Encode exactly one frame so the writer can be built around the encoder's
    /// own HEVC format description. Returns the encoded frame and its format;
    /// the caller appends the frame once the writer is running.
    private func primeEncoder(o: BackendOptions,
                              output: AVAssetReaderTrackOutput)
                              -> (sample: CMSampleBuffer, format: CMFormatDescription)? {
        while true {
            if isCancelled { return nil }
            guard let sample = output.copyNextSampleBuffer() else {
                setFailure("The source produced no decodable video frames.")
                return nil
            }
            // Non-image samples at the head of a track are skippable.
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }

            guard createSession(from: pixels, settings: o.settings, favorSpeed: o.favorSpeed),
                  let session else {
                setFailure("Could not create the hardware encoder.")
                return nil
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            var duration = CMSampleBufferGetDuration(sample)
            if !duration.isValid || duration.seconds <= 0 {
                duration = CMTime(seconds: 1.0 / Double(expectedFrameRate), preferredTimescale: 600)
            }

            var flags = VTEncodeInfoFlags()
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixels,
                presentationTimeStamp: pts,
                duration: duration,
                frameProperties: nil,
                infoFlagsOut: &flags
            ) { [weak self] status, _, sampleBuffer in
                guard let self else { return }
                if status == noErr {
                    self.primedSample = sampleBuffer
                } else {
                    self.setFailure("Hardware encoder returned status \(status).")
                }
            }
            guard status == noErr else {
                setFailure("Hardware encode failed (status \(status)).")
                return nil
            }
            framesRead += 1

            // CompleteFrames blocks until every pending callback has run, so
            // primedSample is safe to read on this thread afterwards.
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

            guard let encoded = primedSample,
                  let format = CMSampleBufferGetFormatDescription(encoded) else {
                setFailure(failure ?? "The encoder produced no output for the first frame.")
                return nil
            }
            primedSample = nil
            return (encoded, format)
        }
    }

    private func encodeVideo(o: BackendOptions,
                            output: AVAssetReaderTrackOutput,
                            input: AVAssetWriterInput) {
        while true {
            if !waitIfPaused() { break }
            guard let session else { break }
            guard let sample = output.copyNextSampleBuffer() else { break }
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }

            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            var duration = CMSampleBufferGetDuration(sample)
            if !duration.isValid || duration.seconds <= 0 {
                duration = CMTime(seconds: 1.0 / Double(expectedFrameRate), preferredTimescale: 600)
            }

            // Don't run more than `inFlight` frames ahead of the encoder. The
            // timeout is a safety valve: a frame VideoToolbox never calls back on
            // would otherwise hang the encode forever.
            _ = inFlight.wait(timeout: .now() + 10)

            var flags = VTEncodeInfoFlags()
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixels,
                presentationTimeStamp: pts,
                duration: duration,
                frameProperties: nil,
                infoFlagsOut: &flags
            ) { [weak self] status, _, sampleBuffer in
                self?.handleEncoded(status: status, sampleBuffer: sampleBuffer, input: input)
            }
            if status != noErr {
                inFlight.signal()   // no callback is coming for this frame
                setFailure("Hardware encode failed (status \(status)).")
                break
            }

            framesRead += 1
            reportProgress(processed: pts.seconds + duration.seconds)

            // Backgrounded with keep-awake: pace ourselves so we stay under iOS's
            // background CPU budget instead of being killed mid-encode.
            if isThrottled { Thread.sleep(forTimeInterval: 0.02) }
        }

        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
        input.markAsFinished()
    }

    /// VideoToolbox handed us an encoded frame — hand it to the writer. Called on
    /// VideoToolbox's own thread; appends block until the writer is ready, which
    /// is what keeps memory flat.
    private func handleEncoded(status: OSStatus,
                               sampleBuffer: CMSampleBuffer?,
                               input: AVAssetWriterInput) {
        defer { inFlight.signal() }

        guard status == noErr, let sampleBuffer else {
            // A nil buffer with noErr means the encoder dropped this frame, which
            // is legitimate (and what the read/written counts are there to catch).
            if status != noErr {
                setFailure("Hardware encoder returned status \(status).")
            }
            return
        }
        append(sampleBuffer, to: input)
    }

    /// Hand one encoded frame to the writer, waiting for it to have room. That
    /// wait is the backstop that keeps memory flat when the writer is the
    /// bottleneck. Called from VideoToolbox's thread and from the priming step.
    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput) {
        if isCancelled { return }
        while !input.isReadyForMoreMediaData {
            if isCancelled { return }
            Thread.sleep(forTimeInterval: 0.005)
        }
        if input.append(sampleBuffer) {
            stateLock.lock(); framesWritten += 1; stateLock.unlock()
        } else {
            setFailure(writer?.error?.localizedDescription ?? "Could not write the encoded frame.")
        }
    }

    // MARK: - session setup

    private func createSession(from pixels: CVPixelBuffer,
                               settings: EncodeSettings,
                               favorSpeed: Bool) -> Bool {
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixels)
        let isTenBit = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange

        // No encoder specification: the Enable/RequireHardwareAcceleratedVideoEncoder
        // keys are macOS-only, because on iOS the HEVC encoder is the hardware block
        // — there is no software encoder to fall back to or select away from.
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            note("✗ session — VTCompressionSessionCreate failed (status \(status))")
            return false
        }
        session = created
        note("• \(width)×\(height), \(isTenBit ? "10-bit" : "8-bit"), \(String(format: "%.2f", expectedFrameRate)) fps")

        configure(session: created, settings: settings, isTenBit: isTenBit, favorSpeed: favorSpeed)
        VTCompressionSessionPrepareToEncodeFrames(created)
        return true
    }

    private func configure(session: VTCompressionSession,
                           settings s: EncodeSettings,
                           isTenBit: Bool,
                           favorSpeed: Bool) {
        // Is constant quality even offered here? Worth recording either way —
        // a key can be listed and still be ignored, so the file size is the proof.
        var supported: CFDictionary?
        if VTSessionCopySupportedPropertyDictionary(session, supportedPropertyDictionaryOut: &supported) == noErr,
           let dict = supported as? [String: Any] {
            let has = dict[kVTCompressionPropertyKey_Quality as String] != nil
            note("• Quality listed as supported: \(has ? "yes" : "no")")
        }

        // Export, not a live stream — let the encoder take its time.
        set(session, kVTCompressionPropertyKey_RealTime, false as CFBoolean, "RealTime=false")
        set(session, kVTCompressionPropertyKey_ExpectedFrameRate,
            expectedFrameRate as CFNumber, "ExpectedFrameRate")

        let profile: CFString = isTenBit
            ? kVTProfileLevel_HEVC_Main10_AutoLevel
            : kVTProfileLevel_HEVC_Main_AutoLevel
        set(session, kVTCompressionPropertyKey_ProfileLevel, profile,
            "ProfileLevel=\(isTenBit ? "Main10" : "Main")")

        applyRateControl(session, s)

        if s.vtKeyframeSeconds > 0 {
            set(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                s.vtKeyframeSeconds as CFNumber, "MaxKeyFrameIntervalDuration=\(s.vtKeyframeSeconds)s")
            let interval = Int(s.vtKeyframeSeconds * Double(expectedFrameRate))
            set(session, kVTCompressionPropertyKey_MaxKeyFrameInterval,
                interval as CFNumber, "MaxKeyFrameInterval=\(interval)")
        }

        // CBR pads frames to hit its target, and B-frames fight that; give CBR the
        // configuration it documents rather than a combination that just fails.
        let allowBFrames = s.vtRateControl == .constantBitrate ? false : s.vtAllowFrameReordering
        set(session, kVTCompressionPropertyKey_AllowFrameReordering,
            allowBFrames as CFBoolean, "AllowFrameReordering=\(allowBFrames)")

        if favorSpeed || s.vtPrioritizeSpeed {
            set(session, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                true as CFBoolean, "PrioritizeEncodingSpeedOverQuality=true")
        }
        if s.vtPowerEfficient {
            set(session, kVTCompressionPropertyKey_MaximizePowerEfficiency,
                true as CFBoolean, "MaximizePowerEfficiency=true")
        }

        propagateColor(session)
    }

    private func applyRateControl(_ session: VTCompressionSession, _ s: EncodeSettings) {
        let bits = Int(max(0.1, s.vtBitrateMbps) * 1_000_000)
        /// Whether the knob that defines this mode's quality was accepted.
        var primaryAccepted = false

        switch s.vtRateControl {
        case .constantQuality:
            // Deliberately no bitrate target — Quality only governs when nothing
            // else is constraining the encoder.
            primaryAccepted = set(session, kVTCompressionPropertyKey_Quality,
                s.vtQuality as CFNumber, "Quality=\(String(format: "%.2f", s.vtQuality))")

        case .averageBitrate:
            primaryAccepted = set(session, kVTCompressionPropertyKey_AverageBitRate,
                bits as CFNumber, "AverageBitRate=\(s.vtBitrateMbps) Mbps")

        case .constantBitrate:
            primaryAccepted = set(session, kVTCompressionPropertyKey_ConstantBitRate,
                bits as CFNumber, "ConstantBitRate=\(s.vtBitrateMbps) Mbps")

        case .bitrateWithQPCap:
            set(session, kVTCompressionPropertyKey_AverageBitRate,
                bits as CFNumber, "AverageBitRate=\(s.vtBitrateMbps) Mbps")
            primaryAccepted = set(session, kVTCompressionPropertyKey_MaxAllowedFrameQP,
                s.vtMaxQP as CFNumber, "MaxAllowedFrameQP=\(s.vtMaxQP)")
            if s.vtMinQP > 0 {
                set(session, kVTCompressionPropertyKey_MinAllowedFrameQP,
                    s.vtMinQP as CFNumber, "MinAllowedFrameQP=\(s.vtMinQP)")
            }

        case .qualityWithCap:
            primaryAccepted = set(session, kVTCompressionPropertyKey_Quality,
                s.vtQuality as CFNumber, "Quality=\(String(format: "%.2f", s.vtQuality))")
            // DataRateLimits is [bytes, seconds] pairs — a hard ceiling over a
            // one-second window, so constant quality can't run away on a busy scene.
            let capBytes = Int(Double(bits) * max(1.0, s.vtCapMultiplier) / 8.0)
            set(session, kVTCompressionPropertyKey_DataRateLimits,
                [capBytes, 1] as CFArray,
                "DataRateLimits=\(capBytes) bytes/s")
        }

        // A rejected knob doesn't fail the encode — the encoder just falls back to
        // its own defaults, so the file size you get has nothing to do with the
        // slider you moved. Say so plainly rather than letting it look like it worked.
        if !primaryAccepted {
            note("⚠︎ \"\(s.vtRateControl.rawValue)\" was NOT applied — this encode used the"
                 + " encoder's default rate control, so the output does not reflect your setting.")
        }
    }

    /// Carry the source's color tags onto the output so HDR/BT.2020 material
    /// doesn't come out looking like Rec.709.
    private func propagateColor(_ session: VTCompressionSession) {
        guard let fd = sourceFormatDescription else { return }
        let pairs: [(CFString, CFString, String)] = [
            (kCMFormatDescriptionExtension_ColorPrimaries,
             kVTCompressionPropertyKey_ColorPrimaries, "ColorPrimaries"),
            (kCMFormatDescriptionExtension_TransferFunction,
             kVTCompressionPropertyKey_TransferFunction, "TransferFunction"),
            (kCMFormatDescriptionExtension_YCbCrMatrix,
             kVTCompressionPropertyKey_YCbCrMatrix, "YCbCrMatrix")
        ]
        for (extKey, propKey, label) in pairs {
            guard let value = CMFormatDescriptionGetExtension(fd, extensionKey: extKey) else { continue }
            set(session, propKey, value, "\(label)=\(value)")
        }
    }

    /// Set one property and record whether the device's encoder took it.
    /// Returns whether it was accepted, so callers can flag a rejected knob that
    /// leaves the encoder silently running on its own defaults.
    @discardableResult
    private func set(_ session: VTCompressionSession,
                     _ key: CFString,
                     _ value: CFTypeRef,
                     _ label: String) -> Bool {
        let status = VTSessionSetProperty(session, key: key, value: value)
        switch status {
        case noErr:
            note("✓ \(label)")
            return true
        case kVTPropertyNotSupportedErr:
            note("✗ \(label) — not supported by this encoder")
        case kVTParameterErr:
            // The key exists and may even be listed as supported, but this
            // encoder won't take this value — the "listed ≠ honored" case.
            note("✗ \(label) — kVTParameterErr (rejected, not merely absent)")
        default:
            note("✗ \(label) — status \(status)")
        }
        return false
    }

    // MARK: - progress / completion

    private func reportProgress(processed: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastProgressReport >= 0.2 else { return }
        lastProgressReport = now

        let elapsed = now - startWall
        let fraction = totalSeconds > 0 ? min(1, processed / totalSeconds) : 0
        var p = TranscodeProgress()
        p.processedSeconds = processed
        p.totalSeconds = totalSeconds
        p.speed = elapsed > 0.01 ? processed / elapsed : 0
        // The reader doesn't report bytes consumed, so scale the source size by
        // how much of the timeline we've handled.
        p.inputBytes = Int64(Double(totalInputBytes) * fraction)
        p.totalInputBytes = totalInputBytes
        p.outputBytes = outputURL.map(fileSize) ?? 0

        DispatchQueue.main.async { [weak self] in self?.onProgress?(p) }
    }

    private func finish(_ success: Bool, _ error: String?) {
        guard !finishedOnce else { return }
        finishedOnce = true
        if let session {
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
        let report = takeNotes()
        DispatchQueue.main.async { [weak self] in
            self?.onFinished?(success, error, report)
        }
    }

    // MARK: - helpers

    private func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Run an async load synchronously. Safe here because this only ever runs on
    /// our own serial queues — never the main queue or a cooperative-pool thread.
    private func blocking<T>(_ work: @escaping () async throws -> T) -> T? {
        let box = LoadBox<T>()
        let sem = DispatchSemaphore(value: 0)
        Task {
            box.value = try? await work()
            sem.signal()
        }
        sem.wait()
        return box.value
    }
}

/// Hands one loaded value back across the `blocking` semaphore. Safe by
/// construction: written once inside the Task, read only after `sem.wait()`.
private final class LoadBox<V>: @unchecked Sendable {
    var value: V?
}

private extension AudioProfileOption {
    var audioFormatID: AudioFormatID {
        switch self {
        case .aacLC:   return kAudioFormatMPEG4AAC
        case .heAAC:   return kAudioFormatMPEG4AAC_HE
        case .heAACv2: return kAudioFormatMPEG4AAC_HE_V2
        }
    }
}
