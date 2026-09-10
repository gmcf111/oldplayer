#import "OPSMBSession.h"
#import "OPSocket.h"
#import "OPBytes.h"
#import "OPNTLM.h"

#include <string.h>
#include <stdlib.h>

// SMB2 commands.
static const uint16_t SMB2_NEGOTIATE = 0x0000;
static const uint16_t SMB2_SESSION_SETUP = 0x0001;
static const uint16_t SMB2_TREE_CONNECT = 0x0003;
static const uint16_t SMB2_CREATE = 0x0005;
static const uint16_t SMB2_CLOSE = 0x0006;
static const uint16_t SMB2_READ = 0x0008;
static const uint16_t SMB2_QUERY_DIRECTORY = 0x000E;

// SMB2 status codes.
static const uint32_t STATUS_SUCCESS = 0x00000000;
static const uint32_t STATUS_MORE_PROCESSING_REQUIRED = 0xC0000016;
static const uint32_t STATUS_NO_MORE_FILES = 0x80000006;
static const uint32_t STATUS_ACCESS_DENIED = 0xC0000022;
static const uint32_t STATUS_LOGON_FAILURE = 0xC000006D;
static const uint32_t STATUS_BAD_NETWORK_NAME = 0xC00000CC;
static const uint32_t STATUS_OBJECT_NAME_NOT_FOUND = 0xC0000034;
static const uint32_t STATUS_OBJECT_PATH_NOT_FOUND = 0xC000003A;
static const uint32_t STATUS_NOT_SUPPORTED = 0xC00000BB;

// CreateOptions / DesiredAccess.
static const uint32_t FILE_DIRECTORY_FILE = 0x00000001;
static const uint32_t FILE_NON_DIRECTORY_FILE = 0x00000040;
static const uint32_t FILE_LIST_DIRECTORY = 0x00000001;
static const uint32_t FILE_READ_DATA = 0x00000001;
static const uint32_t FILE_SHARE_ALL = 0x00000007;
static const uint32_t FILE_OPEN = 0x00000001;

static NSString *const OPSMBErrorDomain = @"OPSMB";

