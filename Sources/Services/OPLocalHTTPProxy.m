#import "OPLocalHTTPProxy.h"
#import "OPSocket.h"
#import "OPSeekableStream.h"
#import "OPFTPSeekStream.h"
#import "OPSMBSeekStream.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

static NSString *const OPProxyErrorDomain = @"OPProxy";

static NSString *OPProxyContentType(NSString *name) {
    static NSDictionary *map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"mp4": @"video/mp4",
            @"m4v": @"video/x-m4v",
            @"mov": @"video/quicktime",
            @"3gp": @"video/3gpp",
            @"3g2": @"video/3gpp2",
            @"mp3": @"audio/mpeg",
            @"m4a": @"audio/mp4",
            @"m4b": @"audio/mp4",
            @"aac": @"audio/aac",
            @"wav": @"audio/wav",
            @"aif": @"audio/aiff",
            @"aiff": @"audio/aiff",
            @"caf": @"audio/x-caf",
        };
    });
    NSString *type = [map objectForKey:[[name pathExtension] lowercaseString]];
    return type ?: @"application/octet-stream";
}

static BOOL OPProxyIsDigits(NSString *string) {
    if (string.length == 0) {
        return NO;
    }
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return [string rangeOfCharacterFromSet:nonDigits].location == NSNotFound;
}

@interface OPLocalHTTPProxy ()
@property (nonatomic, assign) int listenFD;
@property (nonatomic, assign) int listenPort;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, strong) NSMutableDictionary *tickets;
@property (nonatomic, strong) NSMutableArray *activeClients;
@end

@implementation OPLocalHTTPProxy

+ (instancetype)sharedProxy {
    static OPLocalHTTPProxy *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[OPLocalHTTPProxy alloc] init];
    });
    return shared;
}

- (id)init {
    self = [super init];
    if (self) {
        _listenFD = -1;
        _tickets = [NSMutableDictionary dictionary];
        _activeClients = [NSMutableArray array];
    }
    return self;
}

- (BOOL)start:(NSError **)error {
    @synchronized(self) {
        if (self.running) {
            return YES;
        }
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) {
            if (error) {
                *error = [NSError errorWithDomain:OPProxyErrorDomain code:-1 userInfo:
                          @{NSLocalizedDescriptionKey : @"无法创建本地套接字"}];
            }
            return NO;
        }
        int yes = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = 0;  // ephemeral port
        if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
            listen(fd, 5) != 0) {
            close(fd);
            if (error) {
                *error = [NSError errorWithDomain:OPProxyErrorDomain code:-1 userInfo:
                          @{NSLocalizedDescriptionKey : @"本地代理端口绑定失败"}];
            }
            return NO;
        }
        socklen_t addrLength = sizeof(addr);
        if (getsockname(fd, (struct sockaddr *)&addr, &addrLength) != 0) {
            close(fd);
            return NO;
        }
        self.listenFD = fd;
        self.listenPort = ntohs(addr.sin_port);
        self.running = YES;

        __weak OPLocalHTTPProxy *weakSelf = self;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [weakSelf acceptLoop];
        });
        return YES;
    }
}

- (void)stop {
    NSArray *clients = nil;
    @synchronized(self) {
        self.running = NO;
        if (self.listenFD >= 0) {
            close(self.listenFD);
            self.listenFD = -1;
        }
        clients = [self.activeClients copy];
    }
    for (OPSocket *client in clients) {
        [client close];
    }
}

- (NSURL *)proxyURLForServer:(OPServer *)server item:(OPFileItem *)item {
    if (server.protocolType != OPProtocolTypeFTP && server.protocolType != OPProtocolTypeSMB) {
        return nil;
    }
    if (![self start:NULL]) {
        return nil;
    }
    NSString *token = [[NSUUID UUID] UUIDString];
    NSDictionary *ticket = @{
        @"server": server,
        @"remotePath": item.remotePath ?: @"/",
        @"name": item.name ?: @"file",
    };
    @synchronized(self) {
        if (self.tickets.count > 32) {
            [self.tickets removeAllObjects];
        }
        [self.tickets setObject:ticket forKey:token];
    }
    NSString *string = [NSString stringWithFormat:@"http://127.0.0.1:%d/%@", self.listenPort, token];
    return [NSURL URLWithString:string];
}

#pragma mark - Accept loop

