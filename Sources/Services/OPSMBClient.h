#import <Foundation/Foundation.h>
#import "OPFileSource.h"

/**
 * SMB2 backend (dialects 2.0.2 / 2.1) with NTLMv2 authentication.
 *
 * For SMB the first path component is the share name, e.g. "/Media/Movies"
 * connects to \\\\host\\Media and browses "Movies".
 */
@interface OPSMBClient : NSObject <OPFileSource>

- (id)initWithServer:(OPServer *)server;

@end
