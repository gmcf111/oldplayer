#import "OPSoftDecoder.h"

#ifdef HAS_FFMPEG
#pragma message("OPSoftDecoder: FULL build with FFmpeg")
#else
#pragma message("OPSoftDecoder: STUB build without FFmpeg")
#endif

#ifdef HAS_FFMPEG
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#include <libavutil/imgutils.h>
#include <libavutil/channel_layout.h>
#endif
#import <AudioToolbox/AudioToolbox.h>
#import <QuartzCore/QuartzCore.h>
#include <unistd.h>
#include <math.h>

// Forward declarations for the C callbacks below (the methods are defined
// later in the @implementation).
@interface OPSoftDecoder (PrivateCallbacks)
- (BOOL)shouldStop;
- (void)fillAudioBuffer:(AudioQueueBufferRef)buffer forQueue:(AudioQueueRef)queue;
@end

static const int kOutSampleRate = 44100;
static const int kOutChannels = 2;
static const int kOutBytesPerFrame = 4; // stereo S16
static const size_t kRingSize = 1024 * 1024; // ~6s of PCM
static const UInt32 kAQBufferBytes = 36864;  // ~0.2s per buffer
static const int kMaxPendingVideoFrames = 4;

#ifdef HAS_FFMPEG
static int DecodeInterruptCallback(void *opaque) {
    OPSoftDecoder *decoder = (__bridge OPSoftDecoder *)opaque;
    return [decoder shouldStop] ? 1 : 0;
}

static void AudioQueueCallback(void *inUserData, AudioQueueRef inAQ,
                               AudioQueueBufferRef inBuffer) {
    OPSoftDecoder *decoder = (__bridge OPSoftDecoder *)inUserData;
    [decoder fillAudioBuffer:inBuffer forQueue:inAQ];
    if (![decoder shouldStop]) {
        AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
    }
}
#endif

@interface OPSoftDecoder () {
#ifdef HAS_FFMPEG
    AVFormatContext *fmtCtx;
    AVCodecContext *videoCtx;
    AVCodecContext *audioCtx;
    struct SwsContext *swsCtx;
    SwrContext *swrCtx;
    AVBSFContext *videoBSF;
    int videoStreamIndex;
    int audioStreamIndex;
    AVRational videoTimeBase;
    int audioInRate;
    AVFrame *tmpYUV;
    uint8_t *tmpYUVBuf;
    int tmpYUVSize;
    uint8_t *pcmBuf;
    unsigned int pcmBufSize;
#endif
    NSThread *worker;
    NSLock *stateLock;
    NSCondition *exitCondition;
    BOOL workerDone;
    BOOL stopFlag;
    BOOL pauseFlag;
    BOOL seekFlag;
    BOOL needPreview;   // decode one video frame while paused (after seek)
    BOOL eofFlag;
    BOOL openedFlag;
    BOOL everPresented;
    BOOL audioBegan;    // first audio sample decoded
    double seekTarget;
    double dropUntil;   // drop video frames older than this (post-seek)
    int generation;     // bumped on seek/stop; stale main-thread frames drop
    double durationSec;
    int pendingFrames;
    double lastReportTime;
    // Buffering detection: stamp of the last actually-played content
    // (presented video frame or consumed audio). Guarded by stateLock;
    // touched from the worker, audio, and main threads.
    double lastProgressStamp;
    BOOL stallReported;

    AudioQueueRef audioQueue;
    AudioQueueBufferRef aqBuffers[3];
    BOOL aqRunning;
    uint8_t *ring;
    size_t ringRead;
    size_t ringWrite;
    size_t ringUsed;
    NSLock *ringLock;
    double audioPlayedSamples; // advanced by the AudioQueue callback
    double audioBase;          // clock offset in seconds (seek target)
    BOOL audioClockLive;       // NO while priming buffers before (re)start
    double videoAnchorPts;     // last presented video pts (video-only clock)
    double videoAnchorNow;     // CACurrentMediaTime() at that frame
    double videoFrozen;        // clock value while paused (video-only)
    int videoW;
    int videoH;
    NSString *urlString;
    NSString *titleString;
}
@end

@implementation OPSoftDecoder

