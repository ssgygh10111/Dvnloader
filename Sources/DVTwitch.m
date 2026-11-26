#import "DVTwitch.h"

static NSString *const kClientID = @"kimne78kx3ncx6brgo4mv6wki5h1ko"; // public web client id

NSString *DVFormatTime(double seconds) {
    long s = (long)MAX(0, seconds);
    return [NSString stringWithFormat:@"%02ld:%02ld:%02ld", s / 3600, (s % 3600) / 60, s % 60];
}

NSError *DVError(NSString *message) {
    return [NSError errorWithDomain:@"Dvnloader" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *DVAttr(NSString *line, NSString *key) {
    NSString *pat = [NSString stringWithFormat:@"(?:^|[,:])%@=(?:\"([^\"]*)\"|([^,]*))", [NSRegularExpression escapedPatternForString:key]];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
    if (!m) return nil;
    for (NSUInteger i = 1; i <= 2; i++) {
        NSRange r = [m rangeAtIndex:i];
        if (r.location != NSNotFound) return [line substringWithRange:r];
    }
    return nil;
}

static NSString *DVEnc(NSString *s) {
    NSMutableCharacterSet *cs = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
    [cs removeCharactersInString:@"+&=?/:,{}\"#"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:cs];
}

static NSArray<NSString *> *DVLines(NSString *text) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *l = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (l.length) [out addObject:l];
    }
    return out;
}

static NSString *DVAfter(NSString *line, NSString *prefix) {
    return [line hasPrefix:prefix] ? [line substringFromIndex:prefix.length] : nil;
}

@implementation DVVariant
@end

@implementation DVSegment
@end

@implementation DVMediaPlaylist

+ (instancetype)parse:(NSString *)text base:(NSURL *)base {
    DVMediaPlaylist *p = [self new];
    NSMutableArray *segs = [NSMutableArray array];
    NSInteger seq = 0;
    double dur = 0, t = 0;
    NSString *title = @"";
    BOOL pending = NO;
    for (NSString *l in DVLines(text)) {
        NSString *v;
        if ((v = DVAfter(l, @"#EXT-X-MEDIA-SEQUENCE:"))) {
            seq = v.integerValue;
        } else if ((v = DVAfter(l, @"#EXTINF:"))) {
            NSRange c = [v rangeOfString:@","];
            dur = (c.location == NSNotFound ? v : [v substringToIndex:c.location]).doubleValue;
            title = c.location == NSNotFound ? @"" : [v substringFromIndex:c.location + 1];
            pending = YES;
        } else if ([l hasPrefix:@"#EXT-X-ENDLIST"]) {
            p.ended = YES;
        } else if ([l hasPrefix:@"#EXT-X-MAP:"]) {
            NSString *u = DVAttr(l, @"URI");
            if (u) p.mapURL = [NSURL URLWithString:u relativeToURL:base].absoluteURL;
        } else if (![l hasPrefix:@"#"] && pending) {
            DVSegment *s = [DVSegment new];
            s.url = [NSURL URLWithString:l relativeToURL:base].absoluteURL;
            s.duration = dur;
            s.title = title;
            s.start = t;
            s.seq = seq++;
            t += dur;
            pending = NO;
            if (s.url) [segs addObject:s];
        }
    }
    p.segments = segs;
    p.total = t;
    return p;
}

@end

@implementation DVTwitch

#pragma mark - Links

