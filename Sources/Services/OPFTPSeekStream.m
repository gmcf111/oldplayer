#import "OPFTPSeekStream.h"
#import "OPFTPConnection.h"
#import "OPSocket.h"

@interface OPFTPSeekStream ()
@property (nonatomic, strong) OPServer *server;
@property (nonatomic, copy) NSString *remotePath;
@property (nonatomic, strong) OPFTPConnection *connection;
@property (nonatomic, strong) NSMutableArray *registry;
@property (nonatomic, strong) OPSocket *dataSocket;
@property (nonatomic, assign) long long position;
@property (nonatomic, assign) long long streamOffset;  // file offset the data socket started at
@property (nonatomic, assign) long long length;
@end

@implementation OPFTPSeekStream

- (id)initWithServer:(OPServer *)server remotePath:(NSString *)remotePath {
    self = [super init];
    if (self) {
        _server = server;
        _remotePath = [remotePath copy];
        _registry = [NSMutableArray array];
        _length = -1;
    }
    return self;
}

- (BOOL)open:(NSError **)error {
    OPFTPConnection *connection = [[OPFTPConnection alloc] initWithServer:self.server
                                                                 registry:self.registry];
    if (![connection openAndLogin:error]) {
        [connection close];
        return NO;
    }
    self.connection = connection;

    NSString *sizeReply = nil;
    NSInteger sizeCode = [connection command:[@"SIZE " stringByAppendingString:self.remotePath]
                                       reply:&sizeReply error:NULL];
    if (sizeCode == 213 && sizeReply.length > 4) {
        self.length = [[sizeReply substringFromIndex:4] longLongValue];
    }
    self.position = 0;
    self.streamOffset = 0;
    return YES;
}

- (long long)contentLength {
    return self.length;
}

- (NSString *)contentType {
    return @"application/octet-stream";  // replaced by the proxy's extension map
}

// Closes the current RETR segment and drains the control connection so the
// next command starts in sync.
- (void)abortDataTransfer {
    if (self.dataSocket) {
        [self.dataSocket close];
        self.dataSocket = nil;
        [self.connection readReply:NULL error:NULL];
    }
}

- (BOOL)beginTransferAtOffset:(long long)offset error:(NSError **)error {
    OPSocket *dataSocket = [self.connection openPassiveDataSocket:error];
    if (!dataSocket) {
        return NO;
    }
    if (offset > 0) {
        NSInteger restCode = [self.connection command:[NSString stringWithFormat:@"REST %lld", offset]
                                                reply:NULL error:error];
        if (restCode != 350) {
            [dataSocket close];
            if (error) *error = OPFTPError(@"服务器不支持断点续传 (REST)");
            return NO;
        }
    }
    NSInteger retrCode = [self.connection command:[@"RETR " stringByAppendingString:self.remotePath]
                                            reply:NULL error:error];
    if (retrCode != 150 && retrCode != 125 && retrCode / 100 != 2) {
        [dataSocket close];
        if (error) *error = OPFTPError(@"服务器拒绝读取请求");
        return NO;
    }
    self.dataSocket = dataSocket;
    self.streamOffset = offset;
    return YES;
}

- (NSInteger)read:(uint8_t *)buffer
        maxLength:(NSUInteger)maxLength
            error:(NSError **)error {
    if (!self.connection) {
        if (error) *error = OPFTPError(@"连接已关闭");
        return -1;
    }
    if (self.length >= 0 && self.position >= self.length) {
        return 0;
    }
    if (!self.dataSocket) {
        if (![self beginTransferAtOffset:self.position error:error]) {
            return -1;
        }
    }
    NSUInteger total = 0;
    while (total < maxLength) {
        NSInteger got = [self.dataSocket readIntoBuffer:buffer + total
                                              maxLength:maxLength - total
                                                timeout:30.0
                                                  error:error];
        if (got == 0) {
            [self abortDataTransfer];  // clean EOF; also drains the 226
            break;
        }
        if (got < 0) {
            [self abortDataTransfer];
            return -1;
        }
        total += (NSUInteger)got;
        self.position += got;
        if (self.length >= 0 && self.position >= self.length) {
            break;
        }
    }
    return (NSInteger)total;
}

- (BOOL)seekToOffset:(long long)offset error:(NSError **)error {
    if (offset < 0) {
        offset = 0;
    }
    if (self.length >= 0 && offset > self.length) {
        offset = self.length;
    }
    if (offset == self.position) {
        return YES;
    }
    [self abortDataTransfer];
    self.position = offset;
    return YES;
}

- (void)close {
    [self abortDataTransfer];
    [self.connection close];
    self.connection = nil;
}

@end