- (id)initWithURLString:(NSString *)url title:(NSString *)title {
    self = [super init];
    if (self) {
        urlString = [url copy] ?: @"";
        titleString = [title copy] ?: @"";
        stateLock = [[NSLock alloc] init];
        ringLock = [[NSLock alloc] init];
        exitCondition = [[NSCondition alloc] init];
#ifdef HAS_FFMPEG
        videoStreamIndex = -1;
        audioStreamIndex = -1;
#endif
    }
    return self;
}

- (void)dealloc {
    [self stop];
    if (ring) { free(ring); ring = NULL; }
}

- (NSString *)title { return titleString; }
- (double)duration { return durationSec; }
- (int)videoWidth { return videoW; }
- (int)videoHeight { return videoH; }
- (BOOL)hasVideo {
#ifdef HAS_FFMPEG
    return videoStreamIndex >= 0;
#else
    return NO;
#endif
}
- (BOOL)hasAudio {
#ifdef HAS_FFMPEG
    return audioStreamIndex >= 0;
#else
    return NO;
#endif
}
- (BOOL)playing {
    [stateLock lock];
    BOOL p = openedFlag && !pauseFlag && !stopFlag;
    [stateLock unlock];
    return p;
}

- (double)currentTime {
    [stateLock lock];
    double t;
    if (audioBegan) {
        t = audioBase + audioPlayedSamples / kOutSampleRate;
    } else if (pauseFlag) {
        t = videoFrozen;
    } else {
        t = videoAnchorNow > 0 ? (CACurrentMediaTime() - videoAnchorNow + videoAnchorPts) : 0;
    }
    [stateLock unlock];
    return t < 0 ? 0 : t;
}

- (BOOL)shouldStop {
    [stateLock lock];
    BOOL s = stopFlag;
    [stateLock unlock];
    return s;
}

#pragma mark - Control (main thread)

- (void)open {
#ifdef HAS_FFMPEG
    @synchronized (self) {
        if (worker || stopFlag) return;
        worker = [[NSThread alloc] initWithTarget:self
                                         selector:@selector(workerMain)
                                           object:nil];
        [worker start];
    }
#else
    [self reportFailWithMessage:@"当前构建不含软解码库（FFmpeg），无法播放此格式。"];
#endif
}

- (void)play {
    [stateLock lock];
    pauseFlag = NO;
    BOOL needStart = openedFlag && audioQueue && !aqRunning && audioBegan;
    if (needStart) audioClockLive = YES;
    [stateLock unlock];
#ifdef HAS_FFMPEG
    if (needStart) {
        AudioQueueStart(audioQueue, NULL);
        [stateLock lock]; aqRunning = YES; [stateLock unlock];
    }
#endif
}

- (void)pause {
    [stateLock lock];
    pauseFlag = YES;
    videoFrozen = [self unlockedClock];
    audioClockLive = NO;
    [stateLock unlock];
#ifdef HAS_FFMPEG
    if (audioQueue) AudioQueuePause(audioQueue);
    [stateLock lock]; aqRunning = NO; [stateLock unlock];
#endif
}

- (void)seekToTime:(double)seconds {
    if (seconds < 0) seconds = 0;
    if (durationSec > 0 && seconds > durationSec) seconds = durationSec;
    [stateLock lock];
    seekTarget = seconds;
    seekFlag = YES;
    if (pauseFlag) needPreview = YES;
    [stateLock unlock];
}

- (void)stop {
    [stateLock lock];
    stopFlag = YES;
    [stateLock unlock];
#ifdef HAS_FFMPEG
    if (audioQueue) AudioQueueStop(audioQueue, true);
#endif
    NSThread *w = nil;
    @synchronized (self) { w = worker; }
    if (w) {
        // Wait for the worker to unwind (bounded; it polls stopFlag).
        [exitCondition lock];
        NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:8];
        while (!workerDone) {
            if (![exitCondition waitUntilDate:limit]) break;
        }
        [exitCondition unlock];
    }
}

#pragma mark - Clock (pure logic: always compiled, uses no FFmpeg types,
// so callers outside #ifdef HAS_FFMPEG can use these too)

// Must only be called on the worker thread (mirrors -currentTime).
- (double)unlockedClockSnapshot {
    if (audioBegan) {
        [stateLock lock];
        double t = audioBase + audioPlayedSamples / kOutSampleRate;
        [stateLock unlock];
        return t;
    }
    [stateLock lock];
    double t;
    if (pauseFlag) t = videoFrozen;
    else t = videoAnchorNow > 0 ? (CACurrentMediaTime() - videoAnchorNow + videoAnchorPts) : 0;
    [stateLock unlock];
    return t;
}

