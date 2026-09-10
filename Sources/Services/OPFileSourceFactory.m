#import "OPFileSourceFactory.h"
#import "OPWebDAVClient.h"
#import "OPFTPClient.h"
#import "OPSMBClient.h"

@implementation OPFileSourceFactory

+ (id<OPFileSource>)sourceForServer:(OPServer *)server {
    switch (server.protocolType) {
        case OPProtocolTypeFTP:
            return [[OPFTPClient alloc] initWithServer:server];
        case OPProtocolTypeSMB:
            return [[OPSMBClient alloc] initWithServer:server];
        case OPProtocolTypeWebDAV:
        default:
            return [[OPWebDAVClient alloc] initWithServer:server];
    }
}

@end
