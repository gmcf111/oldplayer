#import "OPMediaCache.h"

static unsigned long long OPStableHash(NSString *string) {
    // djb2 over UTF-8; deterministic across runs (unlike -[NSString hash]).
    unsigned long long hash = 5381;
    const char *bytes = [string UTF8String];
    while (bytes && *bytes) {
        hash = ((hash << 5) + hash) + (unsigned char)(*bytes++);
    }
    return hash;
}

static NSString *OPSanitizeComponent(NSString *string) {
    NSCharacterSet *illegal = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|"];
    NSArray *parts = [string componentsSeparatedByCharactersInSet:illegal];
    NSString *clean = [parts componentsJoinedByString:@"_"];
    if (clean.length == 0) {
        clean = @"file";
    }
    return clean;
}

@implementation OPMediaCache

+ (NSString *)cacheDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *base = paths.count > 0 ? paths[0] : NSTemporaryDirectory();
    NSString *dir = [base stringByAppendingPathComponent:@"OPMediaCache"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return dir;
}

+ (NSString *)localPathForServer:(OPServer *)server item:(OPFileItem *)item {
    NSString *cacheDir = [self cacheDirectory];
    NSString *serverDir = [cacheDir stringByAppendingPathComponent:OPSanitizeComponent(server.identifier)];
    [[NSFileManager defaultManager] createDirectoryAtPath:serverDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    NSString *name = OPSanitizeComponent(item.name);
    NSString *unique = [NSString stringWithFormat:@"%016llx-%@", OPStableHash(item.remotePath ?: item.name), name];
    return [serverDir stringByAppendingPathComponent:unique];
}

+ (void)clearCache {
    NSString *dir = [self cacheDirectory];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [fm contentsOfDirectoryAtPath:dir error:NULL];
    for (NSString *name in contents) {
        [fm removeItemAtPath:[dir stringByAppendingPathComponent:name] error:NULL];
    }
}

+ (unsigned long long)cacheSize {
    NSString *dir = [self cacheDirectory];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [fm contentsOfDirectoryAtPath:dir error:NULL];
    unsigned long long total = 0;
    for (NSString *name in contents) {
        NSString *path = [dir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:path isDirectory:&isDir]) {
            if (isDir) {
                NSArray *sub = [fm contentsOfDirectoryAtPath:path error:NULL];
                for (NSString *subName in sub) {
                    NSDictionary *attrs = [fm attributesOfItemAtPath:
                        [path stringByAppendingPathComponent:subName] error:NULL];
                    total += [attrs fileSize];
                }
            } else {
                NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
                total += [attrs fileSize];
            }
        }
    }
    return total;
}

@end
