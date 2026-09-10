#import <Foundation/Foundation.h>
#import "OPServer.h"
#import "OPFileItem.h"

/**
 * Localhost HTTP server that turns FTP/SMB files into seekable HTTP streams.
 *
 * MPMoviePlayer only speaks HTTP(S). For FTP/SMB items the browser asks the
 * proxy for a URL like http://127.0.0.1:<port>/<token>; the player's
 * `Range: bytes=S-E` requests are translated into FTP REST+RETR segments or
 * SMB offset READs, so playback starts immediately and seeking works.
 */
@interface OPLocalHTTPProxy : NSObject

+ (instancetype)sharedProxy;

// Starts the listener (idempotent). Returns NO when the socket cannot bind.
- (BOOL)start:(NSError **)error;
- (void)stop;

// Registers an item and returns its localhost URL, or nil when the protocol
// cannot be proxied (WebDAV streams directly and never reaches the proxy).
- (NSURL *)proxyURLForServer:(OPServer *)server item:(OPFileItem *)item;

@end
