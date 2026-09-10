#import <Foundation/Foundation.h>

/**
 * Sequential byte stream with random-access seeks, used by the localhost
 * HTTP proxy to serve MPMoviePlayer range requests from FTP/SMB.
 *
 * Implementations keep one protocol session open across reads; all methods
 * are blocking and run on the proxy's background connection threads.
 */
@protocol OPSeekableStream <NSObject>

// Connects and discovers the length. Returns NO on error.
- (BOOL)open:(NSError **)error;
// Total length, or -1 when the server cannot report it.
- (long long)contentLength;
// Best-effort MIME type for the HTTP Content-Type header.
- (NSString *)contentType;
// Reads up to maxLength bytes from the current position.
// Returns the count, 0 on EOF, -1 on error.
- (NSInteger)read:(uint8_t *)buffer
        maxLength:(NSUInteger)maxLength
            error:(NSError **)error;
// Moves the read position. Reading continues from the new offset.
- (BOOL)seekToOffset:(long long)offset error:(NSError **)error;
- (void)close;

@end
