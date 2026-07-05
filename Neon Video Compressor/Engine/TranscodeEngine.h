//
//  TranscodeEngine.h
//  Objective-C bridge over the C++ Transcoder, consumable from Swift.
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TVCStreamMode) {
    TVCStreamModeEncode = 0,
    TVCStreamModeCopy   = 1,
};

typedef NS_ENUM(NSInteger, TVCAudioProfile) {
    TVCAudioProfileLowComplexity    = 0,   // AAC-LC
    TVCAudioProfileHighEfficiency   = 1,   // HE-AAC
    TVCAudioProfileHighEfficiencyV2 = 2,   // HE-AAC v2
};

@interface TVCMediaInfo : NSObject
@property (nonatomic) BOOL ok;
@property (nonatomic) double durationSeconds;
@property (nonatomic) NSInteger videoWidth;
@property (nonatomic) NSInteger videoHeight;
@property (nonatomic, copy) NSString *videoCodec;
@property (nonatomic, copy) NSString *audioCodec;
@property (nonatomic) NSInteger audioChannels;
@property (nonatomic) NSInteger audioSampleRate;
@property (nonatomic, copy, nullable) NSString *error;
@end

@interface TVCEncodeOptions : NSObject
@property (nonatomic, copy) NSString *inputPath;
@property (nonatomic, copy) NSString *outputPath;
@property (nonatomic) TVCStreamMode videoMode;
@property (nonatomic) TVCStreamMode audioMode;
@property (nonatomic) NSInteger crf;            // libx265 -crf
@property (nonatomic, copy) NSString *preset;   // libx265 -preset
@property (nonatomic, copy, nullable) NSString *x265Params;
@property (nonatomic) TVCAudioProfile audioProfile;
@property (nonatomic) NSInteger audioBitrate;   // bits/sec
@property (nonatomic) double durationLimitSeconds;  // stop after N seconds (0 = whole file)
@end

@interface TVCTranscoder : NSObject

/// Synchronous probe of a media file's properties.
+ (TVCMediaInfo *)probe:(NSString *)path;

/// Fired on the main queue, ~5x/sec.
@property (nonatomic, copy, nullable) void (^onProgress)(double processedSeconds,
                                                         double totalSeconds,
                                                         double speed,
                                                         long long inputBytes,
                                                         long long totalInputBytes,
                                                         long long outputBytes);
/// Fired on the main queue exactly once.
@property (nonatomic, copy, nullable) void (^onFinished)(BOOL success,
                                                         NSString *_Nullable error);

- (void)startWithOptions:(TVCEncodeOptions *)options;
- (void)pause;
- (void)resume;
- (void)cancel;

/// Pace the encoder to stay under iOS's background CPU limit. Enable while
/// backgrounded (keep-awake), disable in the foreground for full speed.
- (void)setThrottled:(BOOL)on;

@end

NS_ASSUME_NONNULL_END
