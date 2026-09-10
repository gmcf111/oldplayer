#import <Foundation/Foundation.h>

/**
 * One entry (file or directory) inside a remote share.
 */
@interface OPFileItem : NSObject

@property (nonatomic, copy) NSString *name;
// Full path inside the source, starting with "/". For WebDAV this is the
// server-reported href path; for FTP/SMB it is the share path.
@property (nonatomic, copy) NSString *remotePath;
@property (nonatomic, assign) BOOL isDirectory;
@property (nonatomic, assign) long long fileSize;
@property (nonatomic, strong) NSDate *modifiedDate;

- (BOOL)isMediaFile;
- (BOOL)isPlayableVideo;
// System player cannot handle these; they go through the FFmpeg soft decoder.
- (BOOL)isSoftDecodedFormat;
- (NSString *)extensionLowercase;
// Human readable byte count ("1.2 MB").
- (NSString *)formattedSize;

@end
