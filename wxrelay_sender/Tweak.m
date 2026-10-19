/**
 * WXRelay v0.2.0 — 发送器可测版
 *
 * 已验证（v0.1 探针, 微信 8.0.78）:
 *   CMessageMgr EXIST + AddMsg:MsgWrap: instance YES
 *   CMessageWrap initWithMsgType: / m_nsContent / m_nsToUsr / m_nsFromUsr YES
 *   MMServiceCenter defaultCenter YES（getClass: 是实例方法）
 *
 * 本版：
 *   1. 启动后探测自身 wxid（CAccountMgr.m_nsUsrName 候选）
 *   2. 读配置 com.mos.wxrelay（CFPreferences）：testTarget = 目标 id
 *   3. 启动 15s 后发测试消息 "WXRelay 自测 <时间>" → 验证静默发送链路
 *   4. CPDistributedMessaging 监听器就绪（捕获器后续接入）
 * 日志：微信沙盒 tmp/wxrelay.log
 */
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>

#define WR_CENTER_NAME   @"com.mos.wxrelay"
#define WR_TEST_DELAY    20.0
#pragma clang assume_nonnull begin
#pragma clang assume_nonnull end

static void wrLog(NSString *msg) {
    @try {
        static NSDateFormatter *f = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ f = [NSDateFormatter new]; f.dateFormat = @"HH:mm:ss"; });
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [f stringFromDate:[NSDate date]], msg];
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wxrelay.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
        NSLog(@"[WXRelay] %@", line);
    } @catch (NSException *e) { }
}

static id WRElvis(id obj) { return obj ?: [NSNull null]; }

/* ---------- 发送核心：进程内直调 handleOpenURL（懒猫接管） ---------- */
static BOOL WRSendMessage(NSString *targetId, NSString *text) {
    @try {
        id delegate = [UIApplication sharedApplication].delegate;
        if (!delegate) { wrLog(@"send: app delegate nil"); return NO; }
        SEL h = NSSelectorFromString(@"application:handleOpenURL:bundleID:annotation:");
        if (![delegate respondsToSelector:h]) { wrLog(@"send: handleOpenURL not responding"); return NO; }

        NSString *escaped = [text stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLQueryAllowedCharacterSet]];
        NSString *urlStr = [NSString stringWithFormat:@"weixin://aiwmao/user=%@&msg=%@", targetId, escaped];
        NSURL *url = [NSURL URLWithString:urlStr];
        if (!url) { wrLog([NSString stringWithFormat:@"send: bad url %@", urlStr]); return NO; }

        wrLog([NSString stringWithFormat:@"send: invoking handleOpenURL %@", urlStr]);
        ((BOOL(*)(id,SEL,id,id,id,id))objc_msgSend)(delegate, h, nil, url, nil, nil);
        wrLog(@"send: handleOpenURL invoked (LazyCat hook expected to fire)");
        return YES;
    } @catch (NSException *e) {
        wrLog([NSString stringWithFormat:@"send EXC: %@ %@", e.name, e.reason]);
        return NO;
    }
}

/* ---------- 自身 wxid 探测 ---------- */
static NSString *WRDetectSelfWxid(void) {
    @try {
        Class svc = NSClassFromString(@"MMServiceCenter");
        id center = ((id(*)(id,SEL))objc_msgSend)(svc, NSSelectorFromString(@"defaultCenter"));
        for (NSString *clsName in @[@"CAccountMgr", @"CAppAccountMgr", @"WCSession"]) {
            Class c = NSClassFromString(clsName);
            if (!c) continue;
            SEL gcS = NSSelectorFromString(@"getClass:");
            if (![center respondsToSelector:gcS]) { wrLog(@"selfwxid: center no getClass:"); continue; }
            id obj = ((id(*)(id,SEL,Class))objc_msgSend)(center, gcS, c);
            if (!obj) continue;
            for (NSString *prop in @[@"m_nsUsrName", @"userName", @"GetUserName"]) {
                SEL s = NSSelectorFromString(prop);
                if ([obj respondsToSelector:s]) {
                    id v = ((id(*)(id,SEL))objc_msgSend)(obj, s);
                    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
                        wrLog([NSString stringWithFormat:@"self wxid via %@.%@ = %@", clsName, prop, v]);
                        return v;
                    }
                }
            }
            wrLog([NSString stringWithFormat:@"self wxid: %@ no usable prop", clsName]);
        }
    } @catch (NSException *e) {
        wrLog([NSString stringWithFormat:@"selfwxid EXC: %@", e.name]);
    }
    return nil;
}

/* ---------- 配置读取 ---------- */
static NSString *WRTmpPath(NSString *fn) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:fn];
}

