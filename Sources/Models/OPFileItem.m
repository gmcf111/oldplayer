#import "OPFileItem.h"

@implementation OPFileItem

- (NSString *)extensionLowercase {
    NSString *ext = [self.name pathExtension];
    return [ext lowercaseString];
}

- (BOOL)isMediaFile {
    return [self isSystemSupportedFormat] || [self isSoftDecodedFormat];
}

- (BOOL)isSystemSupportedFormat {
    static NSSet *systemExtensions = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        systemExtensions = [NSSet setWithObjects:
            @"mp4", @"m4v", @"mov", @"3gp", @"3g2",
            @"mp3", @"m4a", @"aac", @"wav", @"aif", @"aiff", @"caf", @"m4b",
            nil];
    });
    return [systemExtensions containsObject:[self extensionLowercase]];
}

- (BOOL)isSoftDecodedFormat {
    static NSSet *softExtensions = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        softExtensions = [NSSet setWithObjects:
            // video containers / streams the system player cannot open
            @"mkv", @"webm", @"avi", @"flv", @"f4v",
            @"rm", @"rmvb", @"wmv", @"asf",
            @"mpg", @"mpeg", @"mpe", @"ts", @"m2ts", @"vob", @"dat", @"ogv",
            @"dv", @"264",
            // audio codecs/containers outside CoreAudio's reach
            @"ogg", @"oga", @"opus", @"spx", @"flac", @"ape", @"wv", @"tta",
            @"mpc", @"mp2", @"ac3", @"dts", @"wma", @"ra", @"aifc",
            nil];
    });
    return [softExtensions containsObject:[self extensionLowercase]];
}

- (BOOL)isPlayableVideo {
    static NSSet *videoExtensions = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        videoExtensions = [NSSet setWithObjects:@"mp4", @"m4v", @"mov", @"3gp", @"3g2", nil];
    });
    return [videoExtensions containsObject:[self extensionLowercase]];
}

- (NSString *)formattedSize {
    if (self.isDirectory || self.fileSize <= 0) {
        return @"";
    }
    static const char *units[] = { "B", "KB", "MB", "GB", "TB" };
    double size = (double)self.fileSize;
    int unit = 0;
    while (size >= 1024.0 && unit < 4) {
        size /= 1024.0;
        unit++;
    }
    if (unit == 0) {
        return [NSString stringWithFormat:@"%lld B", self.fileSize];
    }
    return [NSString stringWithFormat:@"%.1f %s", size, units[unit]];
}

@end
