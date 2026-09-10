#import <Foundation/Foundation.h>
#import "OPServer.h"
#import "OPFileItem.h"

/**
 * Local on-disk cache for downloaded media.
 */
@interface OPMediaCache : NSObject

+ (NSString *)cacheDirectory;
// Stable destination for one remote file (created on demand).
+ (NSString *)localPathForServer:(OPServer *)server item:(OPFileItem *)item;
+ (void)clearCache;
+ (unsigned long long)cacheSize;

@end