- (void)acceptLoop {
    while (YES) {
        @synchronized(self) {
            if (!self.running || self.listenFD < 0) {
                return;
            }
        }
        int fd = accept(self.listenFD, NULL, NULL);
        if (fd < 0) {
            @synchronized(self) {
                if (!self.running) {
                    return;
                }
            }
            continue;
        }
        OPSocket *client = [[OPSocket alloc] initWithFileDescriptor:fd];
        @synchronized(self) {
            [self.activeClients addObject:client];
        }
        __weak OPLocalHTTPProxy *weakSelf = self;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            OPLocalHTTPProxy *strongSelf = weakSelf;
            [strongSelf handleConnection:client];
            @synchronized(strongSelf) {
                [strongSelf.activeClients removeObject:client];
            }
            [client close];
        });
    }
}

#pragma mark - Request handling

- (void)sendString:(NSString *)string toClient:(OPSocket *)client {
    NSData *data = [string dataUsingEncoding:NSASCIIStringEncoding];
    [client sendData:data error:NULL];
}

- (void)sendError:(NSInteger)code message:(NSString *)message toClient:(OPSocket *)client {
    [self sendString:[NSString stringWithFormat:
                      @"HTTP/1.1 %ld %@\r\nConnection: close\r\nContent-Length: 0\r\n\r\n",
                      (long)code, message]
            toClient:client];
}

- (void)handleConnection:(OPSocket *)client {
    NSError *error = nil;

    // Request line.
    NSData *lineData = [client readLineWithTimeout:30.0 error:&error];
    if (!lineData) {
        return;
    }
    NSString *requestLine = [[NSString alloc] initWithData:lineData encoding:NSASCIIStringEncoding];
    NSArray *requestParts = [[requestLine stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]]
                             componentsSeparatedByString:@" "];
    if (requestParts.count < 2) {
        [self sendError:400 message:@"Bad Request" toClient:client];
        return;
    }
    NSString *method = [requestParts objectAtIndex:0];
    NSString *rawPath = [requestParts objectAtIndex:1];
    BOOL isHead = [method caseInsensitiveCompare:@"HEAD"] == NSOrderedSame;
    if ([method caseInsensitiveCompare:@"GET"] != NSOrderedSame && !isHead) {
        [self sendError:405 message:@"Method Not Allowed" toClient:client];
        return;
    }

    // Headers (only Range matters here).
    NSString *rangeHeader = nil;
    for (int i = 0; i < 64; i++) {
        NSData *headerData = [client readLineWithTimeout:30.0 error:&error];
        if (!headerData) {
            return;
        }
        NSString *header = [[NSString alloc] initWithData:headerData encoding:NSASCIIStringEncoding];
        NSString *trimmed = [header stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) {
            break;
        }
        if ([trimmed rangeOfString:@"Range:" options:NSCaseInsensitiveSearch | NSAnchoredSearch].location != NSNotFound) {
            NSRange colon = [trimmed rangeOfString:@":"];
            if (colon.location != NSNotFound) {
                rangeHeader = [[trimmed substringFromIndex:colon.location + 1]
                               stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            }
        }
    }

    // Token lookup.
    NSString *token = rawPath;
    if ([token hasPrefix:@"/"]) {
        token = [token substringFromIndex:1];
    }
    NSRange query = [token rangeOfString:@"?"];
    if (query.location != NSNotFound) {
        token = [token substringToIndex:query.location];
    }
    NSDictionary *ticket = nil;
    @synchronized(self) {
        ticket = [self.tickets objectForKey:token];
    }
    if (!ticket) {
        [self sendError:404 message:@"Not Found" toClient:client];
        return;
    }

    OPServer *server = [ticket objectForKey:@"server"];
    id<OPSeekableStream> stream = [self streamForServer:server
                                            remotePath:[ticket objectForKey:@"remotePath"]];
    if (!stream) {
        [self sendError:500 message:@"Unsupported Protocol" toClient:client];
        return;
    }
    if (![stream open:&error]) {
        [stream close];
        [self sendError:502 message:@"Bad Gateway" toClient:client];
        return;
    }

    long long total = [stream contentLength];
    NSString *contentType = OPProxyContentType([ticket objectForKey:@"name"] ?: @"");

    long long start = 0;
    long long end = total >= 0 ? total - 1 : -1;
    BOOL useRange = NO;
    if (rangeHeader && total >= 0) {
        long long parsedStart = 0;
        long long parsedEnd = -1;
        if ([self parseRange:rangeHeader total:total start:&parsedStart end:&parsedEnd]) {
            if (parsedStart >= total) {
                [self sendString:[NSString stringWithFormat:
                                  @"HTTP/1.1 416 Requested Range Not Satisfiable\r\n"
                                  @"Content-Range: bytes */%lld\r\n"
                                  @"Connection: close\r\nContent-Length: 0\r\n\r\n", total]
                        toClient:client];
                [stream close];
                return;
            }
            start = parsedStart;
            end = parsedEnd;
            useRange = YES;
        }
    }

    if (useRange && start > 0) {
        if (![stream seekToOffset:start error:NULL]) {
            [self sendError:500 message:@"Seek Failed" toClient:client];
            [stream close];
            return;
        }
    }

    if (useRange) {
        [self sendString:[NSString stringWithFormat:
                          @"HTTP/1.1 206 Partial Content\r\n"
                          @"Content-Type: %@\r\n"
                          @"Content-Length: %lld\r\n"
                          @"Content-Range: bytes %lld-%lld/%lld\r\n"
                          @"Accept-Ranges: bytes\r\n"
                          @"Connection: close\r\n\r\n",
                          contentType, end - start + 1, start, end, total]
                toClient:client];
    } else if (total >= 0) {
        [self sendString:[NSString stringWithFormat:
                          @"HTTP/1.1 200 OK\r\n"
                          @"Content-Type: %@\r\n"
                          @"Content-Length: %lld\r\n"
                          @"Accept-Ranges: bytes\r\n"
                          @"Connection: close\r\n\r\n",
                          contentType, total]
                toClient:client];
    } else {
        [self sendString:[NSString stringWithFormat:
                          @"HTTP/1.1 200 OK\r\n"
                          @"Content-Type: %@\r\n"
                          @"Connection: close\r\n\r\n", contentType]
                toClient:client];
    }

    if (!isHead) {
        long long remaining = useRange ? (end - start + 1) : total;
        uint8_t buffer[32768];
        while (remaining < 0 || remaining > 0) {
            NSUInteger want = sizeof(buffer);
            if (remaining >= 0 && remaining < (long long)want) {
                want = (NSUInteger)remaining;
            }
            NSInteger got = [stream read:buffer maxLength:want error:NULL];
            if (got <= 0) {
                break;
            }
            NSData *chunk = [NSData dataWithBytes:buffer length:(NSUInteger)got];
            if (![client sendData:chunk error:NULL]) {
                break;  // player went away (usually a seek); normal
            }
            if (remaining > 0) {
                remaining -= got;
            }
        }
    }

    [stream close];
}