// Called with stateLock held.
- (double)unlockedClock {
    if (audioBegan) return audioBase + audioPlayedSamples / kOutSampleRate;
    if (pauseFlag) return videoFrozen;
    return videoAnchorNow > 0 ? (CACurrentMediaTime() - videoAnchorNow + videoAnchorPts) : 0;
}

- (int)currentGeneration {
    [stateLock lock];
    int g = generation;
    [stateLock unlock];
    return g;
}

#pragma mark - Worker

- (void)workerMain {
    @autoreleasepool {
#ifdef HAS_FFMPEG
        NSString *error = [self openInput];
        if (error) {
            [self reportFailWithMessage:error];
        } else {
            [stateLock lock]; openedFlag = YES; [stateLock unlock];
            [self reportOpen];
            if ([self hasAudio]) [self startAudioQueue];
            [self decodeLoop];
            // Clean EOF leaves pb->error at 0; a dropped connection sets it.
            // Capture before teardown closes the input.
            BOOL streamBroken = (fmtCtx && fmtCtx->pb && fmtCtx->pb->error != 0);
            if (everPresented || audioBegan) {
                if (![self shouldStop]) {
                    if (streamBroken) {
                        [self reportInterruptWithMessage:@"网络连接中断，播放已停止。"];
                    } else {
                        [self performSelectorOnMainThread:@selector(notifyFinish)
                                               withObject:nil
                                            waitUntilDone:NO];
                    }
                }
            } else if (![self shouldStop]) {
                [self reportFailWithMessage:@"播放中断，媒体可能已损坏。"];
            }
        }
        [self teardownAudio];
        [self cleanupFFmpeg];
#endif
        [exitCondition lock];
        workerDone = YES;
        [exitCondition signal];
        [exitCondition unlock];
    }
}

#ifdef HAS_FFMPEG

#pragma mark - Open / probe

