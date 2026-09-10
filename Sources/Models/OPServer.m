#import "OPServer.h"

@implementation OPServer

+ (instancetype)serverWithDictionary:(NSDictionary *)dictionary {
    OPServer *server = [[OPServer alloc] init];
    server.identifier = dictionary[@"identifier"];
    server.displayName = dictionary[@"displayName"];
    server.protocolType = [dictionary[@"protocolType"] integerValue];
    server.host = dictionary[@"host"];
    server.port = [dictionary[@"port"] integerValue];
    server.username = dictionary[@"username"];
    server.password = dictionary[@"password"];
    server.remotePath = dictionary[@"remotePath"];
    server.secure = [dictionary[@"secure"] boolValue];
    if (server.identifier.length == 0) {
        server.identifier = [[NSUUID UUID] UUIDString];
    }
    if (server.remotePath.length == 0) {
        server.remotePath = @"/";
    }
    if (server.port <= 0) {
        server.port = [server defaultPort];
    }
    return server;
}

- (id)init {
    self = [super init];
    if (self) {
        _identifier = [[NSUUID UUID] UUIDString];
        _remotePath = @"/";
        _protocolType = OPProtocolTypeWebDAV;
        _port = 0;
    }
    return self;
}

- (NSDictionary *)dictionaryRepresentation {
    return @{
        @"identifier"   : self.identifier ?: @"",
        @"displayName"  : self.displayName ?: @"",
        @"protocolType" : @(self.protocolType),
        @"host"         : self.host ?: @"",
        @"port"         : @(self.port),
        @"username"     : self.username ?: @"",
        @"password"     : self.password ?: @"",
        @"remotePath"   : self.remotePath ?: @"/",
        @"secure"       : @(self.secure),
    };
}

- (NSString *)protocolDisplayName {
    switch (self.protocolType) {
        case OPProtocolTypeFTP:    return @"FTP";
        case OPProtocolTypeSMB:    return @"SMB";
        case OPProtocolTypeWebDAV:
        default:                   return self.secure ? @"WebDAV (HTTPS)" : @"WebDAV";
    }
}

- (NSString *)defaultPath {
    return @"/";
}

- (NSInteger)defaultPort {
    switch (self.protocolType) {
        case OPProtocolTypeFTP: return 21;
        case OPProtocolTypeSMB: return 445;
        case OPProtocolTypeWebDAV:
        default:                return self.secure ? 443 : 80;
    }
}

- (NSString *)endpointDescription {
    NSString *scheme = @"webdav";
    if (self.protocolType == OPProtocolTypeFTP) scheme = @"ftp";
    else if (self.protocolType == OPProtocolTypeSMB) scheme = @"smb";
    else if (self.secure) scheme = @"https";
    return [NSString stringWithFormat:@"%@://%@:%ld", scheme, self.host ?: @"", (long)self.port];
}

@end
