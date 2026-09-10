#import <Foundation/Foundation.h>
#import "OPFileSource.h"

/**
 * Creates the right OPFileSource implementation for a saved server.
 */
@interface OPFileSourceFactory : NSObject

+ (id<OPFileSource>)sourceForServer:(OPServer *)server;

@end
