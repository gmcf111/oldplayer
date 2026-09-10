#import <Foundation/Foundation.h>
#import "OPFileItem.h"
#import "OPServer.h"

/**
 * Protocol implemented by every remote access backend (WebDAV / FTP / SMB).
 *
 * All completion blocks are delivered on the main queue. A source instance
 * represents exactly one server connection and must be safe to reuse for
 * several sequential operations.
 */
@protocol OPFileSource <NSObject>

// Lists the immediate children of `path`. `path` always starts with "/".
- (void)listDirectory:(NSString *)path
           completion:(void (^)(NSArray *items, NSError *error))completion;

// Downloads `item` into a local file at `localPath` (overwriting it).
- (void)downloadFile:(OPFileItem *)item
              toPath:(NSString *)localPath
            progress:(void (^)(long long received, long long total))progress
          completion:(void (^)(NSError *error))completion;

// Best-effort cancellation of any in-flight operation.
- (void)cancelAll;

@optional
// When non-nil the item can be handed straight to MPMoviePlayer as a URL
// (used by WebDAV to stream over HTTP without a full download).
- (NSURL *)streamURLForItem:(OPFileItem *)item;

@end
