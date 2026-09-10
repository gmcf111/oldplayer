#import <Foundation/Foundation.h>

/**
 * Minimal NTLMv2 (NTLMSSP) implementation used by the SMB2 backend.
 *
 * Only the pieces needed for SMB2 session setup are implemented:
 *   - build the NEGOTIATE (type 1) message
 *   - parse the CHALLENGE (type 2) message
 *   - build the AUTHENTICATE (type 3) message with an NTLMv2 response
 */
@interface OPNTLM : NSObject

+ (NSData *)negotiateMessage;

// Decodes a type-2 challenge. All out parameters are optional.
+ (BOOL)parseChallenge:(NSData *)challenge
       serverChallenge:(NSData **)serverChallengeOut
            targetName:(NSString **)targetNameOut
            targetInfo:(NSData **)targetInfoOut;

+ (NSData *)authenticateMessageForUser:(NSString *)user
                              password:(NSString *)password
                                domain:(NSString *)domain
                       serverChallenge:(NSData *)serverChallenge
                            targetInfo:(NSData *)targetInfo
                          sessionKeyOut:(NSData **)sessionKeyOut;

@end
