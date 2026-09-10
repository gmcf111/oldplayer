#import <Foundation/Foundation.h>
#import "OPServer.h"

/**
 * Persists the list of OPServer profiles in NSUserDefaults.
 */
@interface OPServerStore : NSObject

+ (NSArray *)servers;
+ (void)saveServers:(NSArray *)servers;

+ (void)addServer:(OPServer *)server;
+ (void)updateServer:(OPServer *)server;
+ (void)removeServer:(OPServer *)server;
// Insert the server if its identifier is unknown, otherwise replace it.
+ (void)upsertServer:(OPServer *)server;

@end