- (NSString *)openInput {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ av_log_set_level(AV_LOG_WARNING); });

    fmtCtx = avformat_alloc_context();
    if (!fmtCtx) return @"内存不足";
    fmtCtx->interrupt_callback.callback = DecodeInterruptCallback;
    fmtCtx->interrupt_callback.opaque = (__bridge void *)self;

    AVDictionary *opts = NULL;
    av_dict_set(&opts, "probesize", "5242880", 0);
    av_dict_set(&opts, "analyzeduration", "5000000", 0);
    av_dict_set(&opts, "reconnect", "1", 0);
    av_dict_set(&opts, "reconnect_streamed", "1", 0);
    av_dict_set(&opts, "reconnect_delay_max", "5", 0);
    int r = avformat_open_input(&fmtCtx, [urlString UTF8String], NULL, &opts);
    av_dict_free(&opts);
    if (r < 0 || [self shouldStop]) {
        return [self shouldStop] ? nil : @"无法打开媒体（网络或地址错误）";
    }
    if (avformat_find_stream_info(fmtCtx, NULL) < 0) return @"无法解析媒体信息";

    if (fmtCtx->duration != AV_NOPTS_VALUE && fmtCtx->duration > 0) {
        durationSec = fmtCtx->duration / 1000000.0;
    }

    // Video: best stream, but skip attached cover art.
    int vIdx = av_find_best_stream(fmtCtx, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (vIdx >= 0 && (fmtCtx->streams[vIdx]->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
        vIdx = -1;
    }
    if (vIdx >= 0) {
        if ([self openVideoStream:vIdx]) {
            videoStreamIndex = vIdx;
        } else {
            vIdx = -1; // video unusable; may still play audio
        }
    }
    int aIdx = av_find_best_stream(fmtCtx, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (aIdx >= 0) {
        if ([self openAudioStream:aIdx]) {
            audioStreamIndex = aIdx;
        }
    }
    if (videoStreamIndex < 0 && audioStreamIndex < 0) return @"没有可解码的音视频流";

    if (durationSec <= 0) {
        // Fall back to a stream duration.
        int idx = videoStreamIndex >= 0 ? videoStreamIndex : audioStreamIndex;
        AVStream *st = fmtCtx->streams[idx];
        if (st->duration != AV_NOPTS_VALUE && st->duration > 0) {
            durationSec = st->duration * av_q2d(st->time_base);
        }
    }
    if (durationSec < 0) durationSec = 0;
    return nil;
}

- (BOOL)openVideoStream:(int)index {
    AVStream *st = fmtCtx->streams[index];
    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!codec) return NO;
    videoCtx = avcodec_alloc_context3(codec);
    if (!videoCtx) return NO;
    if (avcodec_parameters_to_context(videoCtx, st->codecpar) < 0) return NO;
    // Old Xvid/DivX AVIs may use packed B-frames; unpack before decoding.
    if (videoCtx->codec_id == AV_CODEC_ID_MPEG4) {
        const AVBSFContext *unused = NULL; (void)unused;
        const AVBitStreamFilter *bsf = av_bsf_get_by_name("mpeg4_unpack_bframes");
        if (bsf && av_bsf_alloc(bsf, &videoBSF) == 0) {
            if (avcodec_parameters_copy(videoBSF->par_in, st->codecpar) == 0 &&
                av_bsf_init(videoBSF) == 0) {
                videoBSF->time_base_in = st->time_base;
            } else {
                av_bsf_free(&videoBSF);
                videoBSF = NULL;
            }
        }
    }
    if (avcodec_open2(videoCtx, codec, NULL) < 0) return NO;
    videoTimeBase = st->time_base;
    videoW = videoCtx->width;
    videoH = videoCtx->height;
    return YES;
}

- (BOOL)openAudioStream:(int)index {
    AVStream *st = fmtCtx->streams[index];
    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!codec) return NO;
    audioCtx = avcodec_alloc_context3(codec);
    if (!audioCtx) return NO;
    if (avcodec_parameters_to_context(audioCtx, st->codecpar) < 0) return NO;
    if (avcodec_open2(audioCtx, codec, NULL) < 0) return NO;

    AVChannelLayout inLayout = audioCtx->ch_layout;
    if (inLayout.nb_channels == 0) {
        av_channel_layout_default(&inLayout, 2);
    }
    AVChannelLayout outLayout = AV_CHANNEL_LAYOUT_STEREO;
    audioInRate = audioCtx->sample_rate > 0 ? audioCtx->sample_rate : 44100;
    if (swr_alloc_set_opts2(&swrCtx, &outLayout, AV_SAMPLE_FMT_S16, kOutSampleRate,
                            &inLayout, audioCtx->sample_fmt, audioInRate, 0, NULL) != 0) {
        return NO;
    }
    if (inLayout.nb_channels != audioCtx->ch_layout.nb_channels) {
        av_channel_layout_uninit(&inLayout);
    }
    if (swr_init(swrCtx) < 0) return NO;
    return YES;
}

#pragma mark - Decode loop

- (void)decodeLoop {
    AVPacket *pkt = av_packet_alloc();
    AVPacket *filtered = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    if (!pkt || !filtered || !frame) {
        av_packet_free(&pkt); av_packet_free(&filtered); av_frame_free(&frame);
        return;
    }
    [self resetStallDetector];
    while (![self shouldStop]) {
        if ([self takeSeekFlag]) {
            [self doSeek];
            eofFlag = NO;
            if (videoCtx) avcodec_flush_buffers(videoCtx);
            if (audioCtx) avcodec_flush_buffers(audioCtx);
        }
        [stateLock lock];
        BOOL paused = pauseFlag && !needPreview;
        [stateLock unlock];
        if (paused) { usleep(20000); continue; }
        if (!eofFlag) [self checkForStall];
        [stateLock lock];
        BOOL crowded = pendingFrames >= kMaxPendingVideoFrames;
        [stateLock unlock];
        if (crowded) { usleep(8000); continue; }

        if (!eofFlag) {
            int r = av_read_frame(fmtCtx, pkt);
            if (r < 0) {
                eofFlag = YES;
                // Flush decoders: NULL packet, then drain.
                if (videoCtx) {
                    avcodec_send_packet(videoCtx, NULL);
                    [self drainDecoder:videoCtx intoFrame:frame isVideo:YES];
                }
                if (audioCtx) {
                    avcodec_send_packet(audioCtx, NULL);
                    [self drainDecoder:audioCtx intoFrame:frame isVideo:NO];
                }
                continue;
            }
            if (pkt->stream_index == videoStreamIndex) {
                AVPacket *src = pkt;
                if (videoBSF) {
                    if (av_bsf_send_packet(videoBSF, pkt) == 0) {
                        while (av_bsf_receive_packet(videoBSF, filtered) == 0) {
                            [self decodePacket:filtered ctx:videoCtx frame:frame isVideo:YES];
                            av_packet_unref(filtered);
                        }
                    }
                    av_packet_unref(pkt);
                } else {
                    [self decodePacket:src ctx:videoCtx frame:frame isVideo:YES];
                    av_packet_unref(pkt);
                }
            } else if (pkt->stream_index == audioStreamIndex) {
                [self decodePacket:pkt ctx:audioCtx frame:frame isVideo:NO];
                av_packet_unref(pkt);
            } else {
                av_packet_unref(pkt);
            }
        } else {
            // EOF reached and decoders drained: let the tail play out.
            double remaining = [self tailRemaining];
            if (remaining <= 0.1) break;
            [self reportProgress];
            usleep(50000);
        }
    }
    av_packet_free(&pkt);
    av_packet_free(&filtered);
    av_frame_free(&frame);
}

