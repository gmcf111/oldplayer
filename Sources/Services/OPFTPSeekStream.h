#import <Foundation/Foundation.h>
#import "OPServer.h"
#import "OPSeekableStream.h"

/**
 * FTP-backed seekable stream: one control connection stays open while data
 * is fetched with PASV + REST + RETR segments.
 */
@interface OPFTPSeekStream : NSObject <OPSeekableStream>

- (id)initWithServer:(OPServer *)server remotePath:(NSString *)remotePath;

@end
