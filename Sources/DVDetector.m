#import "DVDetector.h"
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>

static NSString *gIdent;
static DVKind gKind;
static NSObject *gLock;

static void DVSet(DVKind kind, NSString *ident) {
    if (!ident.length) return;
    @synchronized (gLock) {
        gKind = kind;
        gIdent = [ident copy];
    }
}

static NSString *DVMatch(NSString *s, NSString *pattern) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    return m ? [s substringWithRange:[m rangeAtIndex:1]] : nil;
}

static void DVObserveGQL(id json) {
    if ([json isKindOfClass:NSArray.class]) {
        for (id op in json) DVObserveGQL(op);
        return;
    }
    if (![json isKindOfClass:NSDictionary.class]) return;
    NSString *op = json[@"operationName"];
    NSDictionary *vars = json[@"variables"];
    if (![vars isKindOfClass:NSDictionary.class]) return;
    BOOL tokenOp = [op isKindOfClass:NSString.class] && [op rangeOfString:@"PlaybackAccessToken" options:NSCaseInsensitiveSearch].location != NSNotFound;
    BOOL looksLikeToken = vars[@"isLive"] != nil && vars[@"isVod"] != nil;
    if (!tokenOp && !looksLikeToken) return;
    if ([vars[@"isVod"] boolValue] && [vars[@"vodID"] isKindOfClass:NSString.class] && [vars[@"vodID"] length]) {
        DVSet(DVKindVOD, vars[@"vodID"]);
    } else if ([vars[@"isLive"] boolValue] && [vars[@"login"] isKindOfClass:NSString.class] && [vars[@"login"] length]) {
        DVSet(DVKindLive, [vars[@"login"] lowercaseString]);
    }
}

static void DVObserve(NSURL *url, NSData *body) {
    @try {
        NSString *host = url.host.lowercaseString;
        if (!host) return;
        if ([host hasPrefix:@"usher."]) {
            NSString *path = url.path ?: @"";
            NSString *vod = DVMatch(path, @"/vod/(?:v\\d+/)?(\\d+)\\.m3u8");
            if (vod) { DVSet(DVKindVOD, vod); return; }
            NSString *login = DVMatch(path, @"/channel/hls/([A-Za-z0-9_]+)\\.m3u8");
            if (login) DVSet(DVKindLive, login.lowercaseString);
        } else if ([host hasPrefix:@"gql."] && body.length && body.length < 200000) {
            id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
            if (json) DVObserveGQL(json);
        }
    } @catch (__unused NSException *e) {}
}

static BOOL DVOwnsMethod(Class cls, SEL sel) {
    unsigned n = 0;
    Method *list = class_copyMethodList(cls, &n);
    BOOL own = NO;
    for (unsigned i = 0; i < n; i++) if (method_getName(list[i]) == sel) { own = YES; break; }
    free(list);
    return own;
}

static void DVHookSessionClass(Class cls) {
    if (!cls) return;
    SEL s1 = @selector(dataTaskWithRequest:completionHandler:);
    if (DVOwnsMethod(cls, s1)) {
        Method m = class_getInstanceMethod(cls, s1);
        IMP orig = method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^id(id me, NSURLRequest *r, id h) {
            DVObserve(r.URL, r.HTTPBody);
            return ((id (*)(id, SEL, id, id))orig)(me, s1, r, h);
        }));
    }
    SEL s2 = @selector(dataTaskWithRequest:);
    if (DVOwnsMethod(cls, s2)) {
        Method m = class_getInstanceMethod(cls, s2);
        IMP orig = method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^id(id me, NSURLRequest *r) {
            DVObserve(r.URL, r.HTTPBody);
            return ((id (*)(id, SEL, id))orig)(me, s2, r);
        }));
    }
    SEL s3 = @selector(uploadTaskWithRequest:fromData:completionHandler:);
    if (DVOwnsMethod(cls, s3)) {
        Method m = class_getInstanceMethod(cls, s3);
        IMP orig = method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^id(id me, NSURLRequest *r, NSData *d, id h) {
            DVObserve(r.URL, d ?: r.HTTPBody);
            return ((id (*)(id, SEL, id, id, id))orig)(me, s3, r, d, h);
        }));
    }
    SEL s4 = @selector(uploadTaskWithRequest:fromData:);
    if (DVOwnsMethod(cls, s4)) {
        Method m = class_getInstanceMethod(cls, s4);
        IMP orig = method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^id(id me, NSURLRequest *r, NSData *d) {
            DVObserve(r.URL, d ?: r.HTTPBody);
            return ((id (*)(id, SEL, id, id))orig)(me, s4, r, d);
        }));
    }
}

@implementation DVDetector

+ (void)install {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLock = [NSObject new];
        DVHookSessionClass(NSURLSession.class);
        DVHookSessionClass(NSClassFromString(@"__NSURLSessionLocal"));

        // The video player may load the playlist straight through AVFoundation.
        Class asset = AVURLAsset.class;
        SEL s = @selector(initWithURL:options:);
        if (DVOwnsMethod(asset, s)) {
            Method m = class_getInstanceMethod(asset, s);
            IMP orig = method_getImplementation(m);
            method_setImplementation(m, imp_implementationWithBlock(^id(id me, NSURL *u, NSDictionary *o) {
                DVObserve(u, nil);
                return ((id (*)(id, SEL, id, id))orig)(me, s, u, o);
            }));
        }
    });
}

+ (BOOL)current:(DVKind *)kind ident:(NSString **)ident {
    @synchronized (gLock) {
        if (!gIdent) return NO;
        *kind = gKind;
        *ident = gIdent;
        return YES;
    }
}

@end
