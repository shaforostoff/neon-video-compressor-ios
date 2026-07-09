//
//  Transcoder.cpp
//
#include "Transcoder.hpp"

#include <chrono>
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <thread>
#include <mach/mach.h>

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/opt.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/channel_layout.h>
#include <libavutil/imgutils.h>
#include <libavutil/samplefmt.h>
#include <libavutil/mathematics.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
}

namespace tvc {

namespace {

double nowSeconds() {
    using namespace std::chrono;
    return duration<double>(steady_clock::now().time_since_epoch()).count();
}

// Total CPU time consumed by this process across ALL live threads (user+system),
// in seconds. Used to pace the encode against iOS's background CPU limit — it
// must include x265's worker threads, not just the calling thread.
double processCpuSeconds() {
    task_thread_times_info_data_t tti;
    mach_msg_type_number_t count = TASK_THREAD_TIMES_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_THREAD_TIMES_INFO,
                  (task_info_t)&tti, &count) != KERN_SUCCESS)
        return 0;
    double user = tti.user_time.seconds + tti.user_time.microseconds / 1e6;
    double sys  = tti.system_time.seconds + tti.system_time.microseconds / 1e6;
    return user + sys;
}

// Feature toggle for the crash-surviving debug log (tvc_debug.log). Define
// TVC_DEBUG_LOG=1 (e.g. via build settings / -DTVC_DEBUG_LOG=1) to enable it.
// When off, dbg() is a no-op and no log file is ever touched.
// NOTE: temporarily defaulted ON for a sideloaded color-diagnosis build — set
// this back to 0 before shipping.
#ifndef TVC_DEBUG_LOG
#define TVC_DEBUG_LOG 1
#endif
constexpr bool kDebugLog = TVC_DEBUG_LOG;

// Crash-surviving diagnostics: appended + flushed immediately so partial
// output remains on disk even if the process segfaults mid-encode. Always
// written to the app's Documents folder so it's retrievable from the Files app
// (rather than next to the output, which for previews is a temp dir).
std::string debugLogPath(const std::string & /*outputPath*/) {
    const char *home = getenv("HOME");
    std::string dir = home ? std::string(home) + "/Documents" : ".";
    return dir + "/tvc_debug.log";
}

void dbg(const std::string &path, const std::string &msg) {
    if (!kDebugLog) return;
    FILE *f = fopen(path.c_str(), "a");
    if (!f) return;
    fprintf(f, "%s\n", msg.c_str());
    fclose(f);
}

std::string avErr(int err) {
    char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(err, buf, sizeof(buf));
    return std::string(buf);
}

// Human-readable color signalling, e.g. "range=tv primaries=bt2020 trc=arib-std-b67
// matrix=bt2020nc". This is the key info for diagnosing washed-out / brightness
// shifts: compare the SOURCE line against the OUTPUT line in the log.
std::string colorDesc(int range, int primaries, int trc, int space) {
    auto nn = [](const char *s) { return s ? s : "unspecified"; };
    return std::string("range=") + nn(av_color_range_name((AVColorRange)range)) +
           " primaries=" + nn(av_color_primaries_name((AVColorPrimaries)primaries)) +
           " trc=" + nn(av_color_transfer_name((AVColorTransferCharacteristic)trc)) +
           " matrix=" + nn(av_color_space_name((AVColorSpace)space));
}

// One output stream's worth of state (either a copy or an encode).
struct StreamCtx {
    int inIndex = -1;
    int outIndex = -1;
    bool encode = false;
    AVStream *outStream = nullptr;
    AVCodecContext *dec = nullptr;
    AVCodecContext *enc = nullptr;
    // video scaling
    SwsContext *sws = nullptr;
    AVFrame *scaled = nullptr;
    // audio resampling + fifo
    SwrContext *swr = nullptr;
    AVAudioFifo *fifo = nullptr;
    int64_t nextAudioPts = 0;
};

void closeStream(StreamCtx &s) {
    if (s.dec) avcodec_free_context(&s.dec);
    if (s.enc) avcodec_free_context(&s.enc);
    if (s.sws) { sws_freeContext(s.sws); s.sws = nullptr; }
    if (s.scaled) av_frame_free(&s.scaled);
    if (s.swr) swr_free(&s.swr);
    if (s.fifo) { av_audio_fifo_free(s.fifo); s.fifo = nullptr; }
}

int profileFor(AudioProfile p) {
    switch (p) {
        case AudioProfile::AAC_LC:   return AV_PROFILE_AAC_LOW;
        case AudioProfile::HE_AAC:   return AV_PROFILE_AAC_HE;
        case AudioProfile::HE_AACv2: return AV_PROFILE_AAC_HE_V2;
    }
    return AV_PROFILE_AAC_LOW;
}

