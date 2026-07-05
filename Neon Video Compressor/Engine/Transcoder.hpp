//
//  Transcoder.hpp
//  Core libav* transcode pipeline: pause / resume / cancel + live progress.
//  Pure C++ so it can be unit-reasoned independently of the iOS layer.
//
#pragma once

#include <string>
#include <functional>
#include <atomic>
#include <thread>
#include <mutex>
#include <condition_variable>

namespace tvc {

enum class StreamMode { Encode, Copy };
enum class AudioProfile { AAC_LC, HE_AAC, HE_AACv2 };

struct TranscodeOptions {
    std::string inputPath;
    std::string outputPath;
    StreamMode videoMode = StreamMode::Encode;
    StreamMode audioMode = StreamMode::Encode;
    int crf = 30;                       // libx265 -crf
    std::string preset = "slow";        // libx265 -preset
    std::string x265Params;             // optional extra "key=val:key=val"
    AudioProfile audioProfile = AudioProfile::HE_AAC;
    int audioBitrate = 40000;           // bits/sec (e.g. -b:a 40k)
    bool faststart = true;              // +faststart
};

struct MediaInfo {
    bool ok = false;
    double durationSeconds = 0;
    int videoWidth = 0;
    int videoHeight = 0;
    std::string videoCodec;
    std::string audioCodec;
    int audioChannels = 0;
    int audioSampleRate = 0;
    std::string error;
};

struct Progress {
    double processedSeconds = 0;
    double totalSeconds = 0;
    double speed = 0;                   // ratio to realtime playback
    long long inputBytes = 0;          // bytes read from the source so far
    long long totalInputBytes = 0;     // total source size (0 if unknown)
    long long outputBytes = 0;         // bytes written to the output so far
};

class Transcoder {
public:
    Transcoder() = default;
    ~Transcoder();

    Transcoder(const Transcoder&) = delete;
    Transcoder& operator=(const Transcoder&) = delete;

    // Synchronous, no libav threads of its own — probe a file's properties.
    static MediaInfo probe(const std::string& path);

    // Callbacks fire on the internal worker thread; the caller marshals to UI.
    std::function<void(const Progress&)> onProgress;
    std::function<void(bool success, const std::string& error)> onFinished;

    void start(const TranscodeOptions& opts);   // spawns worker thread
    void pause();
    void resume();
    void cancel();
    void wait();                                 // join worker

    // When on, the worker paces itself (sleeps between work) to keep CPU under
    // iOS's background limit (~80%/60s). Enable while backgrounded; disable in
    // the foreground for full speed. Safe to toggle from any thread.
    void setThrottled(bool on);

private:
    void run(TranscodeOptions opts);
    // Blocks while paused; returns false if cancelled (loop should stop).
    bool gate();

    std::thread worker_;
    std::mutex mtx_;
    std::condition_variable cv_;
    std::atomic<bool> paused_{false};
    std::atomic<bool> cancelled_{false};
    std::atomic<bool> throttled_{false};

    // wall-clock accounting that excludes paused time
    double pausedAccum_ = 0;
    double pauseStart_ = 0;
};

} // namespace tvc
