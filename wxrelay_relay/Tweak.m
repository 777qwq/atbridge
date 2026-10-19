/**
 * WXRelay Relay v0.4 — SpringBoard 通知捕获器（arm64e）
 * hook NCNotificationDispatcher postNotificationWithRequest:（iOS 14-16 公开点）
 * 命中规则 → 任务文件写入微信沙盒 tmp/wxrelay_task.json → darwin 通知 com.mos.wxrelay.task
 * 微信侧收到通知读自己 tmp 的任务文件发送（微信活着立即发；冻结则唤醒时补发）
 * 规则配置：CFPreferences 域 com.mos.wxrelay，键 rules = 多行 "匹配文本#目标id1#目标id2"
 * 日志：/var/mobile/Library/wxrelay_relay.log
 */
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>

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
    // 直接读文件（绕开 cfprefsd 对手动建文件的缓存问题）
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.mos.wxrelay.plist"];
    if ([d isKindOfClass:[NSDictionary class]]) {
        id v = d[key];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) {
            return v;
        }
    }
    // 兜底：CFPreferences
    CFTypeRef cf = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)@"com.mos.wxrelay");
    if (!cf) return nil;
    NSString *s = CFBridgingRelease(cf);
    return ([s isKindOfClass:[NSString class]] && s.length) ? s : nil;
}

/* 定位微信数据容器：扫 .com.apple.mobile_container_manager.metadata.plist */
static NSString *wechatContainer = nil;
static NSString *rlWeChatContainer(void) {
    if (wechatContainer) return wechatContainer;
    NSString *appsDir = @"/var/mobile/Containers/Data/Application";
    NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:appsDir error:nil];
    for (NSString *d in dirs) {
        NSString *meta = [appsDir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@/.com.apple.mobile_container_manager.metadata.plist", d]];
        NSDictionary *md = [NSDictionary dictionaryWithContentsOfFile:meta];
        if ([[md objectForKey:@"MCMMetadataIdentifier"] isEqualToString:@"com.tencent.xin"]) {
            wechatContainer = [appsDir stringByAppendingPathComponent:d];
            rlLog([NSString stringWithFormat:@"wechat container: %@", wechatContainer]);
            return wechatContainer;
        }
    }
    rlLog(@"wechat container NOT FOUND");
    return nil;
}

static dispatch_queue_t rlTaskQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.mos.wxrelay.tasks", DISPATCH_QUEUE_SERIAL); });
    return q;
}

static void rlDispatch(NSString *text, NSArray *targets) {
    dispatch_async(rlTaskQueue(), ^{
        @try {
            NSString *container = rlWeChatContainer();
            if (!container) return;
            NSString *taskDir = [container stringByAppendingPathComponent:@"tmp/wxrelay_tasks"];
            [[NSFileManager defaultManager] createDirectoryAtPath:taskDir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *fn = [NSString stringWithFormat:@"task_%@.json",
                [[NSUUID UUID] UUIDString]];
            NSDictionary *task = @{ @"targets": targets, @"text": text,
                @"ts": [NSString stringWithFormat:@"%f", [NSDate date].timeIntervalSince1970] };
            NSData *data = [NSJSONSerialization dataWithJSONObject:task options:NSJSONWritingPrettyPrinted error:nil];
            [data writeToFile:[taskDir stringByAppendingPathComponent:fn] atomically:YES];
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                (__bridge CFStringRef)@"com.mos.wxrelay.task", NULL, NULL, YES);
            rlLog([NSString stringWithFormat:@"task written: %@ targets=%@", fn, targets]);
        } @catch (NSException *e) {
            rlLog([NSString stringWithFormat:@"dispatch EXC: %@", e.name]);
        }
    });
}

