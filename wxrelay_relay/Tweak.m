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
    CFTypeRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)@"com.mos.wxrelay");
    if (!v) return nil;
    NSString *s = CFBridgingRelease(v);
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

static void rlDispatch(NSString *text, NSArray *targets) {
    NSString *container = rlWeChatContainer();
    if (!container) return;
    NSString *tmpDir = [container stringByAppendingPathComponent:@"tmp"];
    NSString *taskPath = [tmpDir stringByAppendingPathComponent:@"wxrelay_task.json"];
    NSMutableArray *tasks = [NSMutableArray new];
    NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:taskPath];
    if ([existing isKindOfClass:[NSDictionary class]]) {
        NSArray *old = existing[@"tasks"];
        if ([old isKindOfClass:[NSArray class]]) [tasks addObjectsFromArray:old];
    }
    [tasks addObject:@{ @"targets": targets, @"text": text, @"ts": [NSString stringWithFormat:@"%f", [NSDate date].timeIntervalSince1970] }];
    // 上限保护：堆积超过 20 条丢弃最旧的
    while (tasks.count > 20) [tasks removeObjectAtIndex:0];
    NSDictionary *payload = @{ @"tasks": tasks };
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:taskPath atomically:YES];
    // darwin 通知
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)@"com.mos.wxrelay.task", NULL, NULL, YES);
    rlLog([NSString stringWithFormat:@"task written (%lu queued) + notified", (unsigned long)tasks.count]);
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
