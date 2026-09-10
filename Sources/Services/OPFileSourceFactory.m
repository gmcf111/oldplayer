#import "OPFileSourceFactory.h"
#import "OPWebDAVClient.h"

@implementation OPFileSourceFactory

+ (id<OPFileSource>)sourceForServer:(OPServer *)server {
    switch (server.protocolType) {
        case OPProtocolTypeFTP:
            // Implemented in Stage 2 (OPFTPClient).
            return nil;
        case OPProtocolTypeSMB:
            // Implemented in Stage 3 (OPSMBClient).
            return nil;
        case OPProtocolTypeWebDAV:
        default:
            return [[OPWebDAVClient alloc] initWithServer:server];
    }
}

@end
