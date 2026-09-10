#import "OPWebDAVParser.h"

@interface OPWebDAVParser () <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableArray *items;
@property (nonatomic, copy) NSString *requestedPath;
@property (nonatomic, strong) NSMutableString *textBuffer;

// Per-response state.
@property (nonatomic, assign) BOOL inResponse;
@property (nonatomic, copy) NSString *href;
@property (nonatomic, assign) BOOL isCollection;
@property (nonatomic, assign) long long contentLength;
@property (nonatomic, copy) NSString *lastModified;
@property (nonatomic, assign) BOOL inHref;
@property (nonatomic, assign) BOOL inContentLength;
@property (nonatomic, assign) BOOL inLastModified;
@end

@implementation OPWebDAVParser

- (NSArray *)parseData:(NSData *)data requestedPath:(NSString *)requestedPath {
    self.items = [NSMutableArray array];
    self.requestedPath = [self normalizedPath:requestedPath];
    self.textBuffer = [NSMutableString string];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.delegate = self;
    parser.shouldProcessNamespaces = NO;
    [parser parse];

    // Directories first, then case-insensitive by name.
    [self.items sortUsingComparator:^NSComparisonResult(OPFileItem *a, OPFileItem *b) {
        if (a.isDirectory != b.isDirectory) {
            return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a.name caseInsensitiveCompare:b.name];
    }];
    return self.items;
}

- (NSString *)normalizedPath:(NSString *)path {
    NSString *p = path ?: @"/";
    while ([p length] > 1 && [p hasSuffix:@"/"]) {
        p = [p substringToIndex:p.length - 1];
    }
    return p;
}

- (NSString *)localName:(NSString *)elementName {
    NSRange colon = [elementName rangeOfString:@":"];
    if (colon.location != NSNotFound) {
        return [[elementName substringFromIndex:colon.location + 1] lowercaseString];
    }
    return [elementName lowercaseString];
}

- (NSString *)pathFromHref:(NSString *)href {
    if (href.length == 0) {
        return nil;
    }
    NSString *path = href;
    if ([href rangeOfString:@"://"].location != NSNotFound) {
        NSURL *url = [NSURL URLWithString:href];
        path = url.path ?: href;
    }
    // Strip any query/fragment.
    NSRange hash = [path rangeOfString:@"#"];
    if (hash.location != NSNotFound) path = [path substringToIndex:hash.location];
    NSRange question = [path rangeOfString:@"?"];
    if (question.location != NSNotFound) path = [path substringToIndex:question.location];
    NSString *decoded = [path stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    return [self normalizedPath:decoded ?: path];
}

- (NSDate *)parseDate:(NSString *)string {
    if (string.length == 0) return nil;
    static NSDateFormatter *rfc1123 = nil;
    static NSDateFormatter *iso = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        rfc1123 = [[NSDateFormatter alloc] init];
        rfc1123.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        rfc1123.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss zzz";
        iso = [[NSDateFormatter alloc] init];
        iso.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        iso.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZ";
    });
    NSDate *date = [rfc1123 dateFromString:string];
    if (!date) date = [iso dateFromString:string];
    return date;
}

- (void)finishResponse {
    if (!self.inResponse) {
        return;
    }
    self.inResponse = NO;
    NSString *path = [self pathFromHref:self.href];
    if (path.length == 0) {
        return;
    }
    if ([path isEqualToString:self.requestedPath]) {
        return;  // the requested collection itself
    }
    NSString *name = [path lastPathComponent];
    if (name.length == 0) {
        return;
    }
    OPFileItem *item = [[OPFileItem alloc] init];
    item.name = name;
    item.remotePath = path;
    item.isDirectory = self.isCollection;
    item.fileSize = self.isCollection ? 0 : self.contentLength;
    item.modifiedDate = [self parseDate:self.lastModified];
    [self.items addObject:item];
}

#pragma mark - NSXMLParserDelegate

- (void)parser:(NSXMLParser *)parser
    didStartElement:(NSString *)elementName
       namespaceURI:(NSString *)namespaceURI
      qualifiedName:(NSString *)qName
         attributes:(NSDictionary *)attributeDict {
    NSString *name = [self localName:elementName];
    [self.textBuffer setString:@""];
    if ([name isEqualToString:@"response"]) {
        self.inResponse = YES;
        self.href = nil;
        self.isCollection = NO;
        self.contentLength = 0;
        self.lastModified = nil;
    } else if ([name isEqualToString:@"href"]) {
        self.inHref = YES;
    } else if ([name isEqualToString:@"collection"]) {
        self.isCollection = YES;
    } else if ([name isEqualToString:@"getcontentlength"]) {
        self.inContentLength = YES;
    } else if ([name isEqualToString:@"getlastmodified"]) {
        self.inLastModified = YES;
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    [self.textBuffer appendString:string];
}

- (void)parser:(NSXMLParser *)parser
      didEndElement:(NSString *)elementName
       namespaceURI:(NSString *)namespaceURI
      qualifiedName:(NSString *)qName {
    NSString *name = [self localName:elementName];
    if ([name isEqualToString:@"href"]) {
        if (self.inHref && self.href.length == 0) {
            self.href = [self.textBuffer stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        self.inHref = NO;
    } else if ([name isEqualToString:@"getcontentlength"]) {
        self.contentLength = [[self.textBuffer stringByTrimmingCharactersInSet:
                                   [NSCharacterSet whitespaceAndNewlineCharacterSet]] longLongValue];
        self.inContentLength = NO;
    } else if ([name isEqualToString:@"getlastmodified"]) {
        self.lastModified = [self.textBuffer stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        self.inLastModified = NO;
    } else if ([name isEqualToString:@"response"]) {
        [self finishResponse];
    }
    [self.textBuffer setString:@""];
}

- (void)parser:(NSXMLParser *)parser parseErrorOccurred:(NSError *)parseError {
    // Partial results are still usable; leave whatever was collected.
}

@end
