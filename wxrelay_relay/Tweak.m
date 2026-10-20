/**
 * WXRelay Relay v0.4 — SpringBoard 通知捕获器（arm64e）
 * hook BBServer publishBulletin:destinations:（NotiBlock 同款，公告全文）
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
            rlDispatch(full, targets);
            rlLog([NSString stringWithFormat:@"match [%@] (%lu chars) -> dispatched targets=%@", match,
                (unsigned long)message.length, targets]);
            break;
        }
    } @catch (NSException *e) {
        rlLog([NSString stringWithFormat:@"trymatch EXC: %@", e.name]);
    }
}

static void rlProcess(id __unused self, id bulletin) {
    @try {
        NSString *title = [bulletin respondsToSelector:NSSelectorFromString(@"title")] ?
            (((id(*)(id,SEL))objc_msgSend)(bulletin, NSSelectorFromString(@"title")) ?: @"") : @"";
        NSString *message = [bulletin respondsToSelector:NSSelectorFromString(@"message")] ?
            (((id(*)(id,SEL))objc_msgSend)(bulletin, NSSelectorFromString(@"message")) ?: @"") : @"";
        NSString *sectionID = [bulletin respondsToSelector:NSSelectorFromString(@"sectionID")] ?
            (((id(*)(id,SEL))objc_msgSend)(bulletin, NSSelectorFromString(@"sectionID")) ?: @"") : @"";
        if (!title.length && !message.length) return;

        rlLog([NSString stringWithFormat:@"notif-len: title=%lu msg=%lu", (unsigned long)title.length, (unsigned long)message.length]);
        rlLog([NSString stringWithFormat:@"notif-full: [%@] %@", sectionID, message]);

        rlTryMatch(bulletin, bulletin, title, message, sectionID);
    } @catch (NSException *e) {
        rlLog([NSString stringWithFormat:@"EXC: %@ %@", e.name, e.reason]);
    }
}

static void (*orig_publishBulletin)(id, SEL, id, unsigned long long);
static void hooked_publishBulletin(id self, SEL _cmd, id bulletin, unsigned long long destinations) {
    orig_publishBulletin(self, _cmd, bulletin, destinations);
    rlProcess(self, bulletin);
}

__attribute__((constructor)) static void wxrelayInit(void) {
    @autoreleasepool {
        Class cls = NSClassFromString(@"BBServer");
        if (!cls) { rlLog(@"BBServer not found"); return; }
        SEL sel = NSSelectorFromString(@"publishBulletin:destinations:");
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { rlLog(@"publishBulletin:destinations: not found"); return; }
        orig_publishBulletin = (void (*)(id, SEL, id, unsigned long long))method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_publishBulletin);
        rlLog(@"v0.12 hook installed (BBServer.publishBulletin:destinations:)");
    }
}