/* 统一配置：读微信容器 tmp/wxrelay.cfg 的 catch= 行（与微信侧同一份文件） */
static NSDictionary *rlCatchRules(void) {
    NSString *container = rlWeChatContainer();
    if (!container) return nil;
    NSString *p = [container stringByAppendingPathComponent:@"tmp/wxrelay.cfg"];
    NSString *content = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
    if (!content) return nil;
    NSMutableDictionary *rules = [NSMutableDictionary new];
    for (NSString *line in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *l = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (![l hasPrefix:@"catch="]) continue;
        NSArray *parts = [[l substringFromIndex:6] componentsSeparatedByString:@"#"];
        if (parts.count < 2) continue;
        NSString *match = [parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!match.length) continue;
        NSMutableArray *ts = [NSMutableArray new];
        for (NSUInteger i = 1; i < parts.count; i++) {
            NSString *t = [parts[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (t.length) [ts addObject:t];
        }
        if (ts.count) rules[match] = ts;
    }
    return rules.count ? rules : nil;
}

static void rlTryMatch(id request, id content, NSString *title, NSString *message, NSString *sectionID) {
    @try {
        NSDictionary *rules = rlCatchRules();
        if (!rules) return;
        for (NSString *match in rules) {
            NSArray *targets = rules[match];
            if (![title containsString:match] && ![message containsString:match]) continue;
            if (!targets.count) continue;
            NSString *full = title.length ? [NSString stringWithFormat:@"%@\n%@", title, message] : message;
            Class cpCls = NSClassFromString(@"CPDistributedMessagingCenter");
            if (!cpCls) return;
            id mc = ((id(*)(Class,SEL,id))objc_msgSend)(cpCls, NSSelectorFromString(@"centerNamed:"), @"com.mos.wxrelay");
            BOOL ok = ((BOOL(*)(id,SEL,id,id))objc_msgSend)(mc, NSSelectorFromString(@"sendMessageName:userInfo:"),
                @"com.mos.wxrelay", (@{@"text": full, @"targets": targets, @"source": sectionID}));
            rlLog([NSString stringWithFormat:@"match [%@] (%lu chars) -> %@ : %@", match,
                (unsigned long)message.length, targets, ok ? @"sent" : @"send-failed"]);
            break;
        }
    } @catch (NSException *e) {
        rlLog([NSString stringWithFormat:@"trymatch EXC: %@", e.name]);
    }
}

static void rlProcess(id __unused self, id request) {
    @try {
        id content = ((id(*)(id,SEL))objc_msgSend)(request, NSSelectorFromString(@"content"));
        if (!content) return;
        NSString *title = ((id(*)(id,SEL))objc_msgSend)(content, NSSelectorFromString(@"title")) ?: @"";
        NSString *message = ((id(*)(id,SEL))objc_msgSend)(content, NSSelectorFromString(@"message")) ?: @"";
        NSString *sectionID = @"";
        SEL sidSel = NSSelectorFromString(@"sectionIdentifier");
        if ([request respondsToSelector:sidSel]) {
            sectionID = ((id(*)(id,SEL))objc_msgSend)(request, sidSel) ?: @"";
        }
        NSString *skip = rlPref(@"skipSources") ?: @"";
        for (NSString *sn in [skip componentsSeparatedByString:@","]) {
            NSString *t = [sn stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (t.length && [sectionID isEqualToString:t]) return;
        }
        if (!title.length && !message.length) return;

        rlLog([NSString stringWithFormat:@"notif-len: title=%lu msg=%lu", (unsigned long)title.length, (unsigned long)message.length]);
        rlLog([NSString stringWithFormat:@"notif-full: [%@] %@", sectionID, message]);

        rlTryMatch(request, content, title, message, sectionID);

        // 延迟复查：iOS 原地更新通知内容（先短后长），3 秒后重读，变长再匹配一次
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
                id c2 = ((id(*)(id,SEL))objc_msgSend)(request, NSSelectorFromString(@"content"));
                if (!c2) return;
                NSString *m2 = ((id(*)(id,SEL))objc_msgSend)(c2, NSSelectorFromString(@"message")) ?: @"";
                NSString *t2 = ((id(*)(id,SEL))objc_msgSend)(c2, NSSelectorFromString(@"title")) ?: @"";
                if (m2.length > message.length || t2.length > title.length) {
                    rlLog([NSString stringWithFormat:@"late-update: msg %lu -> %lu chars, re-matching",
                        (unsigned long)message.length, (unsigned long)m2.length]);
                    rlTryMatch(request, c2, t2, m2, sectionID);
                }
            } @catch (NSException *e) { }
        });
    } @catch (NSException *e) {
        rlLog([NSString stringWithFormat:@"EXC: %@ %@", e.name, e.reason]);
    }
}

static void (*orig_postNotification)(id, SEL, id);
static void hooked_postNotification(id self, SEL _cmd, id request) {
    orig_postNotification(self, _cmd, request);
    rlProcess(self, request);
}

__attribute__((constructor)) static void wxrelayInit(void) {
    @autoreleasepool {
        Class cls = NSClassFromString(@"NCNotificationDispatcher");
        if (!cls) { rlLog(@"NCNotificationDispatcher not found"); return; }
        SEL sel = NSSelectorFromString(@"postNotificationWithRequest:");
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { rlLog(@"postNotificationWithRequest: not found"); return; }
        orig_postNotification = (void (*)(id, SEL, id))method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_postNotification);
        rlLog(@"v0.4 hook installed (file-based task queue)");
    }
}
