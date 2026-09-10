#import "OPSMBSeekStream.h"
#import "OPSMBSession.h"

#include <string.h>

static NSString *const OPSMBStreamErrorDomain = @"OPSMBStream";

@interface OPSMBSeekStream ()
@property (nonatomic, strong) OPServer *server;
@property (nonatomic, copy) NSString *remotePath;
@property (nonatomic, strong) OPSMBSession *session;
@property (nonatomic, strong) NSData *fileId;
@property (nonatomic, assign) long long position;
@property (nonatomic, assign) long long length;
@end

@implementation OPSMBSeekStream

- (id)initWithServer:(OPServer *)server remotePath:(NSString *)remotePath {
    self = [super init];
    if (self) {
        _server = server;
        _remotePath = [remotePath copy];
        _length = -1;
    }
    return self;
}

// "/Share/sub/dir" -> share "Share", relative "sub\\dir".
- (BOOL)splitPathShare:(NSString **)shareOut relative:(NSString **)relativeOut {
    NSString *trimmed = self.remotePath ?: @"";
    while ([trimmed hasPrefix:@"/"]) {
        trimmed = [trimmed substringFromIndex:1];
    }
    NSMutableArray *components = [NSMutableArray array];
    for (NSString *component in [trimmed componentsSeparatedByString:@"/"]) {
        if (component.length > 0) {
            [components addObject:component];
        }
    }
    if (components.count == 0) {
        return NO;
    }
    if (shareOut) *shareOut = components[0];
    NSArray *rest = [components subarrayWithRange:NSMakeRange(1, components.count - 1)];
    if (relativeOut) *relativeOut = [rest componentsJoinedByString:@"\\"];
    return YES;
}

- (BOOL)open:(NSError **)error {
    NSString *share = nil;
    NSString *relative = nil;
    if (![self splitPathShare:&share relative:&relative]) {
        if (error) {
            *error = [NSError errorWithDomain:OPSMBStreamErrorDomain code:-1 userInfo:
                      @{NSLocalizedDescriptionKey : @"请在路径中指定共享名，例如 /Media"}];
        }
        return NO;
    }

    OPSMBSession *session = [[OPSMBSession alloc] initWithHost:self.server.host
                                                         port:self.server.port
                                                     username:self.server.username
                                                     password:self.server.password];
    if (![session connect:error]) {
        [session disconnect];
        return NO;
    }
    if (![session treeConnectToShare:share error:error]) {
        [session disconnect];
        return NO;
    }
    uint64_t fileSize = 0;
    NSData *fileId = [session openFile:relative fileSize:&fileSize error:error];
    if (!fileId) {
        [session disconnect];
        return NO;
    }
    self.session = session;
    self.fileId = fileId;
    self.length = (long long)fileSize;
    self.position = 0;
    return YES;
}

- (long long)contentLength {
    return self.length;
}

- (NSString *)contentType {
    return @"application/octet-stream";  // replaced by the proxy's extension map
}

- (NSInteger)read:(uint8_t *)buffer
        maxLength:(NSUInteger)maxLength
            error:(NSError **)error {
    if (!self.session || !self.fileId) {
        if (error) {
            *error = [NSError errorWithDomain:OPSMBStreamErrorDomain code:-1 userInfo:
                      @{NSLocalizedDescriptionKey : @"连接已关闭"}];
        }
        return -1;
    }
    if (self.position >= self.length) {
        return 0;
    }
    NSUInteger total = 0;
    while (total < maxLength && self.position < self.length) {
        uint64_t remaining = (uint64_t)(self.length - self.position);
        uint32_t want = (uint32_t)(maxLength - total);
        if ((uint64_t)want > remaining) {
            want = (uint32_t)remaining;
        }
        if (want > 65536) {
            want = 65536;
        }
        NSData *chunk = [self.session readFileId:self.fileId
                                          offset:(uint64_t)self.position
                                          length:want
                                           error:error];
        if (!chunk) {
            return -1;
        }
        if (chunk.length == 0) {
            break;  // EOF
        }
        memcpy(buffer + total, chunk.bytes, chunk.length);
        total += chunk.length;
        self.position += chunk.length;
    }
    return (NSInteger)total;
}

- (BOOL)seekToOffset:(long long)offset error:(NSError **)error {
    if (offset < 0) {
        offset = 0;
    }
    if (offset > self.length) {
        offset = self.length;
    }
    self.position = offset;
    return YES;
}

- (void)close {
    if (self.session && self.fileId) {
        [self.session closeFileId:self.fileId];
    }
    [self.session disconnect];
    self.session = nil;
    self.fileId = nil;
}

@end
