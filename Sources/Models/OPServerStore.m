#import "OPServerStore.h"
#import "Constants.h"

@implementation OPServerStore

+ (NSArray *)servers {
    NSArray *raw = [[NSUserDefaults standardUserDefaults] arrayForKey:kDefaultsServerList];
    NSMutableArray *servers = [NSMutableArray arrayWithCapacity:raw.count];
    for (NSDictionary *dict in raw) {
        if ([dict isKindOfClass:[NSDictionary class]]) {
            [servers addObject:[OPServer serverWithDictionary:dict]];
        }
    }
    return servers;
}

+ (void)saveServers:(NSArray *)servers {
    NSMutableArray *raw = [NSMutableArray arrayWithCapacity:servers.count];
    for (OPServer *server in servers) {
        [raw addObject:[server dictionaryRepresentation]];
    }
    [[NSUserDefaults standardUserDefaults] setObject:raw forKey:kDefaultsServerList];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationServersChanged object:nil];
}

+ (void)addServer:(OPServer *)server {
    NSMutableArray *servers = [[self servers] mutableCopy];
    [servers addObject:server];
    [self saveServers:servers];
}

+ (void)updateServer:(OPServer *)server {
    NSMutableArray *servers = [[self servers] mutableCopy];
    for (NSUInteger i = 0; i < servers.count; i++) {
        OPServer *existing = servers[i];
        if ([existing.identifier isEqualToString:server.identifier]) {
            servers[i] = server;
            break;
        }
    }
    [self saveServers:servers];
}

+ (void)upsertServer:(OPServer *)server {
    NSMutableArray *servers = [[self servers] mutableCopy];
    BOOL replaced = NO;
    for (NSUInteger i = 0; i < servers.count; i++) {
        OPServer *existing = servers[i];
        if ([existing.identifier isEqualToString:server.identifier]) {
            servers[i] = server;
            replaced = YES;
            break;
        }
    }
    if (!replaced) {
        [servers addObject:server];
    }
    [self saveServers:servers];
}

+ (void)removeServer:(OPServer *)server {
    NSMutableArray *servers = [[self servers] mutableCopy];
    for (NSUInteger i = 0; i < servers.count; i++) {
        OPServer *existing = servers[i];
        if ([existing.identifier isEqualToString:server.identifier]) {
            [servers removeObjectAtIndex:i];
            break;
        }
    }
    [self saveServers:servers];
}

@end