// Copy the display-matrix side data (rotation/flip) from an input stream to an
// output stream. iPhone stores "portrait" clips as landscape pixels plus a 90°
// matrix; re-encoding builds a fresh stream that would otherwise lose it and
// play sideways. Safe to call on a stream that has none (no-op).
void copyDisplayMatrix(const AVStream *in, AVStream *out) {
    const AVPacketSideData *sd = av_packet_side_data_get(
        in->codecpar->coded_side_data, in->codecpar->nb_coded_side_data,
        AV_PKT_DATA_DISPLAYMATRIX);
    if (!sd) return;
    AVPacketSideData *dst = av_packet_side_data_new(
        &out->codecpar->coded_side_data, &out->codecpar->nb_coded_side_data,
        AV_PKT_DATA_DISPLAYMATRIX, sd->size, 0);
    if (dst) memcpy(dst->data, sd->data, sd->size);
}

} // namespace

// ---------------------------------------------------------------------------
// probe
// ---------------------------------------------------------------------------
MediaInfo Transcoder::probe(const std::string &path) {
    MediaInfo info;
    AVFormatContext *fmt = nullptr;
    int err = avformat_open_input(&fmt, path.c_str(), nullptr, nullptr);
    if (err < 0) { info.error = "open: " + avErr(err); return info; }
    if ((err = avformat_find_stream_info(fmt, nullptr)) < 0) {
        info.error = "stream info: " + avErr(err);
        avformat_close_input(&fmt);
        return info;
    }
    if (fmt->duration != AV_NOPTS_VALUE)
        info.durationSeconds = (double)fmt->duration / AV_TIME_BASE;

    for (unsigned i = 0; i < fmt->nb_streams; ++i) {
        AVCodecParameters *par = fmt->streams[i]->codecpar;
        const char *name = avcodec_get_name(par->codec_id);
        if (par->codec_type == AVMEDIA_TYPE_VIDEO && info.videoCodec.empty()) {
            info.videoWidth = par->width;
            info.videoHeight = par->height;
            info.videoCodec = name ? name : "?";
        } else if (par->codec_type == AVMEDIA_TYPE_AUDIO && info.audioCodec.empty()) {
            info.audioCodec = name ? name : "?";
            info.audioChannels = par->ch_layout.nb_channels;
            info.audioSampleRate = par->sample_rate;
        }
    }
    info.ok = true;
    avformat_close_input(&fmt);
    return info;
}

// ---------------------------------------------------------------------------
// lifecycle / control
// ---------------------------------------------------------------------------
Transcoder::~Transcoder() {
    cancel();
    wait();
}

void Transcoder::start(const TranscodeOptions &opts) {
    cancelled_ = false;
    paused_ = false;
    pausedAccum_ = 0;
    pauseStart_ = 0;
    worker_ = std::thread([this, opts]() { run(opts); });
}

void Transcoder::pause() {
    std::lock_guard<std::mutex> lk(mtx_);
    if (!paused_) {
        paused_ = true;
        pauseStart_ = nowSeconds();
    }
}

void Transcoder::resume() {
    std::lock_guard<std::mutex> lk(mtx_);
    if (paused_) {
        paused_ = false;
        pausedAccum_ += nowSeconds() - pauseStart_;
        cv_.notify_all();
    }
}

void Transcoder::cancel() {
    {
        std::lock_guard<std::mutex> lk(mtx_);
        cancelled_ = true;
        paused_ = false;
        cv_.notify_all();
    }
}

void Transcoder::setThrottled(bool on) { throttled_ = on; }

void Transcoder::wait() {
    if (worker_.joinable()) worker_.join();
}

bool Transcoder::gate() {
    std::unique_lock<std::mutex> lk(mtx_);
    cv_.wait(lk, [this] { return !paused_ || cancelled_; });
    return !cancelled_;
}

