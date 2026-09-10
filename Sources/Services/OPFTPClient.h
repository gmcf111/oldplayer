#import <Foundation/Foundation.h>
#import "OPFileSource.h"

/**
 * FTP backend implemented over POSIX sockets (OPSocket).
 *
 * One control connection is created per operation and closed afterwards, so
 * the client is stateless between calls. All network work happens on a
 * background queue; completion blocks are delivered on the main queue.
 */
@interface OPFTPClient : NSObject <OPFileSource>

- (id)initWithServer:(OPServer *)server;

@end
