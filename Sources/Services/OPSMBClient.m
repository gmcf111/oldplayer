#import "OPSMBClient.h"
#import "OPSMBSession.h"

static NSString *const OPSMBClientErrorDomain = @"OPSMBClient";

@interface OPSMBClient ()
@property (nonatomic, strong) OPServer *server;
@property (nonatomic, strong) OPSMBSession *activeSession;
@end

@implementation OPSMBClient

- (id)initWithServer:(OPServer *)server {
    self = [super init];
    if (self) {
        _server = server;
    }
    return self;
}

- (void)runBlocking:(void (^)(void))block {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), block);
}

// Splits "/Share/sub/dir" into share "Share" and relative "sub\\dir".
- (BOOL)splitRemotePath:(NSString *)path
                  share:(NSString **)shareOut
               relative:(NSString **)relativeOut
                  error:(NSError **)error {
    NSString *trimmed = path ?: @"";
    while ([trimmed hasPrefix:@"/"]) {
        trimmed = [trimmed substringFromIndex:1];
    }
    NSMutableArray *components = [NSMutableArray array];
    for (NSString *component in [trimmed componentsSeparatedByString:@"/"]) {
        if (component.length > 0) {
            [components addObject:component];
        }
    }
    if (components.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:OPSMBClientErrorDomain code:-1 userInfo:
                      @{NSLocalizedDescriptionKey : @"请在路径中指定共享名，例如 /Media"}];
        }
        return NO;
    }
    if (shareOut) *shareOut = components[0];
    NSArray *rest = [components subarrayWithRange:NSMakeRange(1, components.count - 1)];
    if (relativeOut) *relativeOut = [rest componentsJoinedByString:@"\\"];
    return YES;
}

- (OPSMBSession *)connectSessionForShare:(NSString *)share error:(NSError **)error {
    OPSMBSession *session = [[OPSMBSession alloc] initWithHost:self.server.host
                                                         port:self.server.port
                                                     username:self.server.username
                                                     password:self.server.password];
    @synchronized(self) {
        self.activeSession = session;
    }
    if (![session connect:error]) {
        [session disconnect];
        return nil;
    }
    if (![session treeConnectToShare:share error:error]) {
        [session disconnect];
        return nil;
    }
    return session;
}

- (void)clearSession:(OPSMBSession *)session {
    @synchronized(self) {
        if (self.activeSession == session) {
            self.activeSession = nil;
        }
    }
    [session disconnect];
}

#pragma mark - OPFileSource

- (void)listDirectory:(NSString *)path
           completion:(void (^)(NSArray *, NSError *))completion {
    NSString *requestPath = path.length ? path : @"/";
    __weak OPSMBClient *weakSelf = self;
    [self runBlocking:^{
        OPSMBClient *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSError *error = nil;
        NSString *share = nil;
        NSString *relative = nil;
        NSArray *items = nil;
        if ([strongSelf splitRemotePath:requestPath share:&share relative:&relative error:&error]) {
            OPSMBSession *session = [strongSelf connectSessionForShare:share error:&error];
            if (session) {
                items = [session listDirectory:relative parentPath:requestPath error:&error];
                [strongSelf clearSession:session];
            }
        }
        NSArray *finalItems = items;
        NSError *finalError = error;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(finalItems, finalError);
        });
    }];
}

- (void)downloadFile:(OPFileItem *)item
              toPath:(NSString *)localPath
            progress:(void (^)(long long, long long))progress
          completion:(void (^)(NSError *))completion {
    __weak OPSMBClient *weakSelf = self;
    [self runBlocking:^{
        OPSMBClient *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSError *error = nil;
        BOOL success = NO;
        NSString *share = nil;
        NSString *relative = nil;
        if ([strongSelf splitRemotePath:item.remotePath share:&share relative:&relative error:&error]) {
            OPSMBSession *session = [strongSelf connectSessionForShare:share error:&error];
            if (session) {
                success = [session downloadFile:relative
                                         toPath:localPath
                                       progress:^(long long received, long long total) {
                    if (progress) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            progress(received, total);
                        });
                    }
                } error:&error];
                [strongSelf clearSession:session];
            }
        }
        NSError *finalError = success ? nil : error;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(finalError);
        });
    }];
}

- (void)cancelAll {
    OPSMBSession *session = nil;
    @synchronized(self) {
        session = self.activeSession;
    }
    [session disconnect];
}

@end
