#import "OPFileSourceFactory.h"
#import "OPWebDAVClient.h"
#import "OPFTPClient.h"

@implementation OPFileSourceFactory

+ (id<OPFileSource>)sourceForServer:(OPServer *)server {
    switch (server.protocolType) {
        case OPProtocolTypeFTP:
            return [[OPFTPClient alloc] initWithServer:server];
        case OPProtocolTypeSMB:
            // Implemented in Stage 3 (OPSMBClient).
            return nil;
        case OPProtocolTypeWebDAV:
        default:
            return [[OPWebDAVClient alloc] initWithServer:server];
    }
}

@end
