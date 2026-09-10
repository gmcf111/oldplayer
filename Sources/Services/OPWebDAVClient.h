#import <Foundation/Foundation.h>
#import "OPFileSource.h"

/**
 * WebDAV backend built on NSURLConnection (iOS 6 safe).
 *
 * Paths are the absolute paths reported by the server (percent-decoded).
 * Authentication uses HTTP Basic plus the standard challenge handler, so
 * both Basic and Digest servers work. Self-signed HTTPS is accepted.
 */
@interface OPWebDAVClient : NSObject <OPFileSource>

- (id)initWithServer:(OPServer *)server;

@end