// Parses "bytes=S-E" / "bytes=S-". Only single ranges are supported.
- (BOOL)parseRange:(NSString *)header
             total:(long long)total
             start:(long long *)startOut
               end:(long long *)endOut {
    NSRange equals = [header rangeOfString:@"="];
    if (equals.location == NSNotFound) {
        return NO;
    }
    NSString *spec = [[header substringFromIndex:equals.location + 1]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([spec rangeOfString:@","].location != NSNotFound) {
        return NO;
    }
    NSString *unit = [[header substringToIndex:equals.location]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([unit caseInsensitiveCompare:@"bytes"] != NSOrderedSame) {
        return NO;
    }
    NSRange dash = [spec rangeOfString:@"-"];
    if (dash.location == NSNotFound) {
        return NO;
    }
    NSString *startString = [spec substringToIndex:dash.location];
    NSString *endString = [spec substringFromIndex:dash.location + 1];
    if (!OPProxyIsDigits(startString)) {
        return NO;  // suffix ranges ("-N") are not supported
    }
    long long start = [startString longLongValue];
    long long end = total - 1;
    if (endString.length > 0) {
        if (!OPProxyIsDigits(endString)) {
            return NO;
        }
        end = [endString longLongValue];
        if (end >= total) {
            end = total - 1;
        }
    }
    if (start > end || total <= 0) {
        return NO;
    }
    if (startOut) *startOut = start;
    if (endOut) *endOut = end;
    return YES;
}

- (id<OPSeekableStream>)streamForServer:(OPServer *)server remotePath:(NSString *)remotePath {
    if (server.protocolType == OPProtocolTypeFTP) {
        return [[OPFTPSeekStream alloc] initWithServer:server remotePath:remotePath];
    }
    if (server.protocolType == OPProtocolTypeSMB) {
        return [[OPSMBSeekStream alloc] initWithServer:server remotePath:remotePath];
    }
    return nil;
}

@end
