#import <Foundation/Foundation.h>
#import "OPServer.h"
#import "OPSeekableStream.h"

/**
 * SMB2-backed seekable stream: the session, tree and file handle stay open
 * while reads are served with offset READs.
 */
@interface OPSMBSeekStream : NSObject <OPSeekableStream>

- (id)initWithServer:(OPServer *)server remotePath:(NSString *)remotePath;

@end
