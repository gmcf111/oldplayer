#import <Foundation/Foundation.h>

@class OPSoftDecoder;

@protocol OPSoftDecoderDelegate <NSObject>
@optional
// Called on the main thread when probing finished and playback can start.
- (void)softDecoderDidOpen:(OPSoftDecoder *)decoder;
// Called on the main thread for every video frame. The view must copy the
// planes synchronously; the buffers are freed when this returns.
- (void)softDecoder:(OPSoftDecoder *)decoder
         didRenderY:(const uint8_t *)y
                  U:(const uint8_t *)u
                  V:(const uint8_t *)v
              width:(int)width
             height:(int)height
            strideY:(int)strideY
            strideU:(int)strideU
            strideV:(int)strideV;
// Periodic progress, main thread.
- (void)softDecoder:(OPSoftDecoder *)decoder
  didUpdatePosition:(double)position
           duration:(double)duration;
// Playback reached EOF (main thread).
- (void)softDecoderDidFinish:(OPSoftDecoder *)decoder;
// Open or decode failed before any frame/audio (main thread).
- (void)softDecoder:(OPSoftDecoder *)decoder didFailWithError:(NSError *)error;
@end

/**
 * Software decoder built on FFmpeg (libavformat/libavcodec/libswscale/
 * libswresample). Decodes formats the system player cannot handle
 * (mkv/avi/rmvb/flv/wmv/...) on the CPU, outputs YUV420P video frames to
 * the delegate and PCM audio to an AudioQueue.
 *
 * Threading: demux+decode run on one worker thread; all delegate callbacks
 * fire on the main thread. Call stop before releasing.
 */
@interface OPSoftDecoder : NSObject

- (id)initWithURLString:(NSString *)url title:(NSString *)title;

@property (nonatomic, weak) id<OPSoftDecoderDelegate> delegate;

@property (nonatomic, readonly) double duration;
@property (nonatomic, readonly) double currentTime;
@property (nonatomic, readonly) BOOL playing;
@property (nonatomic, readonly) BOOL hasVideo;
@property (nonatomic, readonly) BOOL hasAudio;
@property (nonatomic, readonly) int videoWidth;
@property (nonatomic, readonly) int videoHeight;
@property (nonatomic, readonly, copy) NSString *title;

- (void)open;   // async probe, then auto-plays
- (void)play;
- (void)pause;
- (void)seekToTime:(double)seconds;
- (void)stop;

@end
