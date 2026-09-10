#import "OPFTPClient.h"
#import "OPSocket.h"

static NSString *const OPFTPErrorDomain = @"OPFTP";

static NSError *OPFTPError(NSString *message) {
    return [NSError errorWithDomain:OPFTPErrorDomain
                               code:-1
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

#pragma mark - Reply helpers

static NSInteger OPFTPReplyCode(NSString *line) {
    if (line.length < 3) {
        return -1;
    }
    return [[line substringToIndex:3] integerValue];
}

static BOOL OPFTPReplyIsMultiline(NSString *line) {
    return line.length >= 4 && [line characterAtIndex:3] == '-';
}

static NSString *OPFTPJoinPath(NSString *parent, NSString *name) {
    if ([parent isEqualToString:@"/"] || parent.length == 0) {
        return [@"/" stringByAppendingString:name];
    }
    return [NSString stringWithFormat:@"%@/%@", parent, name];
}

#pragma mark - One control connection

@interface OPFTPConnection : NSObject
@property (nonatomic, strong) OPServer *server;
@property (nonatomic, strong) NSMutableArray *registry;
@property (nonatomic, strong) OPSocket *control;
@property (nonatomic, strong) NSMutableArray *owned;
- (id)initWithServer:(OPServer *)server registry:(NSMutableArray *)registry;
- (BOOL)openAndLogin:(NSError **)error;
- (NSInteger)command:(NSString *)command reply:(NSString **)replyOut error:(NSError **)error;
- (NSInteger)readReply:(NSString **)replyOut error:(NSError **)error;
- (OPSocket *)openPassiveDataSocket:(NSError **)error;
- (NSData *)retrieveWithCommand:(NSString *)command error:(NSError **)error;
- (void)close;
@end

@implementation OPFTPConnection

- (id)initWithServer:(OPServer *)server registry:(NSMutableArray *)registry {
    self = [super init];
    if (self) {
        _server = server;
        _registry = registry;
        _owned = [NSMutableArray array];
    }
    return self;
}

- (void)trackSocket:(OPSocket *)socket {
    if (!socket) return;
    [_owned addObject:socket];
    @synchronized(_registry) {
        [_registry addObject:socket];
    }
}

- (NSString *)readLineError:(NSError **)error {
    NSData *data = [self.control readLineWithTimeout:30.0 error:error];
    if (!data) {
        return nil;
    }
    NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!line) {
        line = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    return [line stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
}

- (NSInteger)readReply:(NSString **)replyOut error:(NSError **)error {
    NSString *first = [self readLineError:error];
    if (!first) {
        if (error && !*error) *error = OPFTPError(@"服务器无响应");
        return -1;
    }
    NSInteger code = OPFTPReplyCode(first);
    NSMutableString *full = [NSMutableString stringWithString:first];
    if (OPFTPReplyIsMultiline(first)) {
        while (YES) {
            NSString *line = [self readLineError:error];
            if (!line) break;
            [full appendFormat:@"\n%@", line];
            if (line.length >= 4 && [[line substringToIndex:3] integerValue] == code &&
                [line characterAtIndex:3] == ' ') {
                break;
            }
        }
    }
    if (replyOut) *replyOut = full;
    return code;
}

- (NSInteger)command:(NSString *)command reply:(NSString **)replyOut error:(NSError **)error {
    if (!self.control) {
        if (error) *error = OPFTPError(@"连接已关闭");
        return -1;
    }
    NSString *line = [command stringByAppendingString:@"\r\n"];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (![self.control sendData:data error:error]) {
        return -1;
    }
    return [self readReply:replyOut error:error];
}

- (BOOL)openAndLogin:(NSError **)error {
    self.control = [OPSocket connectToHost:self.server.host
                                      port:self.server.port
                                   timeout:20.0
                                     error:error];
    if (!self.control) {
        return NO;
    }
    [self trackSocket:self.control];

    NSInteger greeting = [self readReply:NULL error:error];
    if (greeting < 200 || greeting >= 400) {
        if (error) *error = OPFTPError([NSString stringWithFormat:@"FTP 服务未就绪 (%ld)", (long)greeting]);
        return NO;
    }

    NSString *user = self.server.username.length ? self.server.username : @"anonymous";
    NSInteger userReply = [self command:[@"USER " stringByAppendingString:user] reply:NULL error:error];
    if (userReply == 331 || userReply == 332) {
        NSString *pass = self.server.password.length ? self.server.password : @"anonymous@";
        NSInteger passReply = [self command:[@"PASS " stringByAppendingString:pass] reply:NULL error:error];
        if (passReply != 230 && passReply != 202) {
            if (error) *error = OPFTPError(@"用户名或密码错误");
            return NO;
        }
    } else if (userReply != 230) {
        if (error) *error = OPFTPError(@"登录失败");
        return NO;
    }

    [self command:@"TYPE I" reply:NULL error:error];
    return YES;
}

- (OPSocket *)openPassiveDataSocket:(NSError **)error {
    NSString *reply = nil;
    NSInteger code = [self command:@"PASV" reply:&reply error:error];
    NSInteger port = -1;
    if (code == 227) {
        NSRange open = [reply rangeOfString:@"("];
        NSRange close = [reply rangeOfString:@")"];
        if (open.location != NSNotFound && close.location != NSNotFound && close.location > open.location) {
            NSString *inside = [reply substringWithRange:NSMakeRange(open.location + 1, close.location - open.location - 1)];
            NSArray *parts = [inside componentsSeparatedByString:@","];
            if (parts.count >= 6) {
                NSInteger p1 = [parts[4] integerValue];
                NSInteger p2 = [parts[5] integerValue];
                port = p1 * 256 + p2;
            }
        }
    }
    if (port <= 0) {
        code = [self command:@"EPSV" reply:&reply error:error];
        if (code == 229) {
            NSRange open = [reply rangeOfString:@"(|||"];
            NSRange close = [reply rangeOfString:@"|)"];
            if (open.location != NSNotFound && close.location != NSNotFound && close.location > open.location + 4) {
                NSString *inside = [reply substringWithRange:NSMakeRange(open.location + 4, close.location - open.location - 4)];
                port = [inside integerValue];
            }
        }
    }
    if (port <= 0) {
        if (error) *error = OPFTPError(@"无法进入被动模式");
        return nil;
    }

    OPSocket *dataSocket = [OPSocket connectToHost:self.server.host
                                              port:port
                                           timeout:20.0
                                             error:error];
    [self trackSocket:dataSocket];
    return dataSocket;
}

- (NSData *)retrieveWithCommand:(NSString *)command error:(NSError **)error {
    OPSocket *dataSocket = [self openPassiveDataSocket:error];
    if (!dataSocket) {
        return nil;
    }

    NSInteger replyCode = [self command:command reply:NULL error:error];
    if (replyCode != 150 && replyCode != 125 && replyCode / 100 != 2) {
        [dataSocket close];
        if (error) *error = OPFTPError([NSString stringWithFormat:@"命令 %@ 被拒绝 (%ld)", command, (long)replyCode]);
        return nil;
    }

    NSMutableData *result = [NSMutableData data];
    uint8_t buffer[65536];
    while (YES) {
        NSInteger got = [dataSocket readIntoBuffer:buffer maxLength:sizeof(buffer) timeout:30.0 error:error];
        if (got == 0) break;
        if (got < 0) {
            [dataSocket close];
            return nil;
        }
        [result appendBytes:buffer length:(NSUInteger)got];
    }
    [dataSocket close];
    [self readReply:NULL error:NULL];
    return result;
}

- (void)close {
    for (OPSocket *socket in _owned) {
        [socket close];
    }
    @synchronized(_registry) {
        [_registry removeObjectsInArray:_owned];
    }
    [_owned removeAllObjects];
    self.control = nil;
}

@end

#pragma mark - Listing parser

static NSRegularExpression *OPFTPCompileRegex(NSString *pattern) {
    NSError *regexError = nil;
    return [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:&regexError];
}

static NSDate *OPFTPParseModifyDate(NSString *value) {
    if (value.length < 8) return nil;
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyyMMddHHmmss";
    });
    NSString *trimmed = value;
    if (trimmed.length > 14) trimmed = [trimmed substringToIndex:14];
    return [formatter dateFromString:trimmed];
}

static OPFileItem *OPFTPParseEntry(NSString *line, NSString *parentPath) {
    if (line.length == 0) {
        return nil;
    }

    // MLSD: "type=file;size=1234;modify=20200101120000; name"
    static NSRegularExpression *mlsdRegex = nil;
    static dispatch_once_t mlsdToken;
    dispatch_once(&mlsdToken, ^{
        mlsdRegex = OPFTPCompileRegex(@"^((?:[A-Za-z]+=[^;]*;)+)\\s?(.*)$");
    });
    NSTextCheckingResult *mlsd = [mlsdRegex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
    if (mlsd && mlsd.numberOfRanges == 3) {
        NSString *facts = [line substringWithRange:[mlsd rangeAtIndex:1]];
        NSString *name = [line substringWithRange:[mlsd rangeAtIndex:2]];
        if (name.length == 0 || [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
            return nil;
        }
        OPFileItem *item = [[OPFileItem alloc] init];
        item.name = name;
        item.remotePath = OPFTPJoinPath(parentPath, name);
        for (NSString *fact in [facts componentsSeparatedByString:@";"]) {
            NSRange equals = [fact rangeOfString:@"="];
            if (equals.location == NSNotFound) continue;
            NSString *key = [[fact substringToIndex:equals.location] lowercaseString];
            NSString *value = [fact substringFromIndex:equals.location + 1];
            if ([key isEqualToString:@"type"]) {
                item.isDirectory = [value isEqualToString:@"dir"] || [value isEqualToString:@"cdir"] ||
                                   [value isEqualToString:@"pdir"];
            } else if ([key isEqualToString:@"size"]) {
                item.fileSize = [value longLongValue];
            } else if ([key isEqualToString:@"modify"]) {
                item.modifiedDate = OPFTPParseModifyDate(value);
            }
        }
        return item;
    }

    // Unix: "-rw-r--r-- 1 user group 12345 Jan 12 12:34 name"
    static NSRegularExpression *unixRegex = nil;
    static dispatch_once_t unixToken;
    dispatch_once(&unixToken, ^{
        unixRegex = OPFTPCompileRegex(@"^([-dl])([rwxstST-]{9})\\s+\\d+\\s+\\S+\\s+\\S+\\s+(\\d+)\\s+(\\w{3})\\s+(\\d{1,2})\\s+(\\S+)\\s+(.*)$");
    });
    NSTextCheckingResult *unixMatch = [unixRegex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
    if (unixMatch && unixMatch.numberOfRanges == 8) {
        NSString *kind = [line substringWithRange:[unixMatch rangeAtIndex:1]];
        NSString *name = [line substringWithRange:[unixMatch rangeAtIndex:7]];
        if (name.length == 0 || [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
            return nil;
        }
        OPFileItem *item = [[OPFileItem alloc] init];
        NSString *baseName = [name lastPathComponent];
        item.name = baseName.length ? baseName : name;
        item.remotePath = OPFTPJoinPath(parentPath, item.name);
        item.isDirectory = [kind isEqualToString:@"d"];
        item.fileSize = [[line substringWithRange:[unixMatch rangeAtIndex:3]] longLongValue];

        NSString *month = [line substringWithRange:[unixMatch rangeAtIndex:4]];
        NSString *day = [line substringWithRange:[unixMatch rangeAtIndex:5]];
        NSString *timeOrYear = [line substringWithRange:[unixMatch rangeAtIndex:6]];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        if ([timeOrYear rangeOfString:@":"].location != NSNotFound) {
            NSInteger currentYear = [[[NSCalendar currentCalendar] components:NSYearCalendarUnit fromDate:[NSDate date]] year];
            formatter.dateFormat = @"MMM d HH:mm yyyy";
            NSString *combined = [NSString stringWithFormat:@"%@ %@ %@ %ld", month, day, timeOrYear, (long)currentYear];
            item.modifiedDate = [formatter dateFromString:combined];
        } else {
            formatter.dateFormat = @"MMM d yyyy";
            NSString *combined = [NSString stringWithFormat:@"%@ %@ %@", month, day, timeOrYear];
            item.modifiedDate = [formatter dateFromString:combined];
        }
        return item;
    }

    // DOS: "01-12-12  12:34PM       <DIR>          name"
    static NSRegularExpression *dosRegex = nil;
    static dispatch_once_t dosToken;
    dispatch_once(&dosToken, ^{
        dosRegex = OPFTPCompileRegex(@"^(\\d{2}-\\d{2}-\\d{2})\\s+(\\d{2}:\\d{2}(?:AM|PM))\\s+(<DIR>|\\d+)\\s+(.*)$");
    });
    NSTextCheckingResult *dosMatch = [dosRegex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
    if (dosMatch && dosMatch.numberOfRanges == 5) {
        NSString *name = [line substringWithRange:[dosMatch rangeAtIndex:4]];
        if (name.length == 0 || [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
            return nil;
        }
        OPFileItem *item = [[OPFileItem alloc] init];
        item.name = name;
        item.remotePath = OPFTPJoinPath(parentPath, name);
        NSString *sizeOrDir = [line substringWithRange:[dosMatch rangeAtIndex:3]];
        item.isDirectory = [sizeOrDir isEqualToString:@"<DIR>"];
        if (!item.isDirectory) {
            item.fileSize = [sizeOrDir longLongValue];
        }
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"MM-dd-yy hh:mma";
        NSString *combined = [NSString stringWithFormat:@"%@ %@",
                              [line substringWithRange:[dosMatch rangeAtIndex:1]],
                              [line substringWithRange:[dosMatch rangeAtIndex:2]]];
        item.modifiedDate = [formatter dateFromString:combined];
        return item;
    }

    return nil;
}

#pragma mark - Client

@interface OPFTPClient ()
@property (nonatomic, strong) OPServer *server;
@property (nonatomic, strong) NSMutableArray *activeSockets;
- (NSMutableArray *)parseListingData:(NSData *)data parentPath:(NSString *)parentPath;
@end

@implementation OPFTPClient

- (id)initWithServer:(OPServer *)server {
    self = [super init];
    if (self) {
        _server = server;
        _activeSockets = [NSMutableArray array];
    }
    return self;
}

- (void)runBlocking:(void (^)(void))block {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), block);
}

#pragma mark - OPFileSource

- (void)listDirectory:(NSString *)path
           completion:(void (^)(NSArray *, NSError *))completion {
    NSString *requestPath = path.length ? path : @"/";
    __weak OPFTPClient *weakSelf = self;
    [self runBlocking:^{
        OPFTPClient *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSError *error = nil;
        OPFTPConnection *connection = [[OPFTPConnection alloc] initWithServer:strongSelf.server
                                                                    registry:strongSelf.activeSockets];
        NSArray *items = nil;

        do {
            if (![connection openAndLogin:&error]) break;

            NSInteger cwdCode = [connection command:[@"CWD " stringByAppendingString:requestPath]
                                              reply:NULL error:NULL];
            if (cwdCode / 100 != 2) {
                NSString *relative = [requestPath hasPrefix:@"/"] ? [requestPath substringFromIndex:1] : requestPath;
                cwdCode = [connection command:[@"CWD " stringByAppendingString:relative]
                                        reply:NULL error:NULL];
            }
            if (cwdCode / 100 != 2) {
                error = OPFTPError(@"无法进入目录");
                break;
            }

            NSData *listing = [connection retrieveWithCommand:@"MLSD" error:NULL];
            NSMutableArray *parsed = nil;
            if (listing) {
                parsed = [strongSelf parseListingData:listing parentPath:requestPath];
            }
            if (!listing || parsed.count == 0) {
                listing = [connection retrieveWithCommand:@"LIST" error:&error];
                if (listing) {
                    parsed = [strongSelf parseListingData:listing parentPath:requestPath];
                } else {
                    error = nil;  // empty directory is not an error
                    parsed = [NSMutableArray array];
                }
            }
            items = [parsed sortedArrayUsingComparator:^NSComparisonResult(OPFileItem *a, OPFileItem *b) {
                if (a.isDirectory != b.isDirectory) {
                    return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
                }
                return [a.name caseInsensitiveCompare:b.name];
            }];
        } while (NO);

        [connection close];

        NSArray *finalItems = items;
        NSError *finalError = error;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(finalItems, finalError);
        });
    }];
}

- (NSMutableArray *)parseListingData:(NSData *)data parentPath:(NSString *)parentPath {
    NSMutableArray *parsed = [NSMutableArray array];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) {
        text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        if (line.length == 0 || [line hasPrefix:@"total "]) {
            continue;
        }
        OPFileItem *item = OPFTPParseEntry(line, parentPath);
        if (item) {
            [parsed addObject:item];
        }
    }
    return parsed;
}

- (void)downloadFile:(OPFileItem *)item
              toPath:(NSString *)localPath
            progress:(void (^)(long long, long long))progress
          completion:(void (^)(NSError *))completion {
    __weak OPFTPClient *weakSelf = self;
    [self runBlocking:^{
        OPFTPClient *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSError *error = nil;
        OPFTPConnection *connection = [[OPFTPConnection alloc] initWithServer:strongSelf.server
                                                                    registry:strongSelf.activeSockets];
        BOOL success = NO;

        do {
            if (![connection openAndLogin:&error]) break;

            long long total = 0;
            NSString *sizeReply = nil;
            NSInteger sizeCode = [connection command:[@"SIZE " stringByAppendingString:item.remotePath]
                                               reply:&sizeReply error:NULL];
            if (sizeCode == 213 && sizeReply.length > 4) {
                total = [[sizeReply substringFromIndex:4] longLongValue];
            }

            OPSocket *dataSocket = [connection openPassiveDataSocket:&error];
            if (!dataSocket) break;

            NSInteger replyCode = [connection command:[@"RETR " stringByAppendingString:item.remotePath]
                                                reply:NULL error:&error];
            if (replyCode != 150 && replyCode != 125 && replyCode / 100 != 2) {
                error = OPFTPError(@"服务器拒绝下载请求");
                break;
            }

            [[NSFileManager defaultManager] removeItemAtPath:localPath error:NULL];
            NSOutputStream *stream = [NSOutputStream outputStreamToFileAtPath:localPath append:NO];
            [stream open];

            long long received = 0;
            uint8_t buffer[65536];
            BOOL ioOK = YES;
            while (YES) {
                NSInteger got = [dataSocket readIntoBuffer:buffer maxLength:sizeof(buffer) timeout:60.0 error:&error];
                if (got == 0) break;
                if (got < 0) {
                    ioOK = NO;
                    break;
                }
                NSInteger written = 0;
                while (written < got) {
                    NSInteger n = [stream write:buffer + written maxLength:(NSUInteger)(got - written)];
                    if (n <= 0) {
                        ioOK = NO;
                        error = OPFTPError(@"写入本地文件失败");
                        break;
                    }
                    written += n;
                }
                if (!ioOK) break;
                received += got;
                if (progress) {
                    long long capturedReceived = received;
                    long long capturedTotal = total;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        progress(capturedReceived, capturedTotal);
                    });
                }
            }
            [stream close];
            [dataSocket close];
            [connection readReply:NULL error:NULL];
            success = ioOK;
        } while (NO);

        [connection close];

        NSError *finalError = success ? nil : (error ?: OPFTPError(@"下载失败"));
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(finalError);
        });
    }];
}

- (void)cancelAll {
    NSArray *sockets = nil;
    @synchronized(self.activeSockets) {
        sockets = [self.activeSockets copy];
    }
    for (OPSocket *socket in sockets) {
        [socket close];
    }
}

@end
