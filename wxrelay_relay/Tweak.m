/**
 * WXRelay Relay — SpringBoard 通知捕获器（arm64e，云构建）
 * 手动 swizzle NCNotificationDispatcher postNotificationWithRequest:（iOS 14-16 公开点）
 * 规则配置（扁平）：CFPreferences 域 com.mos.wxrelay
 *   rules = 多行文本，每行：匹配文本#目标id1#目标id2（# 开头为注释）
 *   匹配=标题或正文包含匹配文本；命中→"标题\n正文"发给目标 id
 * 日志：/var/mobile/Library/wxrelay_relay.log
 */
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

#pragma clang assume_nonnull begin
@interface CPDistributedMessagingCenter : NSObject
+ (instancetype)centerNamed:(NSString *)name;
- (BOOL)sendMessageName:(NSString *)name userInfo:(NSDictionary *)userInfo;
@end
#pragma clang assume_nonnull end

static NSString *rlLogPath = @"/var/mobile/Library/wxrelay_relay.log";
static void rlLog(NSString *msg) {
    @try {
        static NSDateFormatter *f = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ f = [NSDateFormatter new]; f.dateFormat = @"HH:mm:ss"; });
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [f stringFromDate:[NSDate date]], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:rlLogPath];
        if (!fh) { [[NSFileManager defaultManager] createFileAtPath:rlLogPath contents:nil attributes:nil];
                   fh = [NSFileHandle fileHandleForWritingAtPath:rlLogPath]; }
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
        NSLog(@"[WXRelayRelay] %@", line);
    } @catch (NSException *e) { }
}

static NSString *rlPref(NSString *key) {
    CFTypeRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)@"com.mos.wxrelay");
    if (!v) return nil;
    NSString *s = CFBridgingRelease(v);
    return ([s isKindOfClass:[NSString class]] && s.length) ? s : nil;
}

static void rlProcess(id __unused self, id request) {
    @try {
        id content = ((id(*)(id,SEL))objc_msgSend)(request, NSSelectorFromString(@"content"));
        if (!content) return;
        NSString *title = ((id(*)(id,SEL))objc_msgSend)(content, NSSelectorFromString(@"title")) ?: @"";
        NSString *message = ((id(*)(id,SEL))objc_msgSend)(content, NSSelectorFromString(@"message")) ?: @"";
        NSString *sectionID = ((id(*)(id,SEL))objc_msgSend)(request, NSSelectorFromString(@"sectionID")) ?: @"";
        if (!title.length && !message.length) return;

        NSString *rules = rlPref(@"rules");
        if (!rules) return;

        for (NSString *line in [rules componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            NSString *l = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (!l.length || [l hasPrefix:@"#"]) continue;
            NSArray *parts = [l componentsSeparatedByString:@"#"];
            if (parts.count < 2) continue;
            NSString *match = [parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (!match.length) continue;
            if (![title containsString:match] && ![message containsString:match]) continue;

            NSMutableArray *targets = [NSMutableArray new];
            for (NSUInteger i = 1; i < parts.count; i++) {
                NSString *t = [parts[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (t.length) [targets addObject:t];
            }
            if (!targets.count) continue;

            NSString *full = title.length ? [NSString stringWithFormat:@"%@\n%@", title, message] : message;
            CPDistributedMessagingCenter *mc = [CPDistributedMessagingCenter centerNamed:@"com.mos.wxrelay"];
            BOOL ok = [mc sendMessageName:@"com.mos.wxrelay"
                                 userInfo:@{@"text": full, @"targets": targets, @"source": sectionID}];
            rlLog([NSString stringWithFormat:@"match [%@] -> %@ : %@", match, targets, ok ? @"sent" : @"send-failed"]);
            break;
        }
    } @catch (NSException *e) {
        rlLog([NSString stringWithFormat:@"EXC: %@ %@", e.name, e.reason]);
    }
}

static void (*orig_postNotification(id self, SEL _cmd, id request))(id, SEL, id);
static void hooked_postNotification(id self, SEL _cmd, id request) {
    orig_postNotification(self, _cmd, request);
    rlProcess(self, request);
}

__attribute__((constructor)) static void wxrelayInit(void) {
    @autoreleasepool {
        Class cls = NSClassFromString(@"NCNotificationDispatcher");
        if (!cls) { NSLog(@"[WXRelayRelay] NCNotificationDispatcher not found"); return; }
        SEL sel = NSSelectorFromString(@"postNotificationWithRequest:");
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { NSLog(@"[WXRelayRelay] postNotificationWithRequest: not found"); return; }
        orig_postNotification = (void (*)(id, SEL, id))method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_postNotification);
        rlLog(@"hook installed (NCNotificationDispatcher.postNotificationWithRequest:)");
    }
}