// Seconds of decoded-but-unplayed content left (audio ring + pending video).
- (double)tailRemaining {
    [ringLock lock];
    double audioSec = (double)ringUsed / (kOutSampleRate * kOutBytesPerFrame);
    [ringLock unlock];
    [stateLock lock];
    int pending = pendingFrames;
    [stateLock unlock];
    return audioSec + pending * 0.04;
}

- (void)decodePacket:(AVPacket *)pkt ctx:(AVCodecContext *)ctx
               frame:(AVFrame *)frame isVideo:(BOOL)isVideo {
    if (avcodec_send_packet(ctx, pkt) < 0) return;
    while (avcodec_receive_frame(ctx, frame) == 0) {
        if (isVideo) {
            [self handleVideoFrame:frame];
        } else {
            [self handleAudioFrame:frame];
        }
        av_frame_unref(frame);
        if ([self shouldStop] || [self peekSeekFlag]) break;
    }
}

- (void)drainDecoder:(AVCodecContext *)ctx intoFrame:(AVFrame *)frame isVideo:(BOOL)isVideo {
    while (avcodec_receive_frame(ctx, frame) == 0) {
        if (isVideo) [self handleVideoFrame:frame]; else [self handleAudioFrame:frame];
        av_frame_unref(frame);
        if ([self shouldStop]) break;
    }
}

#pragma mark - Video frames

- (void)handleVideoFrame:(AVFrame *)f {
    double pts = NAN;
    if (f->best_effort_timestamp != AV_NOPTS_VALUE) {
        pts = f->best_effort_timestamp * av_q2d(videoTimeBase);
    }
    AVFrame *out = f;
    if (f->format != AV_PIX_FMT_YUV420P || f->width != videoW || f->height != videoH) {
        out = [self convertToYUV420P:f];
        if (!out) return;
        if (!isnan(pts)) { /* pts unchanged */ }
    }
    [stateLock lock];
    double until = dropUntil;
    BOOL stop = stopFlag;
    [stateLock unlock];
    if (stop) return;
    if (!isnan(pts) && pts < until) return; // stale pre-seek frame

    if (!isnan(pts)) {
        // Late frames are dropped; early frames wait for the clock.
        if (everPresented && pts < [self unlockedClockSnapshot] - 0.15) return;
        while (![self shouldStop] && ![self peekSeekFlag] &&
               pts > [self unlockedClockSnapshot] + 0.03) {
            usleep(5000);
        }
        if ([self shouldStop] || [self peekSeekFlag]) return;
        if (everPresented && pts < [self unlockedClockSnapshot] - 0.15) return;
        [stateLock lock];
        videoAnchorPts = pts;
        videoAnchorNow = CACurrentMediaTime();
        [stateLock unlock];
    }
    // __block: the pointer itself is mutated (freed) inside the block.
    __block AVFrame *owned = av_frame_clone(out);
    if (!owned) return;
    int w = out->width, h = out->height;
    int sY = out->linesize[0], sU = out->linesize[1], sV = out->linesize[2];
    const uint8_t *pY = out->data[0], *pU = out->data[1], *pV = out->data[2];
    [stateLock lock];
    pendingFrames++;
    int gen = generation;
    [stateLock unlock];
    id<OPSoftDecoderDelegate> delegate = self.delegate;
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            if (gen == [self currentGeneration] && ![self shouldStop]) {
                if ([delegate respondsToSelector:@selector(softDecoder:didRenderY:U:V:width:height:strideY:strideU:strideV:)]) {
                    [delegate softDecoder:self didRenderY:pY U:pU V:pV
                                    width:w height:h strideY:sY strideU:sU strideV:sV];
                }
                // Already on the main thread: report inline.
                [self notePlaybackProgress];
                [stateLock lock];
                needPreview = NO; // a current frame reached the screen
                [stateLock unlock];
            }
            av_frame_free(&owned);
            [stateLock lock];
            pendingFrames--;
            [stateLock unlock];
        }
    });
    everPresented = YES; // worker thread only
    [self reportProgressIfDue];
}

