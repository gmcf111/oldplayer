#import "OPFTPClient.h"
#import "OPFTPConnection.h"
#import "OPSocket.h"

#pragma mark - Path helper

static NSString *OPFTPJoinPath(NSString *parent, NSString *name) {
    if ([parent isEqualToString:@"/"] || parent.length == 0) {
        return [@"/" stringByAppendingString:name];
    }
    return [NSString stringWithFormat:@"%@/%@", parent, name];
}

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
