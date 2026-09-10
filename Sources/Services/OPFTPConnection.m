#import "OPFTPConnection.h"
#import "OPSocket.h"

static NSString *const OPFTPErrorDomain = @"OPFTP";

NSError *OPFTPError(NSString *message) {
    return [NSError errorWithDomain:OPFTPErrorDomain
                               code:-1
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

static NSInteger OPFTPReplyCode(NSString *line) {
    if (line.length < 3) {
        return -1;
    }
    return [[line substringToIndex:3] integerValue];
}

static BOOL OPFTPReplyIsMultiline(NSString *line) {
    return line.length >= 4 && [line characterAtIndex:3] == '-';
}

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
