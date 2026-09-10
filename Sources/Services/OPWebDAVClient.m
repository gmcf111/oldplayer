#import "OPWebDAVClient.h"
#import "OPHTTPTask.h"
#import "OPWebDAVParser.h"

// Percent-encode one URL path while preserving "/" separators.
static NSString *OPEncodePath(NSString *path) {
    if (path.length == 0) {
        path = @"/";
    }
    if (![path hasPrefix:@"/"]) {
        path = [@"/" stringByAppendingString:path];
    }
    NSArray *components = [path componentsSeparatedByString:@"/"];
    NSMutableArray *encoded = [NSMutableArray arrayWithCapacity:components.count];
    for (NSString *component in components) {
        if (component.length == 0) {
            [encoded addObject:@""];
            continue;
        }
        const char *utf8 = [component UTF8String];
        size_t length = strlen(utf8);
        NSMutableString *out = [NSMutableString stringWithCapacity:length];
        for (size_t i = 0; i < length; i++) {
            unsigned char c = (unsigned char)utf8[i];
            if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~') {
                [out appendFormat:@"%c", c];
            } else {
                [out appendFormat:@"%%%02X", c];
            }
        }
        [encoded addObject:out];
    }
    return [encoded componentsJoinedByString:@"/"];
}

@interface OPWebDAVClient ()
@property (nonatomic, strong) OPServer *server;
@property (nonatomic, strong) NSMutableArray *tasks;
@end

@implementation OPWebDAVClient

- (id)initWithServer:(OPServer *)server {
    self = [super init];
    if (self) {
        _server = server;
        _tasks = [NSMutableArray array];
    }
    return self;
}

- (NSURL *)URLForPath:(NSString *)path {
    NSString *scheme = self.server.secure ? @"https" : @"http";
    NSString *encodedPath = OPEncodePath(path);
    NSString *string = [NSString stringWithFormat:@"%@://%@:%ld%@",
                        scheme, self.server.host ?: @"localhost",
                        (long)self.server.port, encodedPath];
    return [NSURL URLWithString:string];
}

// Percent-encodes one userinfo component (RFC 3986 unreserved set only).
static NSString *OPEncodeUserInfo(NSString *string) {
    const char *utf8 = [string UTF8String];
    size_t length = utf8 ? strlen(utf8) : 0;
    NSMutableString *out = [NSMutableString stringWithCapacity:length];
    for (size_t i = 0; i < length; i++) {
        unsigned char c = (unsigned char)utf8[i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~') {
            [out appendFormat:@"%c", c];
        } else {
            [out appendFormat:@"%%%02X", c];
        }
    }
    return out;
}

// Direct HTTP(S) URL for true streaming in MPMoviePlayer. Basic credentials
// ride in the userinfo part; servers that need Digest or reject userinfo
// fail fast and the browser falls back to download-then-play.
- (NSURL *)streamURLForItem:(OPFileItem *)item {
    NSString *scheme = self.server.secure ? @"https" : @"http";
    NSString *authority = self.server.host ?: @"localhost";
    if (self.server.username.length > 0) {
        authority = [NSString stringWithFormat:@"%@:%@@%@",
                     OPEncodeUserInfo(self.server.username),
                     OPEncodeUserInfo(self.server.password ?: @""),
                     authority];
    }
    NSString *string = [NSString stringWithFormat:@"%@://%@:%ld%@",
                        scheme, authority,
                        (long)self.server.port, OPEncodePath(item.remotePath)];
    return [NSURL URLWithString:string];
}

- (NSString *)authorizationHeader {
    if (self.server.username.length == 0) {
        return nil;
    }
    NSString *pair = [NSString stringWithFormat:@"%@:%@",
                      self.server.username, self.server.password ?: @""];
    NSData *data = [pair dataUsingEncoding:NSUTF8StringEncoding];
    // Reuse OPHTTPTask's base64 by encoding here (kept local and tiny).
    static const char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    NSUInteger length = data.length;
    NSMutableString *b64 = [NSMutableString stringWithCapacity:((length + 2) / 3) * 4];
    for (NSUInteger i = 0; i < length; i += 3) {
        NSUInteger n = bytes[i] << 16;
        if (i + 1 < length) n |= bytes[i + 1] << 8;
        if (i + 2 < length) n |= bytes[i + 2];
        [b64 appendFormat:@"%c", table[(n >> 18) & 0x3F]];
        [b64 appendFormat:@"%c", table[(n >> 12) & 0x3F]];
        [b64 appendFormat:@"%c", (i + 1 < length) ? table[(n >> 6) & 0x3F] : '='];
        [b64 appendFormat:@"%c", (i + 2 < length) ? table[n & 0x3F] : '='];
    }
    return [NSString stringWithFormat:@"Basic %@", b64];
}