static NSError *OPSMBError(NSString *message) {
    return [NSError errorWithDomain:OPSMBErrorDomain
                               code:-1
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

static NSError *OPSMBErrorForStatus(uint32_t status) {
    NSString *message = nil;
    switch (status) {
        case STATUS_ACCESS_DENIED: message = @"访问被拒绝（用户名/密码或权限错误）"; break;
        case STATUS_LOGON_FAILURE: message = @"登录失败（用户名或密码错误）"; break;
        case STATUS_BAD_NETWORK_NAME: message = @"找不到共享名"; break;
        case STATUS_OBJECT_NAME_NOT_FOUND: message = @"找不到文件或目录"; break;
        case STATUS_OBJECT_PATH_NOT_FOUND: message = @"路径不存在"; break;
        case STATUS_NOT_SUPPORTED: message = @"服务器不支持该操作"; break;
        default:
            message = [NSString stringWithFormat:@"SMB 错误 0x%08X", status];
            break;
    }
    return OPSMBError(message);
}

static NSString *OPSMBSharePathToUNC(NSString *host, NSString *share) {
    return [NSString stringWithFormat:@"\\\\%@\\%@", host, share];
}

static NSData *OPSMBUTF16(NSString *string) {
    if (string.length == 0) {
        return [NSData data];
    }
    NSData *data = [string dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    return data ?: [NSData data];
}

static NSString *OPSMBDecodeUTF16(NSData *data) {
    if (data.length < 2) {
        return @"";
    }
    NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF16LittleEndianStringEncoding];
    return string ?: @"";
}

static NSDate *OPSMBDateFromFiletime(uint64_t filetime) {
    if (filetime == 0) {
        return nil;
    }
    double seconds = (double)filetime / 10000000.0 - 11644473600.0;
    return [NSDate dateWithTimeIntervalSince1970:seconds];
}

@interface OPSMBSession ()
@property (nonatomic, copy) NSString *host;
@property (nonatomic, assign) NSInteger port;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *password;
@property (nonatomic, strong) OPSocket *socket;
@property (nonatomic, assign) uint64_t messageId;
@property (nonatomic, assign) uint64_t sessionId;
@property (nonatomic, assign) uint32_t treeId;
@end

@implementation OPSMBSession

- (id)initWithHost:(NSString *)host
              port:(NSInteger)port
           username:(NSString *)username
           password:(NSString *)password {
    self = [super init];
    if (self) {
        _host = [host copy];
        _port = port;
        _username = [username copy];
        _password = [password copy];
    }
    return self;
}

#pragma mark - Low level transport

- (NSData *)transact:(uint16_t)command
                body:(NSData *)body
              status:(uint32_t *)statusOut
               error:(NSError **)error {
    NSMutableData *message = [NSMutableData dataWithCapacity:64 + body.length];
    uint8_t header[64];
    memset(header, 0, sizeof(header));
    header[0] = 0xFE;
    header[1] = 'S';
    header[2] = 'M';
    header[3] = 'B';
    OPWriteLE16(header + 4, 64);          // StructureSize
    OPWriteLE16(header + 6, 1);           // CreditCharge
    OPWriteLE32(header + 8, 0);           // Status
    OPWriteLE16(header + 12, command);
    OPWriteLE16(header + 14, 64);         // CreditRequest
    OPWriteLE32(header + 16, 0);          // Flags
    OPWriteLE32(header + 20, 0);          // NextCommand
    OPWriteLE64(header + 24, self.messageId);
    OPWriteLE32(header + 32, 0);          // ProcessId
    OPWriteLE32(header + 36, self.treeId);
    OPWriteLE64(header + 40, self.sessionId);
    [message appendBytes:header length:64];
    [message appendData:body];
    self.messageId++;

    NSMutableData *frame = [NSMutableData dataWithCapacity:4 + message.length];
    uint32_t length = (uint32_t)message.length;
    uint8_t netbios[4];
    netbios[0] = 0x00;
    netbios[1] = (uint8_t)((length >> 16) & 0xFF);
    netbios[2] = (uint8_t)((length >> 8) & 0xFF);
    netbios[3] = (uint8_t)(length & 0xFF);
    [frame appendBytes:netbios length:4];
    [frame appendData:message];

    if (![self.socket sendData:frame error:error]) {
        return nil;
    }

    NSData *lengthData = [self.socket readDataOfLength:4 timeout:30.0 error:error];
    if (!lengthData) {
        if (error) *error = OPSMBError(@"读取响应长度失败");
        return nil;
    }
    const uint8_t *lengthBytes = lengthData.bytes;
    uint32_t responseLength = OPReadBE24(lengthBytes + 1);
    if (responseLength < 64) {
        if (error) *error = OPSMBError(@"响应过短");
        return nil;
    }

    NSData *response = [self.socket readDataOfLength:responseLength timeout:30.0 error:error];
    if (!response) {
        if (error) *error = OPSMBError(@"读取响应失败");
        return nil;
    }
    const uint8_t *bytes = response.bytes;
    if (response.length < 64 || bytes[0] != 0xFE || bytes[1] != 'S' ||
        bytes[2] != 'M' || bytes[3] != 'B') {
        if (error) *error = OPSMBError(@"无效的 SMB2 响应");
        return nil;
    }

    uint32_t status = OPReadLE32(bytes + 8);
    uint32_t responseTreeId = OPReadLE32(bytes + 36);
    uint64_t responseSessionId = OPReadLE64(bytes + 40);
    if (command == SMB2_SESSION_SETUP && responseSessionId != 0) {
        self.sessionId = responseSessionId;
    }
    if (command == SMB2_TREE_CONNECT && responseTreeId != 0) {
        self.treeId = responseTreeId;
    }
    if (statusOut) {
        *statusOut = status;
    }
    return [response subdataWithRange:NSMakeRange(64, response.length - 64)];
}

#pragma mark - Session establishment

- (BOOL)connect:(NSError **)error {
    self.socket = [OPSocket connectToHost:self.host port:self.port timeout:15.0 error:error];
    if (!self.socket) {
        return NO;
    }
    self.messageId = 0;
    self.sessionId = 0;
    self.treeId = 0;

    // NEGOTIATE
    NSMutableData *negotiate = [NSMutableData data];
    OPAppendLE16(negotiate, 36);   // StructureSize
    OPAppendLE16(negotiate, 2);    // DialectCount
    OPAppendLE16(negotiate, 0);    // SecurityMode (signing disabled)
    OPAppendLE16(negotiate, 0);    // Reserved
    OPAppendLE32(negotiate, 0);    // Capabilities
    uint8_t guid[16];
    for (int i = 0; i < 16; i++) {
        guid[i] = (uint8_t)(arc4random() & 0xFF);
    }
    [negotiate appendBytes:guid length:16];
    OPAppendLE32(negotiate, 0);    // NegotiateContextOffset
    OPAppendLE16(negotiate, 0);    // NegotiateContextCount
    OPAppendLE16(negotiate, 0);    // Reserved2
    OPAppendLE16(negotiate, 0x0202);
    OPAppendLE16(negotiate, 0x0210);

    uint32_t status = 0;
    NSData *response = [self transact:SMB2_NEGOTIATE body:negotiate status:&status error:error];
    if (!response) {
        return NO;
    }
    if (status != STATUS_SUCCESS) {
        if (error) *error = OPSMBErrorForStatus(status);
        return NO;
    }
    if (response.length < 8) {
        if (error) *error = OPSMBError(@"协商响应无效");
        return NO;
    }
    uint32_t dialect = OPReadLE16((const uint8_t *)response.bytes + 4);
    if (dialect != 0x0202 && dialect != 0x0210) {
        if (error) {
            *error = OPSMBError([NSString stringWithFormat:
                @"服务器选择了不支持的 SMB 方言 0x%04X（需要 SMB 2.0.2/2.1）", dialect]);
        }
        return NO;
    }

    return [self performSessionSetup:error];
}

- (BOOL)performSessionSetup:(NSError **)error {
    // Step 1: send the NTLMSSP NEGOTIATE.
    NSData *negotiateToken = [OPNTLM negotiateMessage];
    uint32_t status = 0;
    NSData *response = [self sessionSetupWithToken:negotiateToken status:&status error:error];
    if (!response) {
        return NO;
    }

    if (status == STATUS_SUCCESS) {
        return YES;  // anonymous / guest accepted immediately
    }
    if (status != STATUS_MORE_PROCESSING_REQUIRED) {
        if (error) *error = OPSMBErrorForStatus(status);
        return NO;
    }
    if (response.length < 8) {
        if (error) *error = OPSMBError(@"会话建立响应无效");
        return NO;
    }

    // Security buffer is relative to the SMB2 header (already stripped).
    uint16_t bufferOffset = OPReadLE16((const uint8_t *)response.bytes + 4);
    uint16_t bufferLength = OPReadLE16((const uint8_t *)response.bytes + 6);
    NSInteger localOffset = (NSInteger)bufferOffset - 64;
    if (localOffset < 0 || localOffset + bufferLength > (NSInteger)response.length) {
        if (error) *error = OPSMBError(@"挑战响应越界");
        return NO;
    }
    NSData *challengeToken = [response subdataWithRange:NSMakeRange(localOffset, bufferLength)];

    NSData *serverChallenge = nil;
    NSString *targetName = nil;
    NSData *targetInfo = nil;
    if (![OPNTLM parseChallenge:challengeToken
                serverChallenge:&serverChallenge
                     targetName:&targetName
                     targetInfo:&targetInfo]) {
        if (error) *error = OPSMBError(@"无法解析 NTLM 挑战");
        return NO;
    }

    // Split DOMAIN\user or user@domain.
    NSString *user = self.username.length ? self.username : @"guest";
    NSString *domain = targetName ?: @"";
    NSRange backslash = [user rangeOfString:@"\\"];
    if (backslash.location != NSNotFound) {
        domain = [user substringToIndex:backslash.location];
        user = [user substringFromIndex:backslash.location + 1];
    } else {
        NSRange at = [user rangeOfString:@"@" options:NSBackwardsSearch];
        if (at.location != NSNotFound) {
            domain = [user substringFromIndex:at.location + 1];
            user = [user substringToIndex:at.location];
        }
    }

    NSData *authToken = [OPNTLM authenticateMessageForUser:user
                                                  password:self.password ?: @""
                                                    domain:domain
                                           serverChallenge:serverChallenge
                                                targetInfo:targetInfo
                                              sessionKeyOut:NULL];
    status = 0;
    response = [self sessionSetupWithToken:authToken status:&status error:error];
    if (!response) {
        return NO;
    }
    if (status != STATUS_SUCCESS) {
        if (error) *error = OPSMBErrorForStatus(status);
        return NO;
    }
    return YES;
}

- (NSData *)sessionSetupWithToken:(NSData *)token
                           status:(uint32_t *)statusOut
                            error:(NSError **)error {
    NSMutableData *body = [NSMutableData data];
    OPAppendLE16(body, 25);         // StructureSize
    uint8_t flags = 0;
    uint8_t securityMode = 0;
    [body appendBytes:&flags length:1];
    [body appendBytes:&securityMode length:1];
    OPAppendLE32(body, 0);          // Capabilities
    OPAppendLE32(body, 0);          // Channel
    OPAppendLE16(body, 88);         // SecurityBufferOffset (64 + 24)
    OPAppendLE16(body, (uint16_t)token.length);
    OPAppendLE64(body, 0);          // PreviousSessionId
    [body appendData:token];
    return [self transact:SMB2_SESSION_SETUP body:body status:statusOut error:error];
}

- (BOOL)treeConnectToShare:(NSString *)share error:(NSError **)error {
    NSString *unc = OPSMBSharePathToUNC(self.host, share);
    NSData *pathData = OPSMBUTF16(unc);

    NSMutableData *body = [NSMutableData data];
    OPAppendLE16(body, 9);          // StructureSize
    OPAppendLE16(body, 0);          // Reserved
    OPAppendLE16(body, 72);         // PathOffset (64 + 8)
    OPAppendLE16(body, (uint16_t)pathData.length);
    [body appendData:pathData];

    uint32_t status = 0;
    NSData *response = [self transact:SMB2_TREE_CONNECT body:body status:&status error:error];
    if (!response) {
        return NO;
    }
    if (status != STATUS_SUCCESS) {
        if (error) *error = OPSMBErrorForStatus(status);
        return NO;
    }
    return self.treeId != 0;
}

- (void)disconnect {
    [self.socket close];
    self.socket = nil;
}

#pragma mark - File operations

- (NSData *)createPath:(NSString *)path
           isDirectory:(BOOL)isDirectory
             fileSize:(uint64_t *)fileSizeOut
                 error:(NSError **)error {
    NSData *nameData = OPSMBUTF16(path ?: @"");
    NSMutableData *body = [NSMutableData data];
    OPAppendLE16(body, 57);         // StructureSize
    uint8_t securityFlags = 0;
    uint8_t oplock = 0;
    [body appendBytes:&securityFlags length:1];
    [body appendBytes:&oplock length:1];
    OPAppendLE32(body, 2);          // ImpersonationLevel = Impersonation
    OPAppendLE64(body, 0);          // SmbCreateFlags
    OPAppendLE64(body, 0);          // Reserved
    OPAppendLE32(body, isDirectory ? FILE_LIST_DIRECTORY : FILE_READ_DATA);
    OPAppendLE32(body, 0);          // FileAttributes
    OPAppendLE32(body, FILE_SHARE_ALL);
    OPAppendLE32(body, FILE_OPEN);  // CreateDisposition
    OPAppendLE32(body, isDirectory ? FILE_DIRECTORY_FILE : FILE_NON_DIRECTORY_FILE);
    OPAppendLE16(body, 120);        // NameOffset (64 + 56)
    OPAppendLE16(body, (uint16_t)nameData.length);
    OPAppendLE32(body, 0);          // CreateContextsOffset
    OPAppendLE32(body, 0);          // CreateContextsLength
    [body appendData:nameData];

    uint32_t status = 0;
    NSData *response = [self transact:SMB2_CREATE body:body status:&status error:error];
    if (!response) {
        return nil;
    }
    if (status != STATUS_SUCCESS) {
        if (error) *error = OPSMBErrorForStatus(status);
        return nil;
    }
    if (response.length < 80) {
        if (error) *error = OPSMBError(@"创建响应无效");
        return nil;
    }
    const uint8_t *bytes = response.bytes;
    if (fileSizeOut) {
        *fileSizeOut = OPReadLE64(bytes + 48);
    }
    return [response subdataWithRange:NSMakeRange(64, 16)];  // FileId
}

- (void)closeFileId:(NSData *)fileId {
    if (fileId.length < 16) {
        return;
    }
    NSMutableData *body = [NSMutableData data];
    OPAppendLE16(body, 24);         // StructureSize
    OPAppendLE16(body, 0);          // Flags
    OPAppendLE32(body, 0);          // Reserved
    [body appendData:fileId];
    [self transact:SMB2_CLOSE body:body status:NULL error:NULL];
}

- (NSArray *)listDirectory:(NSString *)relativePath
                parentPath:(NSString *)parentPath
                     error:(NSError **)error {
    uint64_t unusedSize = 0;
    NSData *fileId = [self createPath:relativePath isDirectory:YES fileSize:&unusedSize error:error];
    if (!fileId) {
        return nil;
    }

    NSMutableArray *items = [NSMutableArray array];
    BOOL done = NO;
    while (!done) {
        NSMutableData *body = [NSMutableData data];
        OPAppendLE16(body, 33);     // StructureSize
        uint8_t infoClass = 0x25;   // FileIdBothDirectoryInformation
        uint8_t queryFlags = 0;
        [body appendBytes:&infoClass length:1];
        [body appendBytes:&queryFlags length:1];
        OPAppendLE32(body, 0);      // FileIndex
        [body appendData:fileId];
        OPAppendLE16(body, 96);     // FileNameOffset (64 + 32)
        OPAppendLE16(body, 0);      // FileNameLength
        OPAppendLE32(body, 65536);  // OutputBufferLength

        uint32_t status = 0;
        NSData *response = [self transact:SMB2_QUERY_DIRECTORY body:body status:&status error:error];
        if (!response) {
            break;
        }
        if (status == STATUS_NO_MORE_FILES) {
            done = YES;
            continue;
        }
        if (status != STATUS_SUCCESS) {
            if (error) *error = OPSMBErrorForStatus(status);
            [items removeAllObjects];
            break;
        }
        if (response.length < 8) {
            done = YES;
            continue;
        }
        const uint8_t *bytes = response.bytes;
        uint16_t outputOffset = OPReadLE16(bytes + 2);
        uint32_t outputLength = OPReadLE32(bytes + 4);
        NSInteger localOffset = (NSInteger)outputOffset - 64;
        if (localOffset < 0 || localOffset + outputLength > (NSInteger)response.length) {
            done = YES;
            continue;
        }
        [self parseDirectoryBuffer:[response subdataWithRange:NSMakeRange(localOffset, outputLength)]
                       parentPath:parentPath
                          into:items];
        if (outputLength == 0) {
            done = YES;
        }
    }

    [self closeFileId:fileId];

    [items sortUsingComparator:^NSComparisonResult(OPFileItem *a, OPFileItem *b) {
        if (a.isDirectory != b.isDirectory) {
            return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a.name caseInsensitiveCompare:b.name];
    }];
    return items;
}

- (void)parseDirectoryBuffer:(NSData *)buffer
                  parentPath:(NSString *)parentPath
                        into:(NSMutableArray *)items {
    const uint8_t *bytes = buffer.bytes;
    NSUInteger total = buffer.length;
    NSUInteger offset = 0;
    while (offset + 104 <= total) {
        const uint8_t *record = bytes + offset;
        uint32_t nextEntry = OPReadLE32(record + 0);
        uint32_t fileAttributes = OPReadLE32(record + 56);
        uint32_t nameLength = OPReadLE32(record + 60);
        uint64_t endOfFile = OPReadLE64(record + 40);
        uint64_t lastWrite = OPReadLE64(record + 24);

        if (nameLength > 0 && offset + 104 + nameLength <= total) {
            NSData *nameData = [NSData dataWithBytes:record + 104 length:nameLength];
            NSString *name = OPSMBDecodeUTF16(nameData);
            if (name.length > 0 && ![name isEqualToString:@"."] && ![name isEqualToString:@".."]) {
                OPFileItem *item = [[OPFileItem alloc] init];
                item.name = name;
                item.remotePath = [parentPath isEqualToString:@"/"]
                    ? [@"/" stringByAppendingString:name]
                    : [NSString stringWithFormat:@"%@/%@", parentPath, name];
                item.isDirectory = (fileAttributes & 0x10) != 0;
                item.fileSize = item.isDirectory ? 0 : (long long)endOfFile;
                item.modifiedDate = OPSMBDateFromFiletime(lastWrite);
                [items addObject:item];
            }
        }

        if (nextEntry == 0) {
            break;
        }
        offset += nextEntry;
    }
}

- (BOOL)downloadFile:(NSString *)relativePath
              toPath:(NSString *)localPath
            progress:(void (^)(long long, long long))progress
               error:(NSError **)error {
    uint64_t fileSize = 0;
    NSData *fileId = [self createPath:relativePath isDirectory:NO fileSize:&fileSize error:error];
    if (!fileId) {
        return NO;
    }

    [[NSFileManager defaultManager] removeItemAtPath:localPath error:NULL];
    NSOutputStream *stream = [NSOutputStream outputStreamToFileAtPath:localPath append:NO];
    [stream open];

    uint64_t offset = 0;
    NSInteger chunkSize = 65536;
    BOOL success = YES;
    while (fileSize == 0 || offset < fileSize) {
        NSMutableData *body = [NSMutableData data];
        OPAppendLE16(body, 49);     // StructureSize
        uint8_t padding = 0;
        uint8_t readFlags = 0;
        [body appendBytes:&padding length:1];
        [body appendBytes:&readFlags length:1];
        OPAppendLE32(body, (uint32_t)chunkSize);  // Length
        OPAppendLE64(body, offset);               // Offset
        [body appendData:fileId];
        OPAppendLE32(body, 0);      // MinimumCount
        OPAppendLE32(body, 0);      // Channel
        OPAppendLE32(body, 0);      // RemainingBytes
        OPAppendLE16(body, 0);      // ReadChannelInfoOffset
        OPAppendLE16(body, 0);      // ReadChannelInfoLength
        uint8_t bufferByte = 0;
        [body appendBytes:&bufferByte length:1];

        uint32_t status = 0;
        NSData *response = [self transact:SMB2_READ body:body status:&status error:error];
        if (!response) {
            success = NO;
            break;
        }
        if (status != STATUS_SUCCESS) {
            if (error) *error = OPSMBErrorForStatus(status);
            success = NO;
            break;
        }
        if (response.length < 16) {
            break;
        }
        const uint8_t *bytes = response.bytes;
        uint8_t dataOffset = bytes[2];
        uint32_t dataLength = OPReadLE32(bytes + 4);
        NSInteger localOffset = (NSInteger)dataOffset - 64;
        if (localOffset < 0 || localOffset + dataLength > (NSInteger)response.length) {
            if (error) *error = OPSMBError(@"读取数据越界");
            success = NO;
            break;
        }
        if (dataLength == 0) {
            break;
        }
        NSData *chunk = [response subdataWithRange:NSMakeRange(localOffset, dataLength)];
        NSInteger written = 0;
        const uint8_t *chunkBytes = chunk.bytes;
        while (written < (NSInteger)dataLength) {
            NSInteger n = [stream write:chunkBytes + written maxLength:(NSUInteger)(dataLength - written)];
            if (n <= 0) {
                if (error) *error = OPSMBError(@"写入本地文件失败");
                success = NO;
                break;
            }
            written += n;
        }
        if (!success) {
            break;
        }
        offset += dataLength;
        if (progress) {
            progress((long long)offset, (long long)fileSize);
        }
    }

    [stream close];
    [self closeFileId:fileId];
    return success;
}

@end