// Convert any pixel format to the reusable YUV420P buffer.
- (AVFrame *)convertToYUV420P:(AVFrame *)f {
    int w = f->width, h = f->height;
    if (!tmpYUV || tmpYUV->width != w || tmpYUV->height != h) {
        av_frame_free(&tmpYUV);
        if (tmpYUVBuf) { av_free(tmpYUVBuf); tmpYUVBuf = NULL; }
        tmpYUVSize = 0;
        tmpYUV = av_frame_alloc();
        if (!tmpYUV) return NULL;
        tmpYUV->format = AV_PIX_FMT_YUV420P;
        tmpYUV->width = w; tmpYUV->height = h;
        tmpYUVSize = av_image_alloc(tmpYUV->data, tmpYUV->linesize, w, h, AV_PIX_FMT_YUV420P, 16);
        if (tmpYUVSize < 0) { av_frame_free(&tmpYUV); tmpYUVSize = 0; return NULL; }
    }
    swsCtx = sws_getCachedContext(swsCtx, w, h, (enum AVPixelFormat)f->format,
                                  w, h, AV_PIX_FMT_YUV420P, SWS_BILINEAR,
                                  NULL, NULL, NULL);
    if (!swsCtx) return NULL;
    sws_scale(swsCtx, (const uint8_t *const *)f->data, f->linesize, 0, h,
              tmpYUV->data, tmpYUV->linesize);
    tmpYUV->width = w; tmpYUV->height = h;
    return tmpYUV;
}

#pragma mark - Audio frames + AudioQueue

- (void)handleAudioFrame:(AVFrame *)f {
    if (!swrCtx) return;
    int capacity = av_rescale_rnd(swr_get_delay(swrCtx, audioInRate) + f->nb_samples,
                                  kOutSampleRate, audioInRate, AV_ROUND_UP);
    if (capacity <= 0) return;
    unsigned int need = (capacity + 32) * kOutBytesPerFrame;
    if (!pcmBuf || pcmBufSize < need) {
        av_free(pcmBuf);
        pcmBuf = (uint8_t *)av_malloc(need);
        if (!pcmBuf) { pcmBufSize = 0; return; }
        pcmBufSize = need;
    }
    uint8_t *dst = pcmBuf;
    int got = swr_convert(swrCtx, &dst, capacity,
                          (const uint8_t **)f->data, f->nb_samples);
    if (got <= 0) return;
    [self ringWriteBytes:pcmBuf length:(size_t)got * kOutBytesPerFrame];
    audioBegan = YES; // worker thread only
}

- (void)ringWriteBytes:(const uint8_t *)bytes length:(size_t)len {
    size_t off = 0;
    while (off < len) {
        if ([self shouldStop] || [self peekSeekFlag]) return;
        [ringLock lock];
        size_t free = kRingSize - ringUsed;
        if (free == 0) {
            [ringLock unlock];
            usleep(8000);
            continue;
        }
        size_t n = len - off < free ? len - off : free;
        size_t first = kRingSize - ringWrite < n ? kRingSize - ringWrite : n;
        memcpy(ring + ringWrite, bytes + off, first);
        if (n > first) memcpy(ring, bytes + off + first, n - first);
        ringWrite = (ringWrite + n) % kRingSize;
        ringUsed += n;
        [ringLock unlock];
        off += n;
    }
}