// ---------------------------------------------------------------------------
// the transcode pipeline
// ---------------------------------------------------------------------------
void Transcoder::run(TranscodeOptions opts) {
    AVFormatContext *ifmt = nullptr;
    AVFormatContext *ofmt = nullptr;
    StreamCtx video, audio;
    bool headerWritten = false;
    int err = 0;
    std::string error;
    double totalDuration = 0;
    long long totalInputBytes = 0;      // source file size, cached once
    double startWall = nowSeconds();
    double lastEmit = 0;
    double processedSeconds = 0;
    const std::string dbgPath = debugLogPath(opts.outputPath);
    if (kDebugLog) remove(dbgPath.c_str());
    dbg(dbgPath, "=== run start: in=" + opts.inputPath + " out=" + opts.outputPath +
                 " crf=" + std::to_string(opts.crf) + " preset=" + opts.preset + " ===");

    auto fail = [&](const std::string &m) { error = m; };

    const AVCodec *videoEncoder = nullptr;

    // Open the x265 encoder + create its output stream for a known frame size.
    // Factored out so it can run either up front (size known from codecpar) or
    // lazily on the first decoded frame (codecpar reported 0x0).
    auto setupVideoEncoder = [&](int w, int h) -> int {
        // Match the source bit depth so 10-bit HDR isn't crushed to 8-bit, then
        // fall back to 8-bit if this x265 build can't open a 10-bit encoder.
        const AVPixFmtDescriptor *srcDesc = av_pix_fmt_desc_get(video.dec->pix_fmt);
        bool srcTenBit = srcDesc && srcDesc->comp[0].depth >= 10;
        // Try the preferred depth first, then the other depth as a fallback, so we
        // cope with whatever this x265 build supports (8-bit only, 10-bit only, or
        // a multilib). Prefer 10-bit for a 10-bit source to keep HDR — unless the
        // user asked to force 8-bit output.
        bool preferTenBit = srcTenBit && !opts.forceEightBit;
        AVPixelFormat candidates[2];
        int nCand = 0;
        if (preferTenBit) {
            candidates[nCand++] = AV_PIX_FMT_YUV420P10LE;
            candidates[nCand++] = AV_PIX_FMT_YUV420P;
        } else {
            candidates[nCand++] = AV_PIX_FMT_YUV420P;
            candidates[nCand++] = AV_PIX_FMT_YUV420P10LE;
        }

        AVRational fr = ifmt->streams[video.inIndex]->avg_frame_rate.num
                            ? ifmt->streams[video.inIndex]->avg_frame_rate
                            : AVRational{30, 1};
        char crfStr[16];
        snprintf(crfStr, sizeof(crfStr), "%d", opts.crf);
        std::string x265Params = opts.x265Params;

        int e = AVERROR(EINVAL);
        for (int i = 0; i < nCand; ++i) {
            if (video.enc) avcodec_free_context(&video.enc);
            video.enc = avcodec_alloc_context3(videoEncoder);
            video.enc->width = w;
            video.enc->height = h;
            video.enc->pix_fmt = candidates[i];
            video.enc->sample_aspect_ratio = video.dec->sample_aspect_ratio;
            video.enc->time_base = av_inv_q(fr);
            video.enc->framerate = fr;
            // Carry the source's color signalling to the encoder — and via
            // avcodec_parameters_from_context below onto the output track — so a
            // wide-gamut / HDR (e.g. HLG BT.2020) clip isn't rendered as SDR BT.709.
            video.enc->color_primaries        = video.dec->color_primaries;
            video.enc->color_trc              = video.dec->color_trc;
            video.enc->colorspace             = video.dec->colorspace;
            video.enc->color_range            = video.dec->color_range;
            video.enc->chroma_sample_location = video.dec->chroma_sample_location;

            av_opt_set(video.enc->priv_data, "preset", opts.preset.c_str(), 0);
            av_opt_set(video.enc->priv_data, "crf", crfStr, 0);
            // Let x265 build its own CPU-sized thread pool (multithreaded). The
            // null-payload-NAL crash that first looked threading-related was actually
            // FFmpeg's libx265 scalable multi-layer output path (X265_BUILD >= 210),
            // fixed at build time by the ffmpeg-n7.1-libx265-single-picture patch.
            // Do NOT force "pools=none": with no pool x265 still auto-detects
            // frameNumThreads and spawns pool-less FrameEncoders that null-deref.
            if (!x265Params.empty())
                av_opt_set(video.enc->priv_data, "x265-params", x265Params.c_str(), 0);
            video.enc->codec_tag = MKTAG('h','v','c','1');
            if (ofmt->oformat->flags & AVFMT_GLOBALHEADER)
                video.enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;

            e = avcodec_open2(video.enc, videoEncoder, nullptr);
            if (e >= 0) break;
            dbg(dbgPath, std::string("encoder open failed for ") +
                         (av_get_pix_fmt_name(candidates[i]) ? av_get_pix_fmt_name(candidates[i]) : "?") +
                         ": " + avErr(e));
        }
        if (e < 0) return e;
        dbg(dbgPath, "encoder opened: " + std::to_string(video.enc->width) + "x" +
                     std::to_string(video.enc->height) +
                     " pix_fmt=" + (av_get_pix_fmt_name(video.enc->pix_fmt) ? av_get_pix_fmt_name(video.enc->pix_fmt) : "?") +
                     " thread_count=" + std::to_string(video.enc->thread_count) +
                     " x265params=" + x265Params);
        dbg(dbgPath, "OUTPUT color: " + colorDesc(video.enc->color_range,
                     video.enc->color_primaries, video.enc->color_trc, video.enc->colorspace));
        video.outStream = avformat_new_stream(ofmt, nullptr);
        avcodec_parameters_from_context(video.outStream->codecpar, video.enc);
        video.outStream->time_base = video.enc->time_base;
        video.outStream->avg_frame_rate = video.enc->framerate;
        video.outIndex = video.outStream->index;
        copyDisplayMatrix(ifmt->streams[video.inIndex], video.outStream); // keep rotation
        av_dict_copy(&video.outStream->metadata,
                     ifmt->streams[video.inIndex]->metadata, 0); // keep stream tags
        video.scaled = av_frame_alloc();
        return 0;
    };

    // Open the output file + write the container header. Deferred until every
    // output stream exists (for 0x0 codecpar the video stream isn't created
    // until the first decoded frame).
    auto openOutput = [&]() -> int {
        if (!(ofmt->oformat->flags & AVFMT_NOFILE)) {
            int e = avio_open(&ofmt->pb, opts.outputPath.c_str(), AVIO_FLAG_WRITE);
            if (e < 0) return e;
        }
        // Carry over the source container tags (creation date, GPS location,
        // camera make/model, etc.) so the output — and any Photos asset made
        // from it — keeps the original's date and location.
        av_dict_copy(&ofmt->metadata, ifmt->metadata, 0);
        AVDictionary *muxOpts = nullptr;
        if (opts.faststart) av_dict_set(&muxOpts, "movflags", "+faststart", 0);
        int e = avformat_write_header(ofmt, &muxOpts);
        av_dict_free(&muxOpts);
        if (e < 0) return e;
        headerWritten = true;
        return 0;
    };

    // -- open input ---------------------------------------------------------
    if ((err = avformat_open_input(&ifmt, opts.inputPath.c_str(), nullptr, nullptr)) < 0) {
        fail("open input: " + avErr(err)); goto done;
    }
    if ((err = avformat_find_stream_info(ifmt, nullptr)) < 0) {
        fail("stream info: " + avErr(err)); goto done;
    }
    if (ifmt->duration != AV_NOPTS_VALUE)
        totalDuration = (double)ifmt->duration / AV_TIME_BASE;
    // Preview mode: cap the reported total so progress reads 0→100% over the clip.
    if (opts.durationLimitSeconds > 0 &&
        (totalDuration <= 0 || totalDuration > opts.durationLimitSeconds))
        totalDuration = opts.durationLimitSeconds;
    if (ifmt->pb) {
        int64_t sz = avio_size(ifmt->pb);   // seeks to end + restores position
        if (sz > 0) totalInputBytes = sz;
    }

    for (unsigned i = 0; i < ifmt->nb_streams; ++i) {
        AVMediaType t = ifmt->streams[i]->codecpar->codec_type;
        if (t == AVMEDIA_TYPE_VIDEO && video.inIndex < 0) video.inIndex = (int)i;
        else if (t == AVMEDIA_TYPE_AUDIO && audio.inIndex < 0) audio.inIndex = (int)i;
    }

    // -- alloc output -------------------------------------------------------
    if ((err = avformat_alloc_output_context2(&ofmt, nullptr, nullptr,
                                              opts.outputPath.c_str())) < 0) {
        fail("alloc output: " + avErr(err)); goto done;
    }

    // -- configure video stream --------------------------------------------
    if (video.inIndex >= 0) {
        AVStream *in = ifmt->streams[video.inIndex];
        video.encode = (opts.videoMode == StreamMode::Encode);

        if (!video.encode) {
            // remux: copy codecpar, retag HEVC as hvc1 for QuickTime
            video.outStream = avformat_new_stream(ofmt, nullptr);
            avcodec_parameters_copy(video.outStream->codecpar, in->codecpar);
            video.outStream->codecpar->codec_tag = 0;
            if (in->codecpar->codec_id == AV_CODEC_ID_HEVC)
                video.outStream->codecpar->codec_tag = MKTAG('h','v','c','1');
            video.outStream->time_base = in->time_base;
            video.outIndex = video.outStream->index;
            copyDisplayMatrix(in, video.outStream); // keep rotation
            av_dict_copy(&video.outStream->metadata, in->metadata, 0); // keep stream tags
        } else {
            const AVCodec *decoder = avcodec_find_decoder(in->codecpar->codec_id);
            videoEncoder = avcodec_find_encoder_by_name("libx265");
            if (!decoder || !videoEncoder) { fail("missing libx265/decoder"); goto done; }

            video.dec = avcodec_alloc_context3(decoder);
            avcodec_parameters_to_context(video.dec, in->codecpar);
            video.dec->pkt_timebase = in->time_base;
            if ((err = avcodec_open2(video.dec, decoder, nullptr)) < 0) {
                fail("open video decoder: " + avErr(err)); goto done;
            }
            dbg(dbgPath, "decoder opened: " + std::string(decoder->name) +
                         " " + std::to_string(video.dec->width) + "x" + std::to_string(video.dec->height) +
                         " pix_fmt=" + (av_get_pix_fmt_name(video.dec->pix_fmt) ? av_get_pix_fmt_name(video.dec->pix_fmt) : "?") +
                         " profile=" + std::to_string(video.dec->profile) +
                         " field_order=" + std::to_string((int)video.dec->field_order));
            dbg(dbgPath, "SOURCE color: " + colorDesc(video.dec->color_range,
                         video.dec->color_primaries, video.dec->color_trc, video.dec->colorspace));

            // Some decoders report 0x0 in codecpar until the first frame is
            // decoded. Only open the encoder now if we already have a real size;
            // otherwise defer it (and the header) to the first decoded frame.
            if (video.dec->width > 0 && video.dec->height > 0) {
                if ((err = setupVideoEncoder(video.dec->width, video.dec->height)) < 0) {
                    fail("open libx265: " + avErr(err)); goto done;
                }
            } else {
                dbg(dbgPath, "video size unknown from codecpar; deferring encoder setup to first frame");
            }
        }
    }

    // -- configure audio stream --------------------------------------------
    if (audio.inIndex >= 0) {
        AVStream *in = ifmt->streams[audio.inIndex];
        audio.encode = (opts.audioMode == StreamMode::Encode);

        if (!audio.encode) {
            audio.outStream = avformat_new_stream(ofmt, nullptr);
            avcodec_parameters_copy(audio.outStream->codecpar, in->codecpar);
            audio.outStream->codecpar->codec_tag = 0;
            audio.outStream->time_base = in->time_base;
            audio.outIndex = audio.outStream->index;
            av_dict_copy(&audio.outStream->metadata, in->metadata, 0); // keep stream tags
        } else {
            const AVCodec *decoder = avcodec_find_decoder(in->codecpar->codec_id);
            const AVCodec *encoder = avcodec_find_encoder_by_name("aac_at");
            if (!encoder) encoder = avcodec_find_encoder(AV_CODEC_ID_AAC);
            if (!decoder || !encoder) { fail("missing aac/decoder"); goto done; }

            audio.dec = avcodec_alloc_context3(decoder);
            avcodec_parameters_to_context(audio.dec, in->codecpar);
            audio.dec->pkt_timebase = in->time_base;
            if ((err = avcodec_open2(audio.dec, decoder, nullptr)) < 0) {
                fail("open audio decoder: " + avErr(err)); goto done;
            }

            audio.enc = avcodec_alloc_context3(encoder);
            audio.enc->sample_rate = audio.dec->sample_rate;
            av_channel_layout_copy(&audio.enc->ch_layout, &audio.dec->ch_layout);

            int profile = profileFor(opts.audioProfile);
            // HE-AAC v2 (parametric stereo) needs exactly 2 channels.
            if (profile == AV_PROFILE_AAC_HE_V2 && audio.enc->ch_layout.nb_channels != 2) {
                profile = AV_PROFILE_AAC_HE;
            }
            audio.enc->profile = profile;
            audio.enc->bit_rate = opts.audioBitrate;
            audio.enc->sample_fmt = (encoder->sample_fmts ? encoder->sample_fmts[0]
                                                          : AV_SAMPLE_FMT_S16);
            audio.enc->time_base = AVRational{1, audio.enc->sample_rate};
            if (ofmt->oformat->flags & AVFMT_GLOBALHEADER)
                audio.enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;

            if ((err = avcodec_open2(audio.enc, encoder, nullptr)) < 0) {
                fail("open aac encoder: " + avErr(err)); goto done;
            }
            audio.outStream = avformat_new_stream(ofmt, nullptr);
            avcodec_parameters_from_context(audio.outStream->codecpar, audio.enc);
            audio.outStream->time_base = audio.enc->time_base;
            audio.outIndex = audio.outStream->index;
            av_dict_copy(&audio.outStream->metadata,
                         ifmt->streams[audio.inIndex]->metadata, 0); // keep stream tags

            // resampler: decoder output -> encoder input
            swr_alloc_set_opts2(&audio.swr,
                &audio.enc->ch_layout, audio.enc->sample_fmt, audio.enc->sample_rate,
                &audio.dec->ch_layout, audio.dec->sample_fmt, audio.dec->sample_rate,
                0, nullptr);
            if ((err = swr_init(audio.swr)) < 0) { fail("swr init: " + avErr(err)); goto done; }
            audio.fifo = av_audio_fifo_alloc(audio.enc->sample_fmt,
                                             audio.enc->ch_layout.nb_channels, 1);
        }
    }

    if (video.inIndex < 0 && audio.inIndex < 0) { fail("no usable streams"); goto done; }

    // -- open file + write header (deferred if the video size isn't known yet)
    {
        bool deferOutput = (video.inIndex >= 0 && video.encode && video.enc == nullptr);
        if (!deferOutput) {
            if ((err = openOutput()) < 0) { fail("open output: " + avErr(err)); goto done; }
        } else {
            dbg(dbgPath, "output header deferred until first decoded video frame");
        }
    }

    // -- helpers (lambdas capture local state) ------------------------------
    {
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    long frameCounter = 0;
    bool fatal = false;
    std::vector<AVPacket *> pending; // packets seen before a deferred header

    // Background CPU pacing. iOS kills a backgrounded app that averages >80% CPU
    // over 60s. x265 encodes on its own worker threads (async), so we can't pace
    // by the feeder thread's own timing — we measure the WHOLE process's CPU time
    // (all threads) and sleep whenever the CPU/wall ratio since throttling began
    // exceeds a safe target. While we sleep, x265 drains its backlog and then goes
    // idle, which pulls the ratio back down. No-op unless setThrottled(true).
    bool thrActive = false;
    double thrWall0 = 0, thrCpu0 = 0;
    const double kThrottleTarget = 0.7;   // target CPU/wall ratio, safely < 0.80
    auto throttle = [&]() {
        if (!throttled_) { thrActive = false; return; }
        if (!thrActive) {                 // just entered background — set baseline
            thrActive = true;
            thrWall0 = nowSeconds();
            thrCpu0 = processCpuSeconds();
            return;
        }
        while (!cancelled_ && throttled_) {
            double wall = nowSeconds() - thrWall0;
            double cpu = processCpuSeconds() - thrCpu0;
            if (wall <= 0 || cpu / wall <= kThrottleTarget) break;
            double needWall = cpu / kThrottleTarget;          // wall to hit target
            double chunk = std::min(needWall - wall, 0.1);    // cancel-responsive
            if (chunk <= 0) break;
            std::this_thread::sleep_for(std::chrono::duration<double>(chunk));
        }
    };

    auto emitProgress = [&](double pts) {
        if (pts > processedSeconds) processedSeconds = pts;
        double wall = nowSeconds() - startWall - pausedAccum_;
        double now = nowSeconds();
        if (now - lastEmit < 0.2) return;
        lastEmit = now;
        if (onProgress) {
            Progress p;
            p.processedSeconds = processedSeconds;
            p.totalSeconds = totalDuration;
            p.speed = wall > 0.01 ? processedSeconds / wall : 0;
            // avio_tell is a no-op position query (used routinely by muxers), so
            // it's safe to read on both the read and write contexts each tick.
            if (ifmt && ifmt->pb) p.inputBytes = avio_tell(ifmt->pb);
            p.totalInputBytes = totalInputBytes;
            if (ofmt && ofmt->pb) p.outputBytes = avio_tell(ofmt->pb);
            onProgress(p);
        }
    };

    auto writePacket = [&](AVPacket *p, StreamCtx &s, AVRational srcTb) {
        p->stream_index = s.outIndex;
        av_packet_rescale_ts(p, srcTb, s.outStream->time_base);
        double t = p->pts * av_q2d(s.outStream->time_base);
        // Header may be deferred until the first video frame; buffer any
        // (audio) packets that arrive before it so nothing is written early.
        if (!headerWritten) {
            pending.push_back(av_packet_clone(p));
            return 0;
        }
        int w = av_interleaved_write_frame(ofmt, p);
        emitProgress(t);
        return w;
    };

    // encode + write a video frame (nullptr flushes)
    auto encodeVideo = [&](AVFrame *f) -> int {
        int e = avcodec_send_frame(video.enc, f);
        if (e < 0) return e;
        while (true) {
            e = avcodec_receive_packet(video.enc, pkt);
            if (e == AVERROR(EAGAIN) || e == AVERROR_EOF) return 0;
            if (e < 0) return e;
            writePacket(pkt, video, video.enc->time_base);
            av_packet_unref(pkt);
        }
    };

    // pull complete frames from fifo, encode (nullptr flushes encoder)
    auto drainAudioFifo = [&](bool flush) -> int {
        int fs = audio.enc->frame_size > 0 ? audio.enc->frame_size : 1024;
        while (av_audio_fifo_size(audio.fifo) >= fs ||
               (flush && av_audio_fifo_size(audio.fifo) > 0)) {
            int n = std::min(fs, av_audio_fifo_size(audio.fifo));
            AVFrame *out = av_frame_alloc();
            out->nb_samples = n;
            av_channel_layout_copy(&out->ch_layout, &audio.enc->ch_layout);
            out->format = audio.enc->sample_fmt;
            out->sample_rate = audio.enc->sample_rate;
            av_frame_get_buffer(out, 0);
            av_audio_fifo_read(audio.fifo, (void **)out->data, n);
            out->pts = audio.nextAudioPts;
            audio.nextAudioPts += n;

            int e = avcodec_send_frame(audio.enc, out);
            av_frame_free(&out);
            if (e < 0) return e;
            while (true) {
                e = avcodec_receive_packet(audio.enc, pkt);
                if (e == AVERROR(EAGAIN) || e == AVERROR_EOF) break;
                if (e < 0) return e;
                writePacket(pkt, audio, audio.enc->time_base);
                av_packet_unref(pkt);
            }
            if (!flush) break; // one frame per outer call when streaming
        }
        return 0;
    };

    // -- main demux loop ----------------------------------------------------
    while (gate()) {
        err = av_read_frame(ifmt, pkt);
        if (err < 0) break; // EOF

        // Preview mode: stop once the video stream passes the limit. Gauge on the
        // video stream so we always capture a full N seconds of frames; the flush
        // path after the loop finalizes the (short) file normally.
        if (opts.durationLimitSeconds > 0 && pkt->stream_index == video.inIndex &&
            pkt->pts != AV_NOPTS_VALUE) {
            double t = pkt->pts * av_q2d(ifmt->streams[video.inIndex]->time_base);
            if (t >= opts.durationLimitSeconds) { av_packet_unref(pkt); break; }
        }

        if (pkt->stream_index == video.inIndex && video.outStream) {
            if (!video.encode) {
                writePacket(pkt, video, ifmt->streams[video.inIndex]->time_base);
            } else {
                if (avcodec_send_packet(video.dec, pkt) >= 0) {
                    while (avcodec_receive_frame(video.dec, frame) >= 0) {
                        // deferred setup: codecpar reported no size, so take the
                        // frame size from the first decoded frame, then open the
                        // encoder + output and flush any pre-header packets.
                        if (!video.enc) {
                            if ((err = setupVideoEncoder(frame->width, frame->height)) < 0) {
                                fail("open libx265 (deferred): " + avErr(err));
                                av_frame_unref(frame); fatal = true; break;
                            }
                            if ((err = openOutput()) < 0) {
                                fail("open output (deferred): " + avErr(err));
                                av_frame_unref(frame); fatal = true; break;
                            }
                            for (AVPacket *pp : pending) {
                                av_interleaved_write_frame(ofmt, pp);
                                av_packet_free(&pp);
                            }
                            pending.clear();
                        }
                        // lazily build scaler once we know the source format
                        if (!video.sws) {
                            video.sws = sws_getContext(
                                frame->width, frame->height, (AVPixelFormat)frame->format,
                                video.enc->width, video.enc->height, video.enc->pix_fmt,
                                SWS_BILINEAR, nullptr, nullptr, nullptr);
                            video.scaled->format = video.enc->pix_fmt;
                            video.scaled->width = video.enc->width;
                            video.scaled->height = video.enc->height;
                            av_frame_get_buffer(video.scaled, 0);
                            // Tag the frames handed to the encoder with the source
                            // color info so it isn't assumed to be SDR BT.709.
                            video.scaled->color_primaries = video.enc->color_primaries;
                            video.scaled->color_trc       = video.enc->color_trc;
                            video.scaled->colorspace      = video.enc->colorspace;
                            video.scaled->color_range     = video.enc->color_range;
                            dbg(dbgPath, std::string("first decoded frame: ") +
                                         (av_get_pix_fmt_name((AVPixelFormat)frame->format) ?
                                          av_get_pix_fmt_name((AVPixelFormat)frame->format) : "?") +
                                         " " + std::to_string(frame->width) + "x" + std::to_string(frame->height) +
                                         " sample_aspect_ratio=" + std::to_string(frame->sample_aspect_ratio.num) +
                                         "/" + std::to_string(frame->sample_aspect_ratio.den) +
                                         " color_range=" + std::to_string((int)frame->color_range) +
                                         " colorspace=" + std::to_string((int)frame->colorspace) +
                                         " sws=" + (video.sws ? "ok" : "NULL"));
                            if (!video.sws) {
                                fail("scaler init failed for " +
                                     std::string(av_get_pix_fmt_name((AVPixelFormat)frame->format) ?
                                                 av_get_pix_fmt_name((AVPixelFormat)frame->format) : "?") +
                                     " " + std::to_string(frame->width) + "x" + std::to_string(frame->height) +
                                     " -> yuv420p " + std::to_string(video.enc->width) + "x" +
                                     std::to_string(video.enc->height));
                                dbg(dbgPath, error);
                                av_frame_unref(frame);
                                fatal = true;
                                break;
                            }
                        }
                        av_frame_make_writable(video.scaled);
                        sws_scale(video.sws, frame->data, frame->linesize, 0,
                                  frame->height, video.scaled->data, video.scaled->linesize);
                        video.scaled->pts = av_rescale_q(frame->best_effort_timestamp,
                                                         video.dec->pkt_timebase,
                                                         video.enc->time_base);
                        if (++frameCounter % 10 == 1)
                            dbg(dbgPath, "encoding frame #" + std::to_string(frameCounter) +
                                         " pts=" + std::to_string(video.scaled->pts));
                        encodeVideo(video.scaled);
                        av_frame_unref(frame);
                    }
                }
            }
        } else if (pkt->stream_index == audio.inIndex && audio.outStream) {
            if (!audio.encode) {
                writePacket(pkt, audio, ifmt->streams[audio.inIndex]->time_base);
            } else {
                if (avcodec_send_packet(audio.dec, pkt) >= 0) {
                    while (avcodec_receive_frame(audio.dec, frame) >= 0) {
                        uint8_t **conv = nullptr;
                        int outSamples = (int)av_rescale_rnd(
                            swr_get_delay(audio.swr, audio.dec->sample_rate) + frame->nb_samples,
                            audio.enc->sample_rate, audio.dec->sample_rate, AV_ROUND_UP);
                        av_samples_alloc_array_and_samples(&conv, nullptr,
                            audio.enc->ch_layout.nb_channels, outSamples,
                            audio.enc->sample_fmt, 0);
                        int got = swr_convert(audio.swr, conv, outSamples,
                            (const uint8_t **)frame->data, frame->nb_samples);
                        if (got > 0) av_audio_fifo_write(audio.fifo, (void **)conv, got);
                        if (conv) { av_freep(&conv[0]); av_freep(&conv); }
                        av_frame_unref(frame);
                        drainAudioFifo(false);
                    }
                }
            }
        }
        av_packet_unref(pkt);
        if (fatal) break;
        throttle();   // pace whole-process CPU when backgrounded
    }

    // deferred setup never triggered => no video frame was ever decoded
    if (!headerWritten && !cancelled_ && error.empty())
        fail("no video frames decoded");

    // -- flush --------------------------------------------------------------
    dbg(dbgPath, "demux loop done after " + std::to_string(frameCounter) + " video frames, flushing");
    if (!cancelled_ && error.empty()) {
        if (video.encode && video.enc) { dbg(dbgPath, "flushing video encoder"); encodeVideo(nullptr); dbg(dbgPath, "video encoder flushed"); }
        if (audio.encode) {
            // drain decoder, then fifo, then encoder
            avcodec_send_packet(audio.dec, nullptr);
            while (avcodec_receive_frame(audio.dec, frame) >= 0) {
                uint8_t **conv = nullptr;
                int outSamples = (int)av_rescale_rnd(
                    swr_get_delay(audio.swr, audio.dec->sample_rate) + frame->nb_samples,
                    audio.enc->sample_rate, audio.dec->sample_rate, AV_ROUND_UP);
                av_samples_alloc_array_and_samples(&conv, nullptr,
                    audio.enc->ch_layout.nb_channels, outSamples, audio.enc->sample_fmt, 0);
                int got = swr_convert(audio.swr, conv, outSamples,
                    (const uint8_t **)frame->data, frame->nb_samples);
                if (got > 0) av_audio_fifo_write(audio.fifo, (void **)conv, got);
                if (conv) { av_freep(&conv[0]); av_freep(&conv); }
                av_frame_unref(frame);
            }
            drainAudioFifo(true);
            avcodec_send_frame(audio.enc, nullptr);
            while (avcodec_receive_packet(audio.enc, pkt) >= 0) {
                writePacket(pkt, audio, audio.enc->time_base);
                av_packet_unref(pkt);
            }
        }
    }

    for (AVPacket *pp : pending) av_packet_free(&pp); // unflushed on error paths
    av_packet_free(&pkt);
    av_frame_free(&frame);
    }

done:
    dbg(dbgPath, "=== run done: cancelled=" + std::to_string((int)cancelled_.load()) +
                 " error=" + (error.empty() ? "(none)" : error) + " ===");
    if (headerWritten && !cancelled_ && error.empty()) {
        av_write_trailer(ofmt);
    }
    closeStream(video);
    closeStream(audio);
    if (ofmt) {
        if (ofmt->pb && !(ofmt->oformat->flags & AVFMT_NOFILE)) avio_closep(&ofmt->pb);
        avformat_free_context(ofmt);
    }
    if (ifmt) avformat_close_input(&ifmt);

    // remove partial output on cancel/failure
    if ((cancelled_ || !error.empty())) {
        std::remove(opts.outputPath.c_str());
    }

    if (onFinished) {
        if (cancelled_) onFinished(false, "cancelled");
        else if (!error.empty()) onFinished(false, error);
        else onFinished(true, "");
    }
}

} // namespace tvc
