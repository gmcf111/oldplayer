#import <Foundation/Foundation.h>
#import "OPFileItem.h"

/**
 * Parses a WebDAV PROPFIND multistatus XML body into OPFileItem objects.
 */
@interface OPWebDAVParser : NSObject

// `requestedPath` is the absolute path that was PROPFIND-ed; the entry the
// server reports for the collection itself is dropped from the result.
- (NSArray *)parseData:(NSData *)data requestedPath:(NSString *)requestedPath;

@end
