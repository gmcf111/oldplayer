#ifndef Constants_h
#define Constants_h

// Deployment target guard: all APIs used must be available on iOS 6.0.

#define kOPAppName @"OldPlayer"

// NSUserDefaults keys
#define kDefaultsServerList        @"OPServerList"          // NSArray of NSDictionary (server records)
#define kDefaultsLastServerIndex   @"OPLastServerIndex"     // NSInteger
#define kDefaultsPlaybackMode      @"OPPlaybackMode"        // NSInteger
#define kDefaultsThemeMode         @"OPThemeMode"           // NSInteger

// Notification names
#define kNotificationServersChanged @"OPServersChangedNotification"

#endif
