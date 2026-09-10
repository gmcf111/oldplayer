#import "OPFileItem.h"

@implementation OPFileItem

- (NSString *)extensionLowercase {
    NSString *ext = [self.name pathExtension];
    return [ext lowercaseString];
}

- (BOOL)isMediaFile {
    static NSSet *mediaExtensions = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mediaExtensions = [NSSet setWithObjects:
            @"mp4", @"m4v", @"mov", @"3gp", @"3g2",
            @"mp3", @"m4a", @"aac", @"wav", @"aif", @"aiff", @"caf", @"m4b",
            nil];
    });
    return [mediaExtensions containsObject:[self extensionLowercase]];
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
