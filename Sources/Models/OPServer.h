#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, OPProtocolType) {
    OPProtocolTypeWebDAV = 0,
    OPProtocolTypeFTP,
    OPProtocolTypeSMB
};

/**
 * A saved connection profile for one remote server.
 *
 * Instances are persisted to NSUserDefaults as plain dictionaries (see
 * OPServerStore), so every field must be plist-compatible.
 */
@interface OPServer : NSObject

@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, assign) OPProtocolType protocolType;
@property (nonatomic, copy) NSString *host;
@property (nonatomic, assign) NSInteger port;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *password;
// Starting directory inside the share. Always begins with "/".
@property (nonatomic, copy) NSString *remotePath;
// WebDAV only: use HTTPS instead of HTTP.
@property (nonatomic, assign) BOOL secure;

+ (instancetype)serverWithDictionary:(NSDictionary *)dictionary;
- (NSDictionary *)dictionaryRepresentation;

- (NSString *)protocolDisplayName;
- (NSString *)defaultPath;
- (NSInteger)defaultPort;
// "smb://host:445" style summary for the server list.
- (NSString *)endpointDescription;

@end
