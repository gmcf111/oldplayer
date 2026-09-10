#import <Foundation/Foundation.h>
#import "OPServer.h"

@class OPSocket;

NSError *OPFTPError(NSString *message);

/**
 * One FTP control connection (login, PASV, command/reply).
 *
 * Shared by OPFTPClient (listing/download) and the streaming reader.
 * Sockets created through the connection are tracked in `registry` so
 * cancelAll can close them from another thread.
 */
@interface OPFTPConnection : NSObject

@property (nonatomic, strong) OPServer *server;
@property (nonatomic, strong) NSMutableArray *registry;
@property (nonatomic, strong) OPSocket *control;
@property (nonatomic, strong) NSMutableArray *owned;

- (id)initWithServer:(OPServer *)server registry:(NSMutableArray *)registry;
- (BOOL)openAndLogin:(NSError **)error;
- (NSInteger)command:(NSString *)command reply:(NSString **)replyOut error:(NSError **)error;
- (NSInteger)readReply:(NSString **)replyOut error:(NSError **)error;
- (OPSocket *)openPassiveDataSocket:(NSError **)error;
- (NSData *)retrieveWithCommand:(NSString *)command error:(NSError **)error;
- (void)close;

@end
