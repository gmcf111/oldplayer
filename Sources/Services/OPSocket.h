#import <Foundation/Foundation.h>

/**
 * Minimal blocking TCP socket over POSIX sockets.
 *
 * Used by the FTP and SMB backends, which both run their blocking protocol
 * loops on a background queue. Timeouts are enforced with SO_RCVTIMEO /
 * SO_SNDTIMEO so a stalled peer cannot block forever.
 */
@interface OPSocket : NSObject

+ (instancetype)connectToHost:(NSString *)host
                         port:(NSInteger)port
                      timeout:(NSTimeInterval)timeout
                        error:(NSError **)error;

// Wraps an already-connected descriptor (e.g. from accept()).
- (id)initWithFileDescriptor:(int)fd;

- (BOOL)sendData:(NSData *)data error:(NSError **)error;
// Reads one '\n'-terminated line (the newline is included).
- (NSData *)readLineWithTimeout:(NSTimeInterval)timeout error:(NSError **)error;
// Reads up to maxLength bytes. Returns the count, 0 on EOF, -1 on error.
- (NSInteger)readIntoBuffer:(uint8_t *)buffer
                  maxLength:(NSUInteger)maxLength
                    timeout:(NSTimeInterval)timeout
                      error:(NSError **)error;
// Reads exactly `length` bytes (or returns nil on EOF/error).
- (NSData *)readDataOfLength:(NSUInteger)length
                     timeout:(NSTimeInterval)timeout
                       error:(NSError **)error;

- (BOOL)isConnected;
- (void)close;

@end
