#import "OPHTTPTask.h"

// Base64 for HTTP Basic auth. -[NSData base64EncodedStringWithOptions:] is
// iOS 7+, so encode manually to stay iOS 6 safe.
static NSString *OPBase64Encode(NSData *data) {
    static const char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    NSUInteger length = data.length;
    NSMutableString *result = [NSMutableString stringWithCapacity:((length + 2) / 3) * 4];
    for (NSUInteger i = 0; i < length; i += 3) {
        NSUInteger n = bytes[i] << 16;
        if (i + 1 < length) n |= bytes[i + 1] << 8;
        if (i + 2 < length) n |= bytes[i + 2];
        [result appendFormat:@"%c", table[(n >> 18) & 0x3F]];
        [result appendFormat:@"%c", table[(n >> 12) & 0x3F]];
        [result appendFormat:@"%c", (i + 1 < length) ? table[(n >> 6) & 0x3F] : '='];
        [result appendFormat:@"%c", (i + 2 < length) ? table[n & 0x3F] : '='];
    }
    return result;
}

@interface OPHTTPTask () <NSURLConnectionDataDelegate, NSURLConnectionDelegate>
@property (nonatomic, strong) NSURLConnection *connection;
@property (nonatomic, strong) NSURLRequest *request;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *password;
@property (nonatomic, strong) NSMutableData *outputData;
@property (nonatomic, strong) NSOutputStream *outputStream;
@property (nonatomic, copy) void (^progressBlock)(long long, long long);
@property (nonatomic, copy) void (^completionBlock)(NSError *);
@property (nonatomic, assign) long long receivedLength;
@property (nonatomic, assign) long long expectedLength;
@property (nonatomic, assign) BOOL finished;
@end

@implementation OPHTTPTask

- (id)initWithRequest:(NSURLRequest *)request
             username:(NSString *)username
             password:(NSString *)password
           outputData:(NSMutableData *)outputData
         outputStream:(NSOutputStream *)outputStream
             progress:(void (^)(long long, long long))progress
           completion:(void (^)(NSError *))completion {
    self = [super init];
    if (self) {
        _request = request;
        _username = [username copy];
        _password = [password copy];
        _outputData = outputData;
        _outputStream = outputStream;
        _progressBlock = [progress copy];
        _completionBlock = [completion copy];
    }
    return self;
}

- (void)start {
    self.connection = [[NSURLConnection alloc] initWithRequest:self.request
                                                     delegate:self
                                             startImmediately:NO];
    [self.connection scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [self.connection start];
}

- (void)cancel {
    [self.connection cancel];
    self.connection = nil;
    [self closeStream];
}

- (void)closeStream {
    if (self.outputStream) {
        [self.outputStream close];
    }
}

- (void)finishWithError:(NSError *)error {
    if (self.finished) {
        return;
    }
    self.finished = YES;
    [self closeStream];
    if (self.completionBlock) {
        self.completionBlock(error);
    }
}

#pragma mark - NSURLConnectionDataDelegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode >= 400) {
            NSError *error = [NSError errorWithDomain:@"OPWebDAV"
                                                 code:http.statusCode
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                            [NSString stringWithFormat:@"服务器返回 HTTP %ld", (long)http.statusCode]}];
            [self.connection cancel];
            self.connection = nil;
            [self finishWithError:error];
            return;
        }
    }
    self.expectedLength = response.expectedContentLength;
    if (self.outputStream) {
        [self.outputStream open];
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    if (self.outputData) {
        [self.outputData appendData:data];
    }
    if (self.outputStream) {
        const uint8_t *bytes = (const uint8_t *)data.bytes;
        NSUInteger remaining = data.length;
        while (remaining > 0) {
            NSInteger written = [self.outputStream write:bytes maxLength:remaining];
            if (written <= 0) {
                break;
            }
            bytes += written;
            remaining -= (NSUInteger)written;
        }
    }
    self.receivedLength += (long long)data.length;
    if (self.progressBlock) {
        self.progressBlock(self.receivedLength, self.expectedLength);
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    self.connection = nil;
    [self finishWithError:nil];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    self.connection = nil;
    [self finishWithError:error];
}

- (void)connection:(NSURLConnection *)connection
        willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
    NSString *method = challenge.protectionSpace.authenticationMethod;
    if ([method isEqualToString:NSURLAuthenticationMethodServerTrust] &&
        challenge.protectionSpace.serverTrust) {
        // NAS WebDAV servers frequently use self-signed certificates on the
        // LAN; accept the trust so browsing is not blocked.
        NSURLCredential *credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
        [challenge.sender useCredential:credential forAuthenticationChallenge:challenge];
        return;
    }
    if (self.username.length > 0 && challenge.previousFailureCount < 2) {
        NSURLCredential *credential = [NSURLCredential credentialWithUser:self.username
                                                                 password:self.password
                                                              persistence:NSURLCredentialPersistenceForSession];
        [challenge.sender useCredential:credential forAuthenticationChallenge:challenge];
        return;
    }
    [challenge.sender continueWithoutCredentialForAuthenticationChallenge:challenge];
}

@end