- (void)startAudioQueue {
    AudioStreamBasicDescription fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.mSampleRate = kOutSampleRate;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    fmt.mBytesPerPacket = kOutBytesPerFrame;
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerFrame = kOutBytesPerFrame;
    fmt.mChannelsPerFrame = kOutChannels;
    fmt.mBitsPerChannel = 16;
    if (AudioQueueNewOutput(&fmt, AudioQueueCallback, (__bridge void *)self,
                            NULL, NULL, 0, &audioQueue) != noErr) {
        audioQueue = NULL;
        return;
    }
    [stateLock lock]; audioClockLive = NO; [stateLock unlock];
    for (int i = 0; i < 3; i++) {
        if (AudioQueueAllocateBuffer(audioQueue, kAQBufferBytes, &aqBuffers[i]) != noErr) {
            aqBuffers[i] = NULL;
            continue;
        }
        [self fillAudioBuffer:aqBuffers[i] forQueue:audioQueue];
        AudioQueueEnqueueBuffer(audioQueue, aqBuffers[i], 0, NULL);
    }
    AudioQueueStart(audioQueue, NULL);
    [stateLock lock]; aqRunning = YES; audioClockLive = YES; [stateLock unlock];
}

- (void)fillAudioBuffer:(AudioQueueBufferRef)buffer forQueue:(AudioQueueRef)queue {
    (void)queue;
    UInt32 want = buffer->mAudioDataBytesCapacity;
    uint8_t *dst = (uint8_t *)buffer->mAudioData;
    UInt32 got = 0;
    BOOL stopped = [self shouldStop];
    [ringLock lock];
    if (!stopped && ringUsed > 0) {
        UInt32 n = ringUsed < want ? (UInt32)ringUsed : want;
        size_t first = kRingSize - ringRead < n ? kRingSize - ringRead : n;
        memcpy(dst, ring + ringRead, first);
        if (n > first) memcpy(dst + first, ring, n - first);
        ringRead = (ringRead + n) % kRingSize;
        ringUsed -= n;
        got = n;
    }
    [ringLock unlock];
    if (got < want) memset(dst + got, 0, want - got);
    buffer->mAudioDataByteSize = want;
    BOOL consumedRealAudio = (!stopped && got > 0);
    if (!stopped) {
        [stateLock lock];
        if (audioClockLive) {
            audioPlayedSamples += (double)want / kOutBytesPerFrame;
        }
        [stateLock unlock];
    }
    if (consumedRealAudio) [self notePlaybackProgress];
}

- (void)teardownAudio {
    if (audioQueue) {
        AudioQueueStop(audioQueue, true);
        AudioQueueDispose(audioQueue, true);
        audioQueue = NULL;
    }
    [stateLock lock]; aqRunning = NO; [stateLock unlock];
}

#pragma mark - Seek

- (BOOL)takeSeekFlag {
    [stateLock lock];
    BOOL s = seekFlag;
    if (s) seekFlag = NO;
    [stateLock unlock];
    return s;
}

- (BOOL)peekSeekFlag {
    [stateLock lock];
    BOOL s = seekFlag;
    [stateLock unlock];
    return s;
}

- (void)doSeek {
    [stateLock lock];
    double target = seekTarget;
    generation++;
    [stateLock unlock];
    int64_t ts = (int64_t)(target * 1000000.0);
    avformat_seek_file(fmtCtx, -1, INT64_MIN, ts, INT64_MAX, AVSEEK_FLAG_BACKWARD);
    [ringLock lock];
    ringRead = ringWrite = ringUsed = 0;
    [ringLock unlock];
    [stateLock lock];
    audioPlayedSamples = 0;
    audioBase = target;
    videoAnchorPts = target;
    videoAnchorNow = CACurrentMediaTime();
    videoFrozen = target;
    dropUntil = target - 0.10;
    // NOTE: pendingFrames is left alone; stale main-thread frames drop via
    // generation and still decrement the counter when they unwind.
    BOOL paused = pauseFlag;
    audioClockLive = NO; // re-enabled below if the queue restarts
    [stateLock unlock];
    if (audioQueue) {
        AudioQueueStop(audioQueue, true);
        for (int i = 0; i < 3; i++) {
            if (aqBuffers[i]) {
                [self fillAudioBuffer:aqBuffers[i] forQueue:audioQueue];
                AudioQueueEnqueueBuffer(audioQueue, aqBuffers[i], 0, NULL);
            }
        }
        if (!paused) {
            AudioQueueStart(audioQueue, NULL);
            [stateLock lock]; aqRunning = YES; audioClockLive = YES; [stateLock unlock];
        } else {
            [stateLock lock];
            aqRunning = NO;
            needPreview = YES; // decode one frame so the picture follows the seek
            [stateLock unlock];
        }
    } else if (paused) {
        [stateLock lock]; needPreview = YES; [stateLock unlock];
    }
    eofFlag = NO;
    [self resetStallDetector];
    [self reportProgressNow];
}

