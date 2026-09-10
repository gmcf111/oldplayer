#import <Foundation/Foundation.h>
#import "OPFileItem.h"

/**
 * Low-level SMB2 session (dialects 2.0.2 / 2.1) over a single TCP socket.
 *
 * Flow: connect -> NEGOTIATE -> SESSION_SETUP (NTLMv2) -> TREE_CONNECT,
 * after which listDirectory: / downloadFile: operate on paths relative to
 * the connected share (backslash-separated).
 *
 * All methods are blocking and are intended to be driven from a background
 * queue by OPSMBClient.
 */
@interface OPSMBSession : NSObject

- (id)initWithHost:(NSString *)host
              port:(NSInteger)port
           username:(NSString *)username
           password:(NSString *)password;

- (BOOL)connect:(NSError **)error;
- (BOOL)treeConnectToShare:(NSString *)share error:(NSError **)error;
- (void)disconnect;

- (NSArray *)listDirectory:(NSString *)relativePath
                parentPath:(NSString *)parentPath
                     error:(NSError **)error;

- (BOOL)downloadFile:(NSString *)relativePath
              toPath:(NSString *)localPath
            progress:(void (^)(long long, long long))progress
               error:(NSError **)error;

@end
