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
        // 防风暴：同一通知 60 秒内只处理一次（按 来源+标题+正文+分钟 去重）
        static NSMutableDictionary *recent = nil;
        static dispatch_once_t onceT;
        dispatch_once(&onceT, ^{ recent = [NSMutableDictionary new]; });
        NSString *sig = [NSString stringWithFormat:@"%@|%@|%@", sectionID, title, message];
        NSDate *seen = recent[sig];
        NSString *dedupeCfg = rlPref(@"dedupe");
        BOOL dedupeOn = ![dedupeCfg isEqualToString:@"0"];
        if (dedupeOn && seen && [[NSDate date] timeIntervalSinceDate:seen] < 60) {
            rlLog(@"dedupe: same notif within 60s skipped");
            return;
        }
        recent[sig] = [NSDate date];
        for (NSString *k in [recent allKeys]) {
            if ([[NSDate date] timeIntervalSinceDate:recent[k]] > 120) [recent removeObjectForKey:k];
        }
        // 可选跳过来源（默认空=微信通知也作为触发源）
        NSString *skip = rlPref(@"skipSources") ?: @"";
        for (NSString *sn in [skip componentsSeparatedByString:@","]) {
            NSString *t = [sn stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (t.length && [sectionID isEqualToString:t]) return;
        }
        if (!title.length && !message.length) return;

        rlLog([NSString stringWithFormat:@"notif: sec=%@ title=%@ msg=%@", sectionID,
            [title length] > 30 ? [title substringToIndex:30] : title,
            [message length] > 30 ? [message substringToIndex:30] : message]);

        NSString *rules = rlPref(@"rules");
        if (!rules) { rlLog(@"rules PREF EMPTY — 检查 /var/mobile/Library/Preferences/com.mos.wxrelay.plist"); return; }

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
            rlDispatch(full, targets);
            rlLog([NSString stringWithFormat:@"match [%@] (%@) -> dispatched, targets=%@", match, sectionID, targets]);
            break;
        }
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