/* 配置：与 wxrelay.log 同目录的纯文本 wxrelay.cfg，行格式 key=value */
static NSString *WRConfig(NSString *key) {
    NSString *p = WRTmpPath(@"wxrelay.cfg");
    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) {
        NSString *tpl = @"# WXRelay 配置（纯文本，改完重启微信）\n"
            @"# testTarget=自测发送目标 id（例：filehelper 或 wxid_xxx 或 群id@chatroom）\n"
            @"testTarget=\n";
        [tpl writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        wrLog([NSString stringWithFormat:@"config template created: %@", p]);
    }
    NSString *content = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
    for (NSString *line in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *l = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (l.length == 0 || [l hasPrefix:@"#"]) continue;
        NSRange eq = [l rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *k = [[l substringToIndex:eq.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *v = [[l substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([k isEqualToString:key] && v.length) {
            wrLog([NSString stringWithFormat:@"config %@ = %@ (cfg)", key, v]);
            return v;
        }
    }
    return nil;
}

/* ---------- CPDistributedMessaging 监听（捕获器接入点） ---------- */
static void WRFlushTasks(void) {
    @try {
        NSString *taskPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wxrelay_task.json"];
        NSDictionary *payload = [NSDictionary dictionaryWithContentsOfFile:taskPath]
            ?: [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:taskPath]
                options:NSJSONReadingAllowFragments error:nil];
        if (![payload isKindOfClass:[NSDictionary class]]) return;
        NSArray *tasks = payload[@"tasks"];
        if (![tasks isKindOfClass:[NSArray class]] || !tasks.count) return;
        wrLog([NSString stringWithFormat:@"flush %lu task(s)", (unsigned long)tasks.count]);
        for (NSDictionary *t in tasks) {
            if (![t isKindOfClass:[NSDictionary class]]) continue;
            NSString *text = t[@"text"];
            NSArray *targets = t[@"targets"];
            if (![text isKindOfClass:[NSString class]]) continue;
            for (NSString *target in targets) {
                if ([target isKindOfClass:[NSString class]]) WRSendMessage(target, text);
            }
        }
        // 清空队列
        NSDictionary *empty = @{ @"tasks": @[] };
        NSData *d = [NSJSONSerialization dataWithJSONObject:empty options:NSJSONWritingPrettyPrinted error:nil];
        [d writeToFile:taskPath atomically:YES];
        wrLog(@"flush done, queue cleared");
    } @catch (NSException *e) { wrLog([NSString stringWithFormat:@"flush EXC %@", e.name]); }
}

static void WRTaskNotifyCallback(CFNotificationCenterRef __unused center, void __unused *observer,
                                 CFStringRef __unused name, const void __unused *object, CFDictionaryRef __unused userInfo) {
    @autoreleasepool { WRFlushTasks(); }
}



__attribute__((constructor)) static void wxrelayCtor(void) {
    @autoreleasepool {
        wrLog(@"step0: ctor enter");
        id selfId = nil;

        wrLog(@"step1: self wxid detect (guarded)");
        selfId = WRDetectSelfWxid();
        wrLog([NSString stringWithFormat:@"step1 done: %@", WRElvis(selfId)]);
        (void)selfId;

        wrLog(@"step2: darwin task listener (file-based queue)");
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            WRTaskNotifyCallback, (__bridge CFStringRef)@"com.mos.wxrelay.task", NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        wrLog(@"step2: task listener ready");

        wrLog(@"step3: config");
        // 配置读取（内部含模板生成）
        NSString *testTarget = WRConfig(@"testTarget");
        wrLog([NSString stringWithFormat:@"step3 done: %@", WRElvis(testTarget)]);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(WR_TEST_DELAY * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                @try {
                    Class svcC = NSClassFromString(@"MMServiceCenter");
                    id ctr = ((id(*)(id,SEL))objc_msgSend)(svcC, NSSelectorFromString(@"defaultCenter"));
                    wrLog([NSString stringWithFormat:@"[20s] defaultCenter: %@ class=%@", WRElvis(ctr), NSStringFromClass([ctr class])]);
                    unsigned int n = 0; NSMutableArray *sv = [NSMutableArray new];
                    Method *ms = class_copyMethodList(object_getClass(ctr), &n);
                    for (unsigned int i = 0; i < n; i++) {
                        NSString *mn = NSStringFromSelector(method_getName(ms[i]));
                        if ([mn.lowercaseString containsString:@"service"] || [mn.lowercaseString containsString:@"getclass"])
                            [sv addObject:mn];
                    }
                    free(ms);
                    wrLog([NSString stringWithFormat:@"[20s] service accessors: %@", sv]);
                } @catch (NSException *e) { wrLog([NSString stringWithFormat:@"[20s] dump EXC %@", e.name]); }

                WRFlushTasks(); // 启动补发积压任务
                NSString *testTarget = WRConfig(@"testTarget");
                if (!testTarget) { wrLog(@"[20s] testTarget not set — skip self-test"); return; }
                NSString *msg = [NSString stringWithFormat:@"[WXRelay 自测] %@", [NSDate date]];
                BOOL ok = WRSendMessage(testTarget, msg);
                wrLog([NSString stringWithFormat:@"[20s] self-test: %@", ok ? @"CALLED" : @"FAILED"]);
            });
        // 保活开关：wxrelay.cfg keepAlive=1 → 静默音频，防冻结（锁屏实时转发必需）
        NSString *ka = WRConfig(@"keepAlive");
        if ([ka isEqualToString:@"1"]) {
            [self_setupKeepAlive];
        } else {
            wrLog(@"keepAlive off (wxrelay.cfg keepAlive=1 可开启)");
        }
        wrLog(@"ctor complete");
    }
}