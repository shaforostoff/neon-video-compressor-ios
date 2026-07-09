//
//  TranscodeEngine.mm
//
#import "TranscodeEngine.h"
#include "Transcoder.hpp"
#include <string>
#include <memory>

static std::string cppstr(NSString *s) { return s ? std::string(s.UTF8String) : std::string(); }

@implementation TVCMediaInfo
@end

@implementation TVCEncodeOptions
- (instancetype)init {
    if ((self = [super init])) {
        _crf = 30;
        _preset = @"slow";
        _audioProfile = TVCAudioProfileHighEfficiency;
        _audioBitrate = 40000;
        _videoMode = TVCStreamModeEncode;
        _audioMode = TVCStreamModeEncode;
    }
    return self;
}
@end

@implementation TVCTranscoder {
    std::unique_ptr<tvc::Transcoder> _core;
}

- (instancetype)init {
    if ((self = [super init])) {
        _core = std::make_unique<tvc::Transcoder>();
    }
    return self;
}

+ (TVCMediaInfo *)probe:(NSString *)path {
    tvc::MediaInfo mi = tvc::Transcoder::probe(cppstr(path));
    TVCMediaInfo *out = [TVCMediaInfo new];
    out.ok = mi.ok;
    out.durationSeconds = mi.durationSeconds;
    out.videoWidth = mi.videoWidth;
    out.videoHeight = mi.videoHeight;
    out.videoCodec = [NSString stringWithUTF8String:mi.videoCodec.c_str()];
    out.audioCodec = [NSString stringWithUTF8String:mi.audioCodec.c_str()];
    out.audioChannels = mi.audioChannels;
    out.audioSampleRate = mi.audioSampleRate;
    out.error = mi.error.empty() ? nil : [NSString stringWithUTF8String:mi.error.c_str()];
    return out;
}

- (void)startWithOptions:(TVCEncodeOptions *)options {
    tvc::TranscodeOptions o;
    o.inputPath = cppstr(options.inputPath);
    o.outputPath = cppstr(options.outputPath);
    o.videoMode = options.videoMode == TVCStreamModeCopy ? tvc::StreamMode::Copy
                                                         : tvc::StreamMode::Encode;
    o.audioMode = options.audioMode == TVCStreamModeCopy ? tvc::StreamMode::Copy
                                                         : tvc::StreamMode::Encode;
    o.crf = (int)options.crf;
    o.preset = cppstr(options.preset);
    o.x265Params = cppstr(options.x265Params);
    switch (options.audioProfile) {
        case TVCAudioProfileLowComplexity:    o.audioProfile = tvc::AudioProfile::AAC_LC; break;
        case TVCAudioProfileHighEfficiency:   o.audioProfile = tvc::AudioProfile::HE_AAC; break;
        case TVCAudioProfileHighEfficiencyV2: o.audioProfile = tvc::AudioProfile::HE_AACv2; break;
    }
    o.audioBitrate = (int)options.audioBitrate;
    o.durationLimitSeconds = options.durationLimitSeconds;
    o.forceEightBit = options.forceEightBit;

    __weak TVCTranscoder *weakSelf = self;
    _core->onProgress = [weakSelf](const tvc::Progress &p) {
        TVCTranscoder *s = weakSelf;
        if (!s || !s.onProgress) return;
        double proc = p.processedSeconds, tot = p.totalSeconds, spd = p.speed;
        long long inB = p.inputBytes, totIn = p.totalInputBytes, outB = p.outputBytes;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (s.onProgress) s.onProgress(proc, tot, spd, inB, totIn, outB);
        });
    };
    _core->onFinished = [weakSelf](bool success, const std::string &err) {
        TVCTranscoder *s = weakSelf;
        if (!s) return;
        NSString *e = err.empty() ? nil : [NSString stringWithUTF8String:err.c_str()];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (s.onFinished) s.onFinished(success, e);
        });
    };
    _core->start(o);
}

- (void)pause  { _core->pause(); }
- (void)resume { _core->resume(); }
- (void)cancel { _core->cancel(); }
- (void)setThrottled:(BOOL)on { _core->setThrottled(on); }

@end