+ (NSString *)findLinkInString:(NSString *)s {
    if (!s.length) return nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(?:https?://)?(?:www\\.|m\\.)?twitch\\.tv/[^\\s\"'<>]+"
                                                                        options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    return m ? [s substringWithRange:m.range] : nil;
}

+ (BOOL)parseLink:(NSString *)link kind:(DVKind *)kind ident:(NSString **)ident {
    if (!link.length) return NO;
    NSString *s = [link stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

    NSRegularExpression *vod = [NSRegularExpression regularExpressionWithPattern:@"twitch\\.tv/(?:[A-Za-z0-9_]+/)?(?:videos?|v)/(\\d+)"
                                                                         options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *m = [vod firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (m) {
        *kind = DVKindVOD;
        *ident = [s substringWithRange:[m rangeAtIndex:1]];
        return YES;
    }

    NSRegularExpression *ch = [NSRegularExpression regularExpressionWithPattern:@"twitch\\.tv/([A-Za-z0-9_]{2,25})(?:[/?#]|$)"
                                                                        options:NSRegularExpressionCaseInsensitive error:nil];
    m = [ch firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    NSString *name = nil;
    if (m) {
        name = [s substringWithRange:[m rangeAtIndex:1]].lowercaseString;
    } else {
        // Bare channel name or pure VOD number typed by hand.
        NSRegularExpression *num = [NSRegularExpression regularExpressionWithPattern:@"^\\d{6,}$" options:0 error:nil];
        if ([num numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)]) {
            *kind = DVKindVOD;
            *ident = s;
            return YES;
        }
        NSRegularExpression *bare = [NSRegularExpression regularExpressionWithPattern:@"^@?([A-Za-z0-9_]{2,25})$" options:0 error:nil];
        m = [bare firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
        if (m) name = [s substringWithRange:[m rangeAtIndex:1]].lowercaseString;
    }
    NSSet *reserved = [NSSet setWithArray:@[@"directory", @"videos", @"settings", @"search", @"downloads", @"p", @"login", @"signup", @"subscriptions", @"wallet", @"inventory", @"drops", @"jobs", @"turbo", @"store"]];
    if (!name || [reserved containsObject:name]) return NO;
    *kind = DVKindLive;
    *ident = name;
    return YES;
}

#pragma mark - Network

// Own session with only Apple's URL protocols, so other tweaks in the app
// (ad-block proxies etc.) can't rewrite or reroute our requests.
+ (NSURLSession *)session {
    static NSURLSession *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        NSMutableArray *keep = [NSMutableArray array];
        for (Class cls in c.protocolClasses) {
            NSString *n = NSStringFromClass(cls);
            if ([n hasPrefix:@"NS"] || [n hasPrefix:@"_NS"] || [n hasPrefix:@"__NS"]) [keep addObject:cls];
        }
        c.protocolClasses = keep;
        c.HTTPMaximumConnectionsPerHost = 8;
        c.HTTPAdditionalHeaders = @{@"User-Agent": @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"};
        s = [NSURLSession sessionWithConfiguration:c];
    });
    return s;
}

+ (NSData *)fetch:(NSURLRequest *)req error:(NSError **)err {
    __block NSData *data = nil;
    __block NSError *error = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[[self session] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        NSInteger code = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        if (!e && code >= 400) {
            e = [NSError errorWithDomain:@"Dvnloader" code:code
                                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)code]}];
        }
        data = d;
        error = e;
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (err) *err = error;
    return error ? nil : data;
}

+ (NSDictionary *)accessTokenForKind:(DVKind)kind ident:(NSString *)ident error:(NSError **)err {
    BOOL live = kind == DVKindLive;
    NSString *q =
        @"query PlaybackAccessToken_Template($login: String!, $isLive: Boolean!, $vodID: ID!, $isVod: Boolean!, $playerType: String!) {"
         " streamPlaybackAccessToken(channelName: $login, params: {platform: \"web\", playerBackend: \"mediaplayer\", playerType: $playerType}) @include(if: $isLive) { value signature }"
         " videoPlaybackAccessToken(id: $vodID, params: {platform: \"web\", playerBackend: \"mediaplayer\", playerType: $playerType}) @include(if: $isVod) { value signature } }";
    NSDictionary *body = @{
        @"operationName": @"PlaybackAccessToken_Template",
        @"query": q,
        @"variables": @{
            @"isLive": @(live), @"login": live ? ident : @"",
            @"isVod": @(!live), @"vodID": live ? @"" : ident,
            @"playerType": @"site",
        },
    };
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://gql.twitch.tv/gql"]];
    r.HTTPMethod = @"POST";
    r.timeoutInterval = 20;
    [r setValue:kClientID forHTTPHeaderField:@"Client-ID"];
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSData *d = [self fetch:r error:err];
    if (!d) return nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    NSDictionary *data = [json isKindOfClass:NSDictionary.class] ? json[@"data"] : nil;
    id tok = data[live ? @"streamPlaybackAccessToken" : @"videoPlaybackAccessToken"];
    if (![tok isKindOfClass:NSDictionary.class] || ![tok[@"value"] isKindOfClass:NSString.class]) {
        NSString *raw = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
        if (raw.length > 160) raw = [raw substringToIndex:160];
        NSString *msg = live ? @"This channel is offline" : @"Broadcast not found (maybe deleted)";
        if (err) *err = DVError([NSString stringWithFormat:@"%@\n\n(%@ • %@)", msg, ident, raw]);
        return nil;
    }
    return tok;
}

+ (NSArray<DVVariant *> *)variantsSyncForKind:(DVKind)kind ident:(NSString *)ident error:(NSError **)err {
    NSDictionary *tok = [self accessTokenForKind:kind ident:ident error:err];
    if (!tok) return nil;

    NSString *base = kind == DVKindLive
        ? [NSString stringWithFormat:@"https://usher.ttvnw.net/api/channel/hls/%@.m3u8", ident]
        : [NSString stringWithFormat:@"https://usher.ttvnw.net/vod/%@.m3u8", ident];
    NSString *query = [NSString stringWithFormat:
        @"sig=%@&token=%@&allow_source=true&allow_audio_only=true&player=twitchweb&playlist_include_framerate=true&supported_codecs=avc1&p=%u",
        DVEnc(tok[@"signature"]), DVEnc(tok[@"value"]), arc4random_uniform(9999999)];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@?%@", base, query]];

    NSError *e = nil;
    NSData *d = [self fetch:[NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20] error:&e];
    if (!d) {
        NSString *msg = (e.code == 403) ? @"Subscriber-only broadcast, can't download"
                      : (kind == DVKindLive && e.code == 404) ? @"This channel is offline"
                      : (e.localizedDescription ?: @"Something went wrong");
        if (err) *err = DVError([NSString stringWithFormat:@"%@\n\n(%@ • usher %ld)", msg, ident, (long)e.code]);
        return nil;
    }
    NSString *text = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];

    NSMutableDictionary *names = [NSMutableDictionary dictionary];
    NSMutableArray *variants = [NSMutableArray array];
    NSString *pendingGroup = nil, *pendingRes = nil;
    BOOL pending = NO;
    for (NSString *l in DVLines(text)) {
        if ([l hasPrefix:@"#EXT-X-MEDIA:"] && [l containsString:@"TYPE=VIDEO"]) {
            NSString *g = DVAttr(l, @"GROUP-ID"), *n = DVAttr(l, @"NAME");
            if (g && n) names[g] = n;
        } else if ([l hasPrefix:@"#EXT-X-STREAM-INF:"]) {
            pendingGroup = DVAttr(l, @"VIDEO");
            pendingRes = DVAttr(l, @"RESOLUTION");
            pending = YES;
        } else if (![l hasPrefix:@"#"] && pending) {
            DVVariant *v = [DVVariant new];
            v.url = [NSURL URLWithString:l relativeToURL:url].absoluteURL;
            NSString *n = names[pendingGroup] ?: pendingGroup ?: pendingRes ?: @"?";
            if ([n isEqualToString:@"audio_only"]) n = @"Audio Only";
            v.name = n;
            if (v.url) [variants addObject:v];
            pending = NO;
        }
    }
    if (!variants.count) {
        if (err) *err = DVError(@"No qualities found");
        return nil;
    }
    return variants;
}

+ (DVMediaPlaylist *)mediaPlaylistSync:(NSURL *)url error:(NSError **)err {
    NSData *d = [self fetch:[NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20] error:err];
    if (!d) return nil;
    NSString *text = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!text) {
        if (err) *err = DVError(@"Invalid playlist");
        return nil;
    }
    return [DVMediaPlaylist parse:text base:url];
}

+ (void)fetchVariantsForKind:(DVKind)kind ident:(NSString *)ident
                  completion:(void (^)(NSArray<DVVariant *> *, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *e = nil;
        NSArray *v = [self variantsSyncForKind:kind ident:ident error:&e];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(v, e); });
    });
}

+ (void)fetchMediaPlaylist:(NSURL *)url completion:(void (^)(DVMediaPlaylist *, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *e = nil;
        DVMediaPlaylist *p = [self mediaPlaylistSync:url error:&e];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(p, e); });
    });
}

@end
