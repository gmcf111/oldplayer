#import "OPNTLM.h"
#import "OPBytes.h"

#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>
#include <string.h>
#include <stdlib.h>

// Negotiate flags.
static const uint32_t NTLM_NEGOTIATE_UNICODE = 0x00000001;
static const uint32_t NTLM_NEGOTIATE_OEM = 0x00000002;
static const uint32_t NTLM_REQUEST_TARGET = 0x00000004;
static const uint32_t NTLM_NEGOTIATE_NTLM = 0x00000200;
static const uint32_t NTLM_NEGOTIATE_ALWAYS_SIGN = 0x00008000;
static const uint32_t NTLM_NEGOTIATE_EXTENDED_SESSIONSECURITY = 0x00080000;
static const uint32_t NTLM_NEGOTIATE_TARGET_INFO = 0x00800000;
static const uint32_t NTLM_NEGOTIATE_128 = 0x20000000;
static const uint32_t NTLM_NEGOTIATE_56 = 0x80000000;

static NSData *OPUTF16LE(NSString *string) {
    if (string.length == 0) {
        return [NSData data];
    }
    NSData *data = [string dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    return data ?: [NSData data];
}

static NSData *OPHMACMD5(NSData *key, NSData *message) {
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgMD5, key.bytes, key.length, message.bytes, message.length, digest);
    return [NSData dataWithBytes:digest length:CC_MD5_DIGEST_LENGTH];
}

static NSData *OPMD4(NSData *data) {
    unsigned char digest[CC_MD4_DIGEST_LENGTH];
    CC_MD4(data.bytes, (CC_LONG)data.length, digest);
    return [NSData dataWithBytes:digest length:CC_MD4_DIGEST_LENGTH];
}

static NSData *OPFiletimeData(void) {
    // Windows FILETIME: 100ns ticks since 1601-01-01.
    uint64_t unixSeconds = (uint64_t)[NSDate date].timeIntervalSince1970;
    uint64_t filetime = (unixSeconds + 11644473600ULL) * 10000000ULL;
    uint8_t bytes[8];
    OPWriteLE64(bytes, filetime);
    return [NSData dataWithBytes:bytes length:8];
}

@implementation OPNTLM

+ (NSData *)negotiateMessage {
    uint32_t flags = NTLM_NEGOTIATE_UNICODE | NTLM_NEGOTIATE_OEM | NTLM_REQUEST_TARGET |
                     NTLM_NEGOTIATE_NTLM | NTLM_NEGOTIATE_ALWAYS_SIGN |
                     NTLM_NEGOTIATE_EXTENDED_SESSIONSECURITY | NTLM_NEGOTIATE_TARGET_INFO |
                     NTLM_NEGOTIATE_128 | NTLM_NEGOTIATE_56;

    NSMutableData *message = [NSMutableData data];
    [message appendBytes:"NTLMSSP\0" length:8];
    OPAppendLE32(message, 1);       // MessageType = NEGOTIATE
    OPAppendLE32(message, flags);
    // DomainNameFields / WorkstationFields: empty, offset points past the header.
    OPAppendLE16(message, 0); OPAppendLE16(message, 0); OPAppendLE32(message, 32);
    OPAppendLE16(message, 0); OPAppendLE16(message, 0); OPAppendLE32(message, 32);
    return message;
}

+ (BOOL)parseChallenge:(NSData *)challenge
       serverChallenge:(NSData **)serverChallengeOut
            targetName:(NSString **)targetNameOut
            targetInfo:(NSData **)targetInfoOut {
    if (challenge.length < 48) {
        return NO;
    }
    const uint8_t *bytes = challenge.bytes;
    if (memcmp(bytes, "NTLMSSP\0", 8) != 0 || OPReadLE32(bytes + 8) != 2) {
        return NO;
    }

    // TargetName security buffer at offset 12.
    uint16_t targetNameLength = OPReadLE16(bytes + 12);
    uint32_t targetNameOffset = OPReadLE32(bytes + 16);
    NSString *targetName = nil;
    if (targetNameLength > 0 && (NSUInteger)targetNameOffset + targetNameLength <= challenge.length) {
        NSData *nameData = [challenge subdataWithRange:NSMakeRange(targetNameOffset, targetNameLength)];
        targetName = [[NSString alloc] initWithData:nameData encoding:NSUTF16LittleEndianStringEncoding];
    }

    NSData *serverChallenge = [challenge subdataWithRange:NSMakeRange(24, 8)];

    // TargetInfo security buffer at offset 40 (present only when flags say so).
    NSData *targetInfo = [NSData data];
    if (challenge.length >= 48) {
        uint16_t infoLength = OPReadLE16(bytes + 40);
        uint32_t infoOffset = OPReadLE32(bytes + 44);
        if (infoLength > 0 && (NSUInteger)infoOffset + infoLength <= challenge.length) {
            targetInfo = [challenge subdataWithRange:NSMakeRange(infoOffset, infoLength)];
        }
    }

    if (serverChallengeOut) *serverChallengeOut = serverChallenge;
    if (targetNameOut) *targetNameOut = targetName ?: @"";
    if (targetInfoOut) *targetInfoOut = targetInfo;
    return YES;
}