- (void)registerTask:(OPHTTPTask *)task {
    [self.tasks addObject:task];
}

- (void)unregisterTask:(OPHTTPTask *)task {
    if ([self.tasks containsObject:task]) {
        [self.tasks removeObject:task];
    }
}

#pragma mark - OPFileSource

- (void)listDirectory:(NSString *)path
           completion:(void (^)(NSArray *, NSError *))completion {
    NSString *requestPath = path.length ? path : @"/";
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[self URLForPath:requestPath]];
    request.HTTPMethod = @"PROPFIND";
    request.timeoutInterval = 30.0;
    [request setValue:@"1" forHTTPHeaderField:@"Depth"];
    [request setValue:@"application/xml; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    NSString *auth = [self authorizationHeader];
    if (auth) {
        [request setValue:auth forHTTPHeaderField:@"Authorization"];
    }
    NSString *body = @"<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                     @"<d:propfind xmlns:d=\"DAV:\"><d:prop>"
                     @"<d:resourcetype/><d:getcontentlength/><d:getlastmodified/>"
                     @"</d:prop></d:propfind>";
    request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    NSMutableData *buffer = [NSMutableData data];
    __weak OPWebDAVClient *weakSelf = self;
    __block __weak OPHTTPTask *weakTask = nil;
    OPHTTPTask *task = [[OPHTTPTask alloc] initWithRequest:request
                                                  username:self.server.username
                                                  password:self.server.password
                                                outputData:buffer
                                              outputStream:nil
                                                  progress:nil
                                                completion:^(NSError *error) {
        OPWebDAVClient *strongSelf = weakSelf;
        OPHTTPTask *strongTask = weakTask;
        if (strongSelf && strongTask) {
            [strongSelf unregisterTask:strongTask];
        }
        if (error) {
            if (completion) completion(nil, error);
            return;
        }
        OPWebDAVParser *parser = [[OPWebDAVParser alloc] init];
        NSArray *items = [parser parseData:buffer requestedPath:requestPath];
        if (completion) completion(items, nil);
    }];
    weakTask = task;
    [self registerTask:task];
    [task start];
}

- (void)downloadFile:(OPFileItem *)item
              toPath:(NSString *)localPath
            progress:(void (^)(long long, long long))progress
          completion:(void (^)(NSError *))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[self URLForPath:item.remotePath]];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 60.0;
    NSString *auth = [self authorizationHeader];
    if (auth) {
        [request setValue:auth forHTTPHeaderField:@"Authorization"];
    }

    [[NSFileManager defaultManager] removeItemAtPath:localPath error:NULL];
    NSOutputStream *stream = [NSOutputStream outputStreamToFileAtPath:localPath append:NO];
    if (!stream) {
        if (completion) {
            completion([NSError errorWithDomain:@"OPWebDAV" code:-1 userInfo:
                        @{NSLocalizedDescriptionKey : @"无法创建本地缓存文件"}]);
        }
        return;
    }

    __weak OPWebDAVClient *weakSelf = self;
    __block __weak OPHTTPTask *weakTask = nil;
    OPHTTPTask *task = [[OPHTTPTask alloc] initWithRequest:request
                                                  username:self.server.username
                                                  password:self.server.password
                                                outputData:nil
                                              outputStream:stream
                                                  progress:progress
                                                completion:^(NSError *error) {
        OPWebDAVClient *strongSelf = weakSelf;
        OPHTTPTask *strongTask = weakTask;
        if (strongSelf && strongTask) {
            [strongSelf unregisterTask:strongTask];
        }
        if (completion) completion(error);
    }];
    weakTask = task;
    [self registerTask:task];
    [task start];
}

- (void)cancelAll {
    NSArray *tasks = [self.tasks copy];
    [self.tasks removeAllObjects];
    for (OPHTTPTask *task in tasks) {
        [task cancel];
    }
}

@end