- (void)reportProgressIfDue {
    double now = CACurrentMediaTime();
    if (now - lastReportTime > 0.5) {
        lastReportTime = now;
        [self reportProgressNow];
    }
}

- (void)reportProgress {
    double now = CACurrentMediaTime();
    if (now - lastReportTime > 0.5) {
        lastReportTime = now;
        [self reportProgressNow];
    }
}

- (void)reportProgressNow {
    double pos = [self unlockedClockSnapshot];
    double dur = durationSec;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(softDecoder:didUpdatePosition:duration:)]) {
            [self.delegate softDecoder:self didUpdatePosition:pos duration:dur];
        }
    });
}

- (void)reportOpen {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(softDecoderDidOpen:)]) {
            [self.delegate softDecoderDidOpen:self];
        }
    });
}

- (void)notifyFinish {
    if ([self.delegate respondsToSelector:@selector(softDecoderDidFinish:)]) {
        [self.delegate softDecoderDidFinish:self];
    }
}

// Playback-side progress: called when a video frame reaches the screen or
// real audio bytes are consumed. Clears a previously reported stall.
- (void)notePlaybackProgress {
    BOOL recovered = NO;
    [stateLock lock];
    lastProgressStamp = CACurrentMediaTime();
    if (stallReported) {
        stallReported = NO;
        recovered = YES;
    }
    [stateLock unlock];
    if (recovered) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(softDecoderDidEndBuffering:)]) {
                [self.delegate softDecoderDidEndBuffering:self];
            }
        });
    }
}

// Worker-side check, called from the decode loop: nothing played for a
// while means the network (or source) stalled.
- (void)checkForStall {
    BOOL stalled = NO;
    [stateLock lock];
    if (!stallReported && CACurrentMediaTime() - lastProgressStamp > 1.5) {
        stallReported = YES;
        stalled = YES;
    }
    [stateLock unlock];
    if (stalled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(softDecoderDidStartBuffering:)]) {
                [self.delegate softDecoderDidStartBuffering:self];
            }
        });
    }
}

- (void)resetStallDetector {
    BOOL wasStalled = NO;
    [stateLock lock];
    lastProgressStamp = CACurrentMediaTime();
    if (stallReported) {
        stallReported = NO;
        wasStalled = YES;
    }
    [stateLock unlock];
    if (wasStalled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(softDecoderDidEndBuffering:)]) {
                [self.delegate softDecoderDidEndBuffering:self];
            }
        });
    }
}

#endif // HAS_FFMPEG

- (void)reportInterruptWithMessage:(NSString *)message {
    NSError *error = [NSError errorWithDomain:@"OPSoftDecoder" code:-2
                                     userInfo:message ? @{NSLocalizedDescriptionKey: message} : nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(softDecoder:didInterruptWithError:)]) {
            [self.delegate softDecoder:self didInterruptWithError:error];
        }
    });
}

- (void)reportFailWithMessage:(NSString *)message {
    NSError *error = [NSError errorWithDomain:@"OPSoftDecoder" code:-1
                                     userInfo:message ? @{NSLocalizedDescriptionKey: message} : nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(softDecoder:didFailWithError:)]) {
            [self.delegate softDecoder:self didFailWithError:error];
        }
    });
}

#ifdef HAS_FFMPEG
- (void)cleanupFFmpeg {
    if (videoBSF) { av_bsf_free(&videoBSF); videoBSF = NULL; }
    if (swsCtx) { sws_freeContext(swsCtx); swsCtx = NULL; }
    if (swrCtx) { swr_free(&swrCtx); swrCtx = NULL; }
    if (tmpYUV) { av_frame_free(&tmpYUV); }
    if (tmpYUVBuf) { av_freep(&tmpYUVBuf); tmpYUVSize = 0; }
    if (pcmBuf) { av_free(pcmBuf); pcmBuf = NULL; pcmBufSize = 0; }
    if (videoCtx) { avcodec_free_context(&videoCtx); }
    if (audioCtx) { avcodec_free_context(&audioCtx); }
    if (fmtCtx) { avformat_close_input(&fmtCtx); }
}
#endif

@end
