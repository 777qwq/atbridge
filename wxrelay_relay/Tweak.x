/**
 * WXRelay Relay — SpringBoard 通知捕获器（arm64e，云构建）
 * hook NCNotificationDispatcher postNotificationWithRequest:（iOS 14-16 公开点）
 * 规则配置（扁平）：CFPreferences 域 com.mos.wxrelay
 *   rules = 多行字符串，每行一条：匹配文本#目标id1#目标id2
 *   （匹配=标题或正文包含匹配文本；命中→把"标题+正文"完整发给目标）
 * 日志：/var/mobile/Library/wxrelay_relay.log（SB 无沙盒，可直写）
 */
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>

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

%hook NCNotificationDispatcher
- (void)postNotificationWithRequest:(id)request {
    %orig;
    @try {
        static BOOL ready = NO;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ rlLog(@"relay ready"); ready = YES; (void)ready; });

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
            break; // 一条通知只匹配第一条命中的规则
        }
    } @catch (NSException *e) {
        rlLog([NSString stringWithFormat:@"EXC: %@ %@", e.name, e.reason]);
    }
}
%end
