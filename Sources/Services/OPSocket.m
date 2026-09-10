#import "OPSocket.h"

#include <sys/socket.h>
#include <sys/select.h>
#include <sys/time.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>

static NSString *const OPSocketErrorDomain = @"OPSocket";

static NSError *OPSocketError(NSString *message) {
    return [NSError errorWithDomain:OPSocketErrorDomain
                               code:-1
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

@interface OPSocket ()
@property (nonatomic, assign) int fd;
- (BOOL)connectToHost:(NSString *)host
                 port:(NSInteger)port
              timeout:(NSTimeInterval)timeout
                error:(NSError **)error;
@end

@implementation OPSocket

- (id)init {
    self = [super init];
    if (self) {
        _fd = -1;
    }
    return self;
}

- (void)dealloc {
    [self close];
}

+ (instancetype)connectToHost:(NSString *)host
                         port:(NSInteger)port
                      timeout:(NSTimeInterval)timeout
                        error:(NSError **)error {
    OPSocket *socket = [[OPSocket alloc] init];
    if (![socket connectToHost:host port:port timeout:timeout error:error]) {
        return nil;
    }
    return socket;
}

- (BOOL)connectToHost:(NSString *)host
                 port:(NSInteger)port
              timeout:(NSTimeInterval)timeout
                error:(NSError **)error {
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    char portString[16];
    snprintf(portString, sizeof(portString), "%ld", (long)port);

    struct addrinfo *results = NULL;
    int gai = getaddrinfo([host UTF8String], portString, &hints, &results);
    if (gai != 0 || results == NULL) {
        if (error) *error = OPSocketError([NSString stringWithFormat:@"无法解析主机 %@", host]);
        return NO;
    }

    int connectedFD = -1;
    NSString *lastError = @"连接失败";
    for (struct addrinfo *addr = results; addr != NULL; addr = addr->ai_next) {
        int fd = socket(addr->ai_family, addr->ai_socktype, addr->ai_protocol);
        if (fd < 0) {
            continue;
        }
        // Non-blocking connect so we can bound it with select().
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);

        int result = connect(fd, addr->ai_addr, addr->ai_addrlen);
        if (result == 0) {
            connectedFD = fd;
        } else if (errno == EINPROGRESS) {
            fd_set writeSet;
            FD_ZERO(&writeSet);
            FD_SET(fd, &writeSet);
            struct timeval tv;
            tv.tv_sec = (time_t)timeout;
            tv.tv_usec = (suseconds_t)((timeout - (time_t)timeout) * 1000000);
            int selected = select(fd + 1, NULL, &writeSet, NULL, &tv);
            if (selected > 0) {
                int soError = 0;
                socklen_t len = sizeof(soError);
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len);
                if (soError == 0) {
                    connectedFD = fd;
                } else {
                    lastError = [NSString stringWithFormat:@"连接被拒绝 (%d)", soError];
                }
            } else {
                lastError = @"连接超时";
            }
        }
        if (connectedFD >= 0) {
            // Back to blocking with socket-level timeouts.
            fcntl(fd, F_SETFL, flags);
            break;
        }
        close(fd);
    }
    freeaddrinfo(results);

    if (connectedFD < 0) {
        if (error) *error = OPSocketError(lastError);
        return NO;
    }

    // Normalise the receive/send timeouts so backends do not hang.
    NSTimeInterval effective = timeout > 0 ? timeout : 30.0;
    struct timeval ioTimeout;
    ioTimeout.tv_sec = (time_t)effective;
    ioTimeout.tv_usec = (suseconds_t)((effective - (time_t)effective) * 1000000);
    setsockopt(connectedFD, SOL_SOCKET, SO_RCVTIMEO, &ioTimeout, sizeof(ioTimeout));
    setsockopt(connectedFD, SOL_SOCKET, SO_SNDTIMEO, &ioTimeout, sizeof(ioTimeout));
    int yes = 1;
    setsockopt(connectedFD, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));

    self.fd = connectedFD;
    return YES;
}

- (BOOL)isConnected {
    return self.fd >= 0;
}

- (void)close {
    if (self.fd >= 0) {
        close(self.fd);
        self.fd = -1;
    }
}

- (BOOL)sendData:(NSData *)data error:(NSError **)error {
    if (self.fd < 0) {
        if (error) *error = OPSocketError(@"套接字已关闭");
        return NO;
    }
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        ssize_t written = send(self.fd, bytes, remaining, 0);
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (error) *error = OPSocketError([NSString stringWithFormat:@"发送失败 (%d)", errno]);
            return NO;
        }
        bytes += written;
        remaining -= (NSUInteger)written;
    }
    return YES;
}

- (NSData *)readLineWithTimeout:(NSTimeInterval)timeout error:(NSError **)error {
    NSMutableData *line = [NSMutableData data];
    uint8_t byte = 0;
    while (YES) {
        NSInteger got = [self readIntoBuffer:&byte maxLength:1 timeout:timeout error:error];
        if (got <= 0) {
            if (got == 0 && line.length > 0) {
                return line;  // EOF after partial line
            }
            return got == 0 ? nil : nil;
        }
        [line appendBytes:&byte length:1];
        if (byte == '\n') {
            return line;
        }
        if (line.length > 65536) {
            return line;
        }
    }
}

- (NSInteger)readIntoBuffer:(uint8_t *)buffer
                  maxLength:(NSUInteger)maxLength
                    timeout:(NSTimeInterval)timeout
                      error:(NSError **)error {
    if (self.fd < 0) {
        if (error) *error = OPSocketError(@"套接字已关闭");
        return -1;
    }
    while (YES) {
        ssize_t got = recv(self.fd, buffer, maxLength, 0);
        if (got > 0) {
            return (NSInteger)got;
        }
        if (got == 0) {
            return 0;  // clean EOF
        }
        if (errno == EINTR) {
            continue;
        }
        if (error) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                *error = OPSocketError(@"读取超时");
            } else {
                *error = OPSocketError([NSString stringWithFormat:@"读取失败 (%d)", errno]);
            }
        }
        return -1;
    }
}

@end