+ (NSData *)authenticateMessageForUser:(NSString *)user
                              password:(NSString *)password
                                domain:(NSString *)domain
                       serverChallenge:(NSData *)serverChallenge
                            targetInfo:(NSData *)targetInfo
                          sessionKeyOut:(NSData **)sessionKeyOut {
    NSData *ntHash = OPMD4(OPUTF16LE(password));

    NSMutableData *v2KeyMaterial = [NSMutableData data];
    [v2KeyMaterial appendData:OPUTF16LE([user uppercaseString])];
    [v2KeyMaterial appendData:OPUTF16LE(domain ?: @"")];
    NSData *ntlmv2Hash = OPHMACMD5(ntHash, v2KeyMaterial);

    // 8-byte client challenge.
    unsigned char clientChallenge[8];
    for (int i = 0; i < 8; i++) {
        clientChallenge[i] = (unsigned char)(arc4random() & 0xFF);
    }
    NSData *clientChallengeData = [NSData dataWithBytes:clientChallenge length:8];
    NSData *timestamp = OPFiletimeData();

    NSMutableData *blob = [NSMutableData data];
    [blob appendBytes:"\x01\x01\x00\x00" length:4];   // RespType/ HiRespType / Reserved1
    OPAppendLE32(blob, 0);                            // Reserved2
    [blob appendData:timestamp];
    [blob appendData:clientChallengeData];
    OPAppendLE32(blob, 0);                            // Reserved3
    [blob appendData:targetInfo ?: [NSData data]];
    OPAppendLE32(blob, 0);                            // Reserved4 (terminator)

    NSMutableData *proofInput = [NSMutableData dataWithData:serverChallenge];
    [proofInput appendData:blob];
    NSData *ntProof = OPHMACMD5(ntlmv2Hash, proofInput);

    NSMutableData *ntResponse = [NSMutableData dataWithData:ntProof];
    [ntResponse appendData:blob];

    // LMv2 response (HMAC of server challenge + client challenge).
    NSMutableData *lmInput = [NSMutableData dataWithData:serverChallenge];
    [lmInput appendData:clientChallengeData];
    NSData *lmHash = OPHMACMD5(ntlmv2Hash, lmInput);
    NSMutableData *lmResponse = [NSMutableData dataWithData:lmHash];
    [lmResponse appendData:clientChallengeData];

    // Session base key (used only if the server requires signing).
    NSData *sessionKey = OPHMACMD5(ntlmv2Hash, ntProof);
    if (sessionKeyOut) *sessionKeyOut = sessionKey;

    NSData *domainData = OPUTF16LE(domain ?: @"");
    NSData *userData = OPUTF16LE(user ?: @"");
    NSData *workstationData = OPUTF16LE(@"iOS");

    uint32_t flags = NTLM_NEGOTIATE_UNICODE | NTLM_REQUEST_TARGET | NTLM_NEGOTIATE_NTLM |
                     NTLM_NEGOTIATE_ALWAYS_SIGN | NTLM_NEGOTIATE_EXTENDED_SESSIONSECURITY |
                     NTLM_NEGOTIATE_TARGET_INFO | NTLM_NEGOTIATE_128 | NTLM_NEGOTIATE_56;

    NSMutableData *message = [NSMutableData data];
    [message appendBytes:"NTLMSSP\0" length:8];
    OPAppendLE32(message, 3);  // MessageType = AUTHENTICATE

    // Six security buffers, then flags, then payload. Header is 64 bytes.
    NSUInteger payloadOffset = 64;
    NSUInteger lmOffset = payloadOffset;
    NSUInteger ntOffset = lmOffset + lmResponse.length;
    NSUInteger domainOffset = ntOffset + ntResponse.length;
    NSUInteger userOffset = domainOffset + domainData.length;
    NSUInteger workstationOffset = userOffset + userData.length;
    NSUInteger sessionKeyOffset = workstationOffset + workstationData.length;

    OPAppendLE16(message, (uint16_t)lmResponse.length); OPAppendLE16(message, (uint16_t)lmResponse.length); OPAppendLE32(message, (uint32_t)lmOffset);
    OPAppendLE16(message, (uint16_t)ntResponse.length); OPAppendLE16(message, (uint16_t)ntResponse.length); OPAppendLE32(message, (uint32_t)ntOffset);
    OPAppendLE16(message, (uint16_t)domainData.length); OPAppendLE16(message, (uint16_t)domainData.length); OPAppendLE32(message, (uint32_t)domainOffset);
    OPAppendLE16(message, (uint16_t)userData.length); OPAppendLE16(message, (uint16_t)userData.length); OPAppendLE32(message, (uint32_t)userOffset);
    OPAppendLE16(message, (uint16_t)workstationData.length); OPAppendLE16(message, (uint16_t)workstationData.length); OPAppendLE32(message, (uint32_t)workstationOffset);
    OPAppendLE16(message, 0); OPAppendLE16(message, 0); OPAppendLE32(message, (uint32_t)sessionKeyOffset);
    OPAppendLE32(message, flags);

    [message appendData:lmResponse];
    [message appendData:ntResponse];
    [message appendData:domainData];
    [message appendData:userData];
    [message appendData:workstationData];
    return message;
}

@end
