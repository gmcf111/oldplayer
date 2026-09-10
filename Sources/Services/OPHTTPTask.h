#import <Foundation/Foundation.h>

/**
 * A single NSURLConnection wrapped with block callbacks.
 *
 * NSURLConnection does not retain its delegate, so callers must keep the
 * task alive until completion (OPWebDAVClient holds its tasks in a set).
 * All blocks are invoked on the main queue.
 *
 * Exactly one output mode is used:
 *   - outputData   non-nil: the body is appended to it (listing responses)
 *   - outputStream non-nil: the body is written to it (file downloads)
 */
@interface OPHTTPTask : NSObject

- (id)initWithRequest:(NSURLRequest *)request
             username:(NSString *)username
             password:(NSString *)password
           outputData:(NSMutableData *)outputData
         outputStream:(NSOutputStream *)outputStream
             progress:(void (^)(long long received, long long total))progress
           completion:(void (^)(NSError *error))completion;

- (void)start;
- (void)cancel;

@end
